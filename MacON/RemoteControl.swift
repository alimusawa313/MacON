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
        case "click":
            let p = point(e) ?? lastPoint
            click(at: p, right: e.button == "right", count: max(1, e.count ?? 1))
        case "scroll":
            scroll(dx: e.dx ?? 0, dy: e.dy ?? 0)
        case "text":
            if let s = e.s { type(s) }
        case "key":
            if let code = e.code { key(CGKeyCode(code), down: e.down ?? true) }
        case "swipe":
            // Three-finger swipe → switch spaces, like the Mac trackpad.
            // Swipe left reveals the space to the right (Ctrl+→), and vice-versa.
            if let d = e.s { spaceSwitch(right: d == "left") }
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

    private func click(at p: CGPoint, right: Bool, count: Int) {
        lastPoint = p
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = right ? .right : .left
        for e in [down, up] {
            let ev = CGEvent(mouseEventSource: nil, mouseType: e, mouseCursorPosition: p, mouseButton: button)
            ev?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            ev?.post(tap: .cghidEventTap)
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

    /// Move one space right (Ctrl+→) or left (Ctrl+←) — Mission Control's default
    /// shortcuts, matching a three-finger trackpad swipe.
    private func spaceSwitch(right: Bool) {
        let arrow: CGKeyCode = right ? 124 : 123          // → : ←
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: arrow, keyDown: down)
            ev?.flags = .maskControl
            ev?.post(tap: .cghidEventTap)
        }
    }
}
