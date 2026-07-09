//
//  VirtualKeyboard.swift
//  macon-helper
//
//  A virtual USB-boot keyboard created with IOHIDUserDevice. Because it injects
//  at the HID report layer (like real hardware), its keystrokes are accepted at
//  the login window / lock screen, where Secure Event Input rejects synthetic
//  CGEvents.
//
//  Requires: running as root AND signed with
//  `com.apple.developer.hid.virtual.device` (see SETUP.md). Without both,
//  `IOHIDUserDeviceCreate` returns nil and typing is a no-op.
//

import Foundation
import IOKit
import IOKit.hid
import CVirtualHID

final class VirtualKeyboard: @unchecked Sendable {
    private let device: IOHIDUserDevice?
    private let lock = NSLock()

    /// 8-byte boot-keyboard report: [modifiers, reserved, k1…k6].
    private var report = [UInt8](repeating: 0, count: 8)

    init() { device = Self.makeDevice() }

    var isReady: Bool { device != nil }

    // MARK: Typing

    /// Type a string by tapping each character (down then up).
    func type(_ string: String) {
        for scalar in string.unicodeScalars {
            guard let (usage, shift) = Self.hidUsage(for: scalar) else { continue }
            tap(usage: usage, shift: shift)
        }
    }

    /// Tap a raw HID usage (e.g. Return = 0x28, Delete = 0x2A) with optional shift.
    func tap(usage: UInt8, shift: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        report[0] = shift ? 0x02 : 0x00     // left-shift modifier
        report[2] = usage
        send()
        report[0] = 0; report[2] = 0        // release
        send()
    }

    /// Caller holds `lock`.
    private func send() {
        guard let device else { return }
        report.withUnsafeBufferPointer {
            _ = IOHIDUserDeviceHandleReport(device, $0.baseAddress!, CFIndex(report.count))
        }
        usleep(1500)                        // brief spacing so the loginwindow keeps up
    }

    // MARK: Device creation

    private static func makeDevice() -> IOHIDUserDevice? {
        let props: [String: Any] = [
            kIOHIDReportDescriptorKey as String: Data(bootKeyboardDescriptor),
            kIOHIDVendorIDKey as String: 0x1209,
            kIOHIDProductIDKey as String: 0x6D01,
            kIOHIDManufacturerKey as String: "MacOn",
            kIOHIDProductKey as String: "MacOn Virtual Keyboard",
            kIOHIDTransportKey as String: "Virtual",
        ]
        return IOHIDUserDeviceCreate(kCFAllocatorDefault, props as CFDictionary)?.takeRetainedValue()
    }

    /// Standard 65-byte USB HID boot-keyboard report descriptor.
    private static let bootKeyboardDescriptor: [UInt8] = [
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x06,        // Usage (Keyboard)
        0xA1, 0x01,        // Collection (Application)
        0x05, 0x07,        //   Usage Page (Keyboard)
        0x19, 0xE0,        //   Usage Minimum (LeftControl)
        0x29, 0xE7,        //   Usage Maximum (Right GUI)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x01,        //   Logical Maximum (1)
        0x75, 0x01,        //   Report Size (1)
        0x95, 0x08,        //   Report Count (8)
        0x81, 0x02,        //   Input (Data,Var,Abs) — modifier byte
        0x95, 0x01,        //   Report Count (1)
        0x75, 0x08,        //   Report Size (8)
        0x81, 0x01,        //   Input (Const) — reserved byte
        0x95, 0x06,        //   Report Count (6)
        0x75, 0x08,        //   Report Size (8)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x65,        //   Logical Maximum (101)
        0x05, 0x07,        //   Usage Page (Keyboard)
        0x19, 0x00,        //   Usage Minimum (0)
        0x29, 0x65,        //   Usage Maximum (101)
        0x81, 0x00,        //   Input (Data,Array) — 6 key slots
        0xC0,              // End Collection
    ]

    // MARK: Character → HID usage

    /// Map a character to (usage, needsShift). Covers the ASCII a machine password
    /// realistically uses; unknown scalars are skipped.
    static func hidUsage(for scalar: Unicode.Scalar) -> (UInt8, Bool)? {
        let c = Character(scalar)
        if let u = lower[c] { return (u, false) }
        if let u = shifted[c] { return (u, true) }
        if ("A"..."Z").contains(c), let u = lower[Character(c.lowercased())] { return (u, true) }
        return nil
    }

    private static let lower: [Character: UInt8] = {
        var m: [Character: UInt8] = [:]
        let letters = "abcdefghijklmnopqrstuvwxyz"
        for (i, ch) in letters.enumerated() { m[ch] = UInt8(0x04 + i) }
        let digits = "1234567890"
        for (i, ch) in digits.enumerated() { m[ch] = UInt8(0x1E + i) }
        m[" "] = 0x2C; m["-"] = 0x2D; m["="] = 0x2E; m["["] = 0x2F; m["]"] = 0x30
        m["\\"] = 0x31; m[";"] = 0x33; m["'"] = 0x34; m["`"] = 0x35; m[","] = 0x36
        m["."] = 0x37; m["/"] = 0x38; m["\n"] = 0x28; m["\t"] = 0x2B
        return m
    }()

    /// Shifted symbols → the same usage as their unshifted key, with shift held.
    private static let shifted: [Character: UInt8] = [
        "!": 0x1E, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22, "^": 0x23, "&": 0x24,
        "*": 0x25, "(": 0x26, ")": 0x27, "_": 0x2D, "+": 0x2E, "{": 0x2F, "}": 0x30,
        "|": 0x31, ":": 0x33, "\"": 0x34, "~": 0x35, "<": 0x36, ">": 0x37, "?": 0x38,
    ]
}
