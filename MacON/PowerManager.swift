//
//  PowerManager.swift
//  MacON
//
//  Keeps the Mac reachable for the companion and lets a paired device wake and
//  unlock it:
//
//  • Keep-awake — an IOKit power assertion so the Mac never idle-sleeps while
//    serving, so it stays reachable (the "always connected" enabler). The app
//    isn't sandboxed, so no special entitlement is needed.
//  • Wake — declares user activity to wake the display; combined with the
//    device's Wake-on-LAN magic packet this also brings the Mac back from full
//    sleep (requires "Wake for network access" in macOS energy settings).
//  • Unlock — types the stored login password at the lock screen (needs
//    Accessibility). macOS blocks synthetic input under Secure Keyboard Entry,
//    so this is best-effort: it dismisses the screen-lock/​screensaver prompt
//    in the common case, not a FileVault preboot screen.
//
//  Also reports the primary NIC's MAC + subnet broadcast so the device can
//  address its magic packet.
//

import Foundation
import IOKit.pwr_mgt
import IOKit.ps
import CoreGraphics
import AppKit
import MaconKit

@MainActor
final class PowerManager {
    private let remote = RemoteControl()

    // MARK: Keep awake

    private var assertionID: IOPMAssertionID = 0
    private(set) var keepAwake = false

    /// Hold (or release) an assertion that blocks idle system + display sleep,
    /// so the Mac stays reachable. Safe to call repeatedly.
    func setKeepAwake(_ on: Bool) {
        guard on != keepAwake else { return }
        if on {
            var id: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "MacON companion is connected" as CFString, &id)
            if ok == kIOReturnSuccess { assertionID = id; keepAwake = true }
        } else {
            if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
            keepAwake = false
        }
    }

    // MARK: Wake

    /// Wake the display (and confirm the machine is active). On a Mac that
    /// idle-slept this lights the screen back up; a full-sleep wake needs the
    /// device's Wake-on-LAN packet first.
    func wake() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("MacON remote wake" as CFString,
                                         kIOPMUserActiveLocal, &id)
    }

    /// Force the display on: keep declaring user activity — plus an HID-level
    /// nudge (a zero-motion mouse move, which the display manager treats as
    /// real input) — until the panel actually reports active. A single
    /// declaration is sometimes ignored at the lock screen; this loops until it
    /// lands, giving up after ~3s (a shut lid has no panel to light — callers
    /// proceed anyway and type blind, which still unlocks the session).
    func forceDisplayOn() async {
        for _ in 0..<10 {
            guard isDisplayAsleep else { return }
            wake()
            if remote.isTrusted {          // posting events needs Accessibility
                let loc = CGEvent(source: nil)?.location ?? .zero
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                        mouseCursorPosition: loc, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    // MARK: Lock state

    /// Whether the login/lock window is currently up.
    var isLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    /// Whether the display has gone to sleep.
    var isDisplayAsleep: Bool { CGDisplayIsActive(CGMainDisplayID()) == 0 }

    /// Whether the Mac is running on AC power. Always true on a desktop with no
    /// battery. macOS only drives a display (real or virtual) in closed-lid
    /// clamshell mode while on AC, so lid-closed screen sharing needs this.
    var isOnACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return true }   // can't tell → assume powered (e.g. a Mac mini)
        return type == kIOPSACPowerValue
    }

    // MARK: Lock

    /// Lock the screen immediately (login window up), via the same private
    /// login.framework entry point the OS uses for ⌃⌘Q. No Accessibility
    /// needed. Returns false if the symbol can't be resolved.
    @discardableResult
    func lock() -> Bool {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFn = @convention(c) () -> Int32
        let lockScreen = unsafeBitCast(sym, to: LockFn.self)
        return lockScreen() == 0
    }

    // MARK: Unlock

    /// Type the password into the lock screen, then Return. Requires
    /// Accessibility and a stored password; returns false if either is missing.
    /// Best-effort — Secure Keyboard Entry can swallow the keystrokes.
    ///
    /// Returns true once a valid attempt has been *dispatched* (the actual typing
    /// happens asynchronously). The single blind 0.4s delay this used to use lost
    /// the password whenever the display had idle-slept: it was still coming back
    /// on when the keys were sent. So we now wake, wait for the display to
    /// actually be on, type, then verify and retry once if the screen is still
    /// locked (the first attempt may have raced the login window appearing).
    /// This recovers the idle-display-sleep case; it can't beat the *secure*
    /// login window, where macOS refuses synthetic keystrokes regardless.
    @discardableResult
    func unlock(password: String) -> Bool {
        guard !password.isEmpty, remote.isTrusted else { return false }
        Task { @MainActor in
            // Force the screen on first — typing into a dark display goes
            // nowhere (this is why unlock used to need the lid opened first).
            await forceDisplayOn()
            // A short settle so the login/lock window is ready for input.
            try? await Task.sleep(for: .milliseconds(350))
            remote.typeSecure(password)
            remote.pressReturn()
            // Still locked a beat later? The window may have appeared just after
            // the first attempt — try once more (only once, to avoid hammering
            // the password field if it's genuinely being rejected).
            try? await Task.sleep(for: .milliseconds(900))
            if isLocked {
                await forceDisplayOn()
                remote.typeSecure(password)
                remote.pressReturn()
            }
        }
        return true
    }

    /// Ask for Accessibility up front (so unlock can post events later).
    func requestPermission() { remote.requestPermission() }

    /// Whether the app is trusted for Accessibility (needed to post events).
    var isTrusted: Bool { remote.isTrusted }

    // MARK: Network identity (for Wake-on-LAN)

    /// The primary active interface's MAC address ("aa:bb:cc:dd:ee:ff") and the
    /// IPv4 subnet broadcast address, so the device can target its magic packet.
    static func networkIdentity() -> (mac: String?, broadcast: String?) {
        var mac: String?
        var broadcast: String?

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (nil, nil) }
        defer { freeifaddrs(ifaddr) }

        // Prefer en0 (built-in Ethernet/Wi-Fi); fall back to the first usable.
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            let family = ptr.pointee.ifa_addr.pointee.sa_family

            if family == UInt8(AF_LINK), mac == nil {
                mac = macString(from: ptr)
            }
            if family == UInt8(AF_INET), broadcast == nil,
               ptr.pointee.ifa_flags & UInt32(IFF_BROADCAST) != 0,
               let dst = ptr.pointee.ifa_dstaddr {   // ifa_broadaddr aliases ifa_dstaddr
                var addr = dst.pointee
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(&addr, socklen_t(addr.sa_len), &host,
                               socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    broadcast = String(cString: host)
                }
            }
        }
        return (mac, broadcast)
    }

    private static func macString(from ptr: UnsafeMutablePointer<ifaddrs>) -> String? {
        ptr.pointee.ifa_addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
            let len = Int(dl.pointee.sdl_alen)
            guard len == 6 else { return nil }
            let base = UnsafeRawPointer(dl).advanced(by: 8 + Int(dl.pointee.sdl_nlen))
                .assumingMemoryBound(to: UInt8.self)
            return (0..<6).map { String(format: "%02x", base[$0]) }.joined(separator: ":")
        }
    }
}
