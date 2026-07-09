//
//  PrivacyCurtain.swift
//  MacON
//
//  A full-screen "privacy wall" shown on the physical Mac ("In use — please
//  don't touch") while a companion device keeps viewing and controlling the
//  real desktop underneath.
//
//  How it stays out of the companion's way:
//   • The curtain windows are click-through (ignoresMouseEvents) and never
//     become key by default, so injected/real mouse + keyboard fall straight
//     through to the apps below — the companion works exactly as normal.
//   • The curtain windows are EXCLUDED from the ScreenCaptureKit filter (see
//     CompanionManager wiring), so the companion streams the real screen, not
//     the wall.
//
//  Dismissing: a global hot key (⌃⌥⌘U) works even while the wall covers
//  everything. If an (optional) passcode is set, it reveals a passcode field
//  and briefly makes the window key to accept typing; otherwise it drops the
//  wall immediately.
//

import SwiftUI
import AppKit
import Combine
import CryptoKit
import Carbon.HIToolbox
import MaconKit

// MARK: - Manager

@MainActor
final class PrivacyCurtain: ObservableObject {
    static let shared = PrivacyCurtain()

    @Published private(set) var isUp = false
    /// True while the passcode field is showing (window is temporarily key).
    @Published var unlocking = false
    /// Bumped on a wrong passcode to trigger a shake.
    @Published private(set) var wrongAttempts = 0
    /// The message shown on the wall.
    @Published var message: String {
        didSet { UserDefaults.standard.set(message, forKey: Self.msgKey) }
    }

    /// Called whenever the wall is raised or lowered so capture can refresh
    /// which windows it excludes.
    var onChange: (() -> Void)?

    private var windows: [CurtainWindow] = []
    private var hotKey: GlobalHotKey?

    private static let msgKey = "companion.curtain.message"
    private static let passAccount = "companion.curtain.pass"
    private static let defaultMessage = "In use by MacOn — please don't touch."

    private init() {
        message = UserDefaults.standard.string(forKey: Self.msgKey) ?? Self.defaultMessage
        // ⌃⌥⌘U — reveal the unlock prompt / drop the wall, from anywhere.
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_U),
                              modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            Task { @MainActor in self?.beginUnlock() }
        }
    }

    // MARK: Raise / lower

    /// CGWindowIDs of the curtain windows, for the capture filter to exclude.
    var excludedWindowNumbers: [CGWindowID] {
        windows.map { CGWindowID($0.windowNumber) }
    }

    var hasPasscode: Bool { !Keychain.get(account: Self.passAccount).isEmpty }

    func raise() {
        guard !isUp else { return }
        buildWindows()
        isUp = true
        onChange?()
    }

    func lower() {
        guard isUp else { return }
        unlocking = false
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        isUp = false
        NSApp.deactivate()   // hand focus back to whatever the companion was driving
        onChange?()
    }

    /// Triggered by the hot key. No passcode → drop immediately. Passcode set →
    /// reveal the field and make the primary window key to accept typing.
    func beginUnlock() {
        guard isUp else { return }
        guard hasPasscode else { lower(); return }
        unlocking = true
        if let main = windows.first {
            main.keyable = true
            main.ignoresMouseEvents = false
            NSApp.activate(ignoringOtherApps: true)
            main.makeKeyAndOrderFront(nil)
        }
    }

    func cancelUnlock() {
        unlocking = false
        if let main = windows.first {
            main.keyable = false
            main.ignoresMouseEvents = true
            main.resignKey()
        }
        NSApp.deactivate()   // return focus to the app the companion was driving
    }

    /// Verify an entered passcode; drops the wall on success, shakes on failure.
    func submit(_ code: String) {
        if verify(code) {
            lower()
        } else {
            wrongAttempts += 1
        }
    }

    // MARK: Passcode

    /// Set (or, with an empty string, clear) the dismiss passcode.
    func setPasscode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        Keychain.set(trimmed.isEmpty ? "" : hash(trimmed), account: Self.passAccount)
        objectWillChange.send()
    }

    func clearPasscode() { Keychain.set("", account: Self.passAccount) ; objectWillChange.send() }

    private func verify(_ code: String) -> Bool {
        let stored = Keychain.get(account: Self.passAccount)
        return !stored.isEmpty && stored == hash(code)
    }

    private func hash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(("macon.curtain.v1:" + s).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Windows

    private func buildWindows() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()

        let screens = NSScreen.screens
        for (i, screen) in screens.enumerated() {
            let w = CurtainWindow(contentRect: screen.frame,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.isOpaque = true
            w.backgroundColor = .black
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.setFrame(screen.frame, display: true)

            let host = NSHostingView(rootView: CurtainView(curtain: self, primary: i == 0))
            host.frame = CGRect(origin: .zero, size: screen.frame.size)
            host.autoresizingMask = [.width, .height]
            w.contentView = host
            w.orderFrontRegardless()
            windows.append(w)
        }
    }
}

// MARK: - Window

/// A panel that can become key only when we're explicitly unlocking, so the
/// wall never steals focus from the app the companion is driving.
final class CurtainWindow: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
}

// MARK: - Global hot key (Carbon; works while another app is frontmost)

final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        let id = EventHotKeyID(signature: 0x4D_43_4F_4E /* "MCON" */, id: 1)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let this = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(ctx).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, this, &handler)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

// MARK: - Curtain content

private struct CurtainView: View {
    @ObservedObject var curtain: PrivacyCurtain
    var primary: Bool

    @State private var pulse = false
    @State private var code = ""
    @State private var shake: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // Deep, calm backdrop with a faint brand glow.
            LinearGradient(colors: [.black, Color(red: 0.04, green: 0.05, blue: 0.09)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Brand.blue.opacity(0.22), .clear],
                           center: .center, startRadius: 5, endRadius: 620)

            VStack(spacing: 22) {
                ZStack {
                    Circle().fill(Brand.blue.opacity(0.16))
                        .frame(width: 128, height: 128)
                        .scaleEffect(pulse ? 1.12 : 0.94)
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(Brand.gradient)
                }
                .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulse)

                VStack(spacing: 8) {
                    Text(curtain.message)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text("This Mac is being used remotely.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: 640)

                if primary {
                    if curtain.unlocking {
                        passcodeCard
                    } else {
                        Label("Press ⌃⌥⌘U to unlock", systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.top, 8)
                    }
                }
            }
            .padding(40)
        }
        .ignoresSafeArea()
        .onAppear { pulse = true }
        .onChange(of: curtain.unlocking) { _, now in
            if now { focused = true } else { code = "" }
        }
        .onChange(of: curtain.wrongAttempts) { _, _ in
            code = ""
            withAnimation(.default) { shake = 1 }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.25)) { shake = 0 }
        }
    }

    private var passcodeCard: some View {
        VStack(spacing: 12) {
            Text("Enter passcode to unlock").font(.headline).foregroundStyle(.white)
            SecureField("Passcode", text: $code)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit { curtain.submit(code) }
            HStack(spacing: 10) {
                Button("Cancel") { curtain.cancelUnlock() }
                    .buttonStyle(SoftButtonStyle())
                Button("Unlock") { curtain.submit(code) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .offset(x: shake == 0 ? 0 : -10)
        .padding(.top, 8)
    }
}
