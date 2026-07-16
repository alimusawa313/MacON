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

    // MARK: Lock state

    /// Whether the login/lock window is currently up.
    var isLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    /// Whether the display has gone to sleep.
    var isDisplayAsleep: Bool { CGDisplayIsActive(CGMainDisplayID()) == 0 }

    // MARK: Unlock

    /// Type the password into the lock screen, then Return. Requires
    /// Accessibility and a stored password; returns false if either is missing.
    /// Best-effort — Secure Keyboard Entry can swallow the keystrokes.
    @discardableResult
    func unlock(password: String) -> Bool {
        guard !password.isEmpty, remote.isTrusted else { return false }
        wake()                                   // make sure the screen is lit
        // Give the login window a moment to appear before typing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [remote] in
            remote.typeSecure(password)
            remote.pressReturn()
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
