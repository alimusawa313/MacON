//
//  RemoteControl.swift
//  MacON
//
//  Injects the ControlEvents a paired device sends into the Mac as real input
//  (CGEvent). Requires the Accessibility permission ("Control your computer").
//  Normalized coordinates map onto the main display.
//

import Foundation
import CoreGraphics
import CoreAudio
import AppKit
import MaconKit

@MainActor
final class RemoteControl {
    /// True once the app is trusted for Accessibility (needed to post events).
    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask macOS for Accessibility permission (opens the prompt if not granted).
    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private var lastPoint: CGPoint = .zero

    func handle(_ e: ControlEvent) {
        guard AXIsProcessTrusted() else { return }
        switch e.t {
        case "move":
            if let p = point(e) { move(to: p) }
        case "movedelta":
            moveBy(dx: e.dx ?? 0, dy: e.dy ?? 0)
        case "click":
            let p = point(e) ?? lastPoint
            click(at: p, right: e.button == "right", count: max(1, e.count ?? 1), mods: e.mods ?? [])
        case "scroll":
            scroll(dx: e.dx ?? 0, dy: e.dy ?? 0)
        case "text":
            if let s = e.s { type(s) }
        case "key":
            if let code = e.code { key(CGKeyCode(code), down: e.down ?? true) }
        case "combo":
            // A shortcut chord, e.g. Ctrl+→ (next space) or Ctrl+↑ (Mission Control).
            if let code = e.code { press(CGKeyCode(code), mods: e.mods ?? []) }
        case "media":
            // A media key (play/next/prev/mute) — NX_KEYTYPE_* code.
            if let code = e.code { mediaKey(Int32(code)) }
        case "volume":
            if let v = e.v { setSystemVolume(Float(v)) }
        default:
            break
        }
    }

    // MARK: Mapping

    private func point(_ e: ControlEvent) -> CGPoint? {
        guard let nx = e.x, let ny = e.y else { return nil }
        let b = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: b.minX + nx * b.width, y: b.minY + ny * b.height)
    }

    // MARK: Injection

    private func move(to p: CGPoint) {
        lastPoint = p
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Trackpad-style relative move: nudge the current cursor by (dx, dy), with a
    /// little gain, clamped to the main display.
    private func moveBy(dx: Double, dy: Double) {
        let gain = 1.8
        let current = CGEvent(source: nil)?.location ?? lastPoint
        let b = CGDisplayBounds(CGMainDisplayID())
        let x = min(max(b.minX, current.x + dx * gain), b.maxX - 1)
        let y = min(max(b.minY, current.y + dy * gain), b.maxY - 1)
        move(to: CGPoint(x: x, y: y))
    }

    private func click(at p: CGPoint, right: Bool, count: Int, mods: [String] = []) {
        lastPoint = p
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = right ? .right : .left
        holdingModifiers(mods) { flags in
            for e in [down, up] {
                let ev = CGEvent(mouseEventSource: nil, mouseType: e, mouseCursorPosition: p, mouseButton: button)
                ev?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                if !flags.isEmpty { ev?.flags = flags }
                ev?.post(tap: .cghidEventTap)
            }
        }
    }

    private func scroll(dx: Double, dy: Double) {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    private func type(_ s: String) {
        let chars = Array(s.utf16)
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            chars.withUnsafeBufferPointer { ev?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: $0.baseAddress) }
            ev?.post(tap: .cghidEventTap)
        }
    }

    private func key(_ code: CGKeyCode, down: Bool) {
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
    }

    /// Press a shortcut chord (e.g. Ctrl+→ to switch spaces, like a 3-finger
    /// swipe). System gestures such as Mission Control often ignore a flags-only
    /// synthetic event, so we press the real modifier keys around the key.
    private func press(_ code: CGKeyCode, mods: [String]) {
        holdingModifiers(mods) { flags in
            for down in [true, false] {
                let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                ev?.flags = flags; ev?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Simulate a media key (play/pause, next, prev, mute…) via a system-defined
    /// event — how the physical media keys are delivered.
    private func mediaKey(_ key: Int32) {
        func post(_ down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(down ? 0xA00 : 0xB00))
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                               timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
        post(true); post(false)
    }

    /// Set the default output device's volume (0…1).
    private func setSystemVolume(_ value: Float) {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddr, 0, nil, &size, &deviceID) == noErr else { return }

        var vol = max(0, min(1, value))
        // 'vmvc' = virtual main volume (constant renamed across SDKs; use the code).
        let virtualMainVolume: AudioObjectPropertySelector = 0x766d7663
        var volAddr = AudioObjectPropertyAddress(
            mSelector: virtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &volAddr) else { return }
        AudioObjectSetPropertyData(deviceID, &volAddr, 0, nil, UInt32(MemoryLayout<Float>.size), &vol)
    }

    /// Hold the given modifiers (real key events) for the duration of `body`.
    private func holdingModifiers(_ mods: [String], _ body: (CGEventFlags) -> Void) {
        var flags: CGEventFlags = []
        var keys: [CGKeyCode] = []
        if mods.contains("cmd")   { flags.insert(.maskCommand);   keys.append(55) }  // ⌘
        if mods.contains("ctrl")  { flags.insert(.maskControl);   keys.append(59) }  // ⌃
        if mods.contains("opt")   { flags.insert(.maskAlternate); keys.append(58) }  // ⌥
        if mods.contains("shift") { flags.insert(.maskShift);     keys.append(56) }  // ⇧
        for m in keys {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: m, keyDown: true)
            ev?.flags = flags; ev?.post(tap: .cghidEventTap)
        }
        body(flags)
        for m in keys.reversed() {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: m, keyDown: false)
            ev?.post(tap: .cghidEventTap)
        }
    }
}
