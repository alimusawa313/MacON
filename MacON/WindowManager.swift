//
//  WindowManager.swift
//  MacON
//
//  CompactOS backend: enumerate the Mac's open windows, launch/focus apps, and
//  fit a window to the companion device's screen so the per-window stream maps
//  ~1:1 onto the phone (which is what makes the text big and readable).
//
//  Enumeration uses ScreenCaptureKit (same permission as streaming); moving/
//  resizing other apps' windows needs the Accessibility permission the remote-
//  control feature already requires.
//

import AppKit
import ScreenCaptureKit
import ApplicationServices
import MaconKit

/// Private-but-stable AX bridge: the CGWindowID behind an AXUIElement window.
/// It's the only way to match AX windows (which we can move/resize) to the
/// window IDs ScreenCaptureKit and CGWindowList speak.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

enum WindowManager {

    // MARK: Enumeration

    /// All normal app windows (including minimized / other Spaces), front-to-
    /// back, excluding our own. Feeds the CompactOS picker + window switcher.
    static func list() async -> CompanionWindowsDTO {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            return CompanionWindowsDTO(windows: [])
        }
        let ownBundle = Bundle.main.bundleIdentifier
        let windows = content.windows
            .filter { win in
                win.windowLayer == 0
                    && win.frame.width >= 120 && win.frame.height >= 90
                    && win.owningApplication != nil
                    && win.owningApplication?.bundleIdentifier != ownBundle
            }
            .map { win -> CompanionWindowDTO in
                let pid = win.owningApplication?.processID ?? 0
                let path = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path
                return CompanionWindowDTO(
                    id: win.windowID,
                    app: win.owningApplication?.applicationName ?? "App",
                    appPath: path,
                    title: win.title?.isEmpty == false ? win.title : nil,
                    width: Int(win.frame.width), height: Int(win.frame.height),
                    isOnScreen: win.isOnScreen)
            }
        // On-screen windows first, then by app name so the switcher scans well.
        return CompanionWindowsDTO(windows: windows.sorted {
            if $0.isOnScreen != $1.isOnScreen { return $0.isOnScreen }
            return $0.app.localizedCaseInsensitiveCompare($1.app) == .orderedAscending
        })
    }

    // MARK: Open + fit

    /// Open/focus the requested app (or window), un-minimize + raise it, and
    /// resize it to the device's screen (clamped to the Mac's visible frame —
    /// apps may clamp further to their minimum size). Returns the window the
    /// device should stream, with its actual post-clamp size, and whether the
    /// window was actually moved/resized (an already-fitted window is left
    /// alone, so the capture isn't pointlessly restarted).
    @MainActor
    static func openCompact(_ req: CompanionCompactOpenRequestDTO) async
        -> (response: CompanionCompactOpenResponseDTO, resized: Bool)? {
        guard AXIsProcessTrusted() else { return nil }

        var pid: pid_t?
        var targetID: CGWindowID? = req.windowId          // CGWindowID == UInt32

        if let id = targetID {
            pid = owningPID(of: id)
        } else if let path = req.appPath {
            pid = await launch(path: path)
        }
        guard let pid else { return nil }

        // The app may still be opening its first window — give it a moment.
        var ax: AXUIElement?
        for attempt in 0..<20 {
            if let id = targetID { ax = axWindow(pid: pid, matching: id) }
            else if let front = frontAXWindow(pid: pid) { ax = front.element; targetID = front.id }
            if ax != nil { break }
            if attempt == 19 { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let window = ax, let windowID = targetID else { return nil }

        // Un-minimize and force the window to the very front so device input
        // lands in it — not in whatever was covering it.
        bringToFront(pid: pid, window: window)

        // A native-fullscreen window can't be moved or resized — drop it back
        // to a regular window first, then fit it.
        await exitFullScreen(window)

        let resized = place(window, size: CGSize(width: req.width, height: req.height))

        // Let the app finish its relayout, then report the size it settled on.
        if resized { try? await Task.sleep(for: .milliseconds(200)) }
        let actual = frame(of: window)?.size ?? CGSize(width: req.width, height: req.height)
        return (CompanionCompactOpenResponseDTO(windowId: windowID,
                                                width: Int(actual.width), height: Int(actual.height)),
                resized)
    }

    /// Raise a window and bring its app frontmost — used before injecting a
    /// CompactOS click, so the click can't land on a window overlapping it.
    @MainActor
    static func raise(_ id: CGWindowID) {
        guard let pid = owningPID(of: id),
              let window = axWindow(pid: pid, matching: id) else { return }
        bringToFront(pid: pid, window: window)
    }

    /// Force an app + one of its windows to the very front of the global
    /// stack. NSRunningApplication.activate() is *cooperative* on modern macOS
    /// — coming from a background app (us) it's simply ignored, and AXRaise
    /// alone only reorders windows WITHIN their app. Setting the AX frontmost/
    /// main/focused attributes is not subject to that arbitration (it rides
    /// the Accessibility permission remote control already needs).
    @MainActor
    private static func bringToFront(pid: pid_t, window: AXUIElement) {
        setBool(window, kAXMinimizedAttribute, false)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()   // belt & suspenders
    }

    // MARK: Launch

    /// Focus a running app or launch it; returns its pid once it's running.
    @MainActor
    private static func launch(path: String) async -> pid_t? {
        let url = URL(fileURLWithPath: path)
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == url }) {
            running.activate()
            return running.processIdentifier
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        return app?.processIdentifier
    }

    // MARK: AX plumbing

    private static func owningPID(of windowID: CGWindowID) -> pid_t? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let pid = info.first?[kCGWindowOwnerPID as String] as? Int else { return nil }
        return pid_t(pid)
    }

    private static func axWindows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    private static func axWindow(pid: pid_t, matching id: CGWindowID) -> AXUIElement? {
        axWindows(pid: pid).first { windowID(of: $0) == id }
    }

    /// The app's main window if it has one, else its first AX window.
    private static func frontAXWindow(pid: pid_t) -> (element: AXUIElement, id: CGWindowID)? {
        let app = AXUIElementCreateApplication(pid)
        var main: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &main) == .success,
           let element = main, CFGetTypeID(element) == AXUIElementGetTypeID() {
            let window = unsafeDowncast(element, to: AXUIElement.self)
            if let id = windowID(of: window) { return (window, id) }
        }
        for window in axWindows(pid: pid) {
            if let id = windowID(of: window) { return (window, id) }
        }
        return nil
    }

    private static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    private static func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success,
              let flag = value as? Bool else { return false }
        return flag
    }

    /// Take a window out of native fullscreen and wait for the exit animation
    /// (and its Space switch) to settle, so the follow-up resize sticks.
    @MainActor
    private static func exitFullScreen(_ window: AXUIElement) async {
        guard isFullScreen(window) else { return }
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
        for _ in 0..<10 {                                  // ≤ 2s for the animation
            try? await Task.sleep(for: .milliseconds(200))
            if !isFullScreen(window) { break }
        }
        try? await Task.sleep(for: .milliseconds(300))     // Space switch settles
    }

    /// Resize to `size` (scaled to fit the visible frame while KEEPING the
    /// device's aspect — a portrait phone gets a portrait window, so the stream
    /// fills its screen) and center the window. AX coordinates are top-left-
    /// origin global, so convert from AppKit's. Returns whether the window was
    /// actually touched — one already at the target size is left in peace.
    private static func place(_ window: AXUIElement, size: CGSize) -> Bool {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              size.width > 0, size.height > 0 else { return false }
        let sf = screen.frame, vf = screen.visibleFrame
        let fit = min(1, vf.width / size.width, vf.height / size.height)
        let w = (size.width * fit).rounded()
        let h = (size.height * fit).rounded()

        // Already fitted (within a hair)? Re-placing it would only disturb the
        // app and force a needless capture restart.
        if let current = frame(of: window)?.size,
           abs(current.width - w) <= 2, abs(current.height - h) <= 2 {
            return false
        }

        let topInset = sf.maxY - vf.maxY                       // menu bar / notch
        var origin = CGPoint(x: vf.minX + ((vf.width - w) / 2).rounded(),
                             y: topInset + ((vf.height - h) / 2).rounded())
        var newSize = CGSize(width: w, height: h)

        if let posValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        return true
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, CFGetTypeID(posValue) == AXValueGetTypeID(),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(unsafeDowncast(posValue, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) {
        AXUIElementSetAttributeValue(element, attribute as CFString,
                                     (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }
}
