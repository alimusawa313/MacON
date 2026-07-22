//
//  AXSnapshot.swift
//  MacON
//
//  The agent's eyes: a flat list of the frontmost app's addressable controls,
//  read from the accessibility tree — role, name, value, and the exact frame
//  to click. Text instead of pixels: this is what makes planning cheap (no
//  screenshot tokens) and clicking precise (no pixel-guessing). Requires the
//  same Accessibility permission remote control already holds.
//

import Foundation
import AppKit
import ApplicationServices

/// One addressable control, in global display points (top-left origin — the
/// same space CGEvent clicks use).
struct AXNode {
    let role: String            // "AXButton", "AXTextField", "AXMenuBarItem"…
    let name: String            // title / description / placeholder
    let value: String?          // current text-field contents etc.
    let enabled: Bool
    let frame: CGRect
    let isMenuBar: Bool         // top-of-screen menu (opens on click)
}

enum AXSnapshotter {

    /// Roles worth showing the planner — things a user would click or type in.
    private static let interactiveRoles: Set<String> = [
        kAXButtonRole, kAXTextFieldRole, kAXTextAreaRole, kAXCheckBoxRole,
        kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole,
        kAXMenuItemRole, kAXComboBoxRole,
        kAXSliderRole, kAXDisclosureTriangleRole, kAXCellRole, kAXRowRole,
        "AXLink", "AXSearchField", "AXTab",
    ]

    /// The frontmost app's controls + its name and front window title.
    /// Bounded (depth/node caps) so a pathological tree can't stall the loop.
    static func snapshot(maxNodes: Int = 350) -> (app: String, window: String, nodes: [AXNode]) {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            return ("", "", [])
        }
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        var nodes: [AXNode] = []

        // Front window title (context for the planner).
        var windowTitle = ""
        if let win: AXUIElement = attr(appEl, kAXFocusedWindowAttribute) ?? attr(appEl, kAXMainWindowAttribute) {
            windowTitle = string(win, kAXTitleAttribute) ?? ""
            walk(win, depth: 0, into: &nodes, cap: maxNodes, menuBar: false)
        }

        // Menu bar items — how most app commands are reached. Depth 1 only;
        // clicking one opens its menu, whose items show up in the NEXT
        // snapshot (the loop re-reads the tree before every step).
        if let bar: AXUIElement = attr(appEl, kAXMenuBarAttribute) {
            for item in children(bar).prefix(24) {
                guard let node = node(from: item, menuBar: true), !node.name.isEmpty else { continue }
                nodes.append(node)
            }
            // An open menu's items live under the menu bar, not the window.
            for item in children(bar) {
                for menu in children(item) {          // AXMenu when open
                    walk(menu, depth: 0, into: &nodes, cap: maxNodes, menuBar: false)
                }
            }
        }

        return (front.localizedName ?? "", windowTitle, nodes)
    }

    /// The snapshot as compact prompt text — one control per line.
    static func promptText(app: String, window: String, nodes: [AXNode]) -> String {
        var lines = ["Frontmost app: \(app.isEmpty ? "(none)" : app)"]
        if !window.isEmpty { lines.append("Front window: \"\(window)\"") }
        lines.append("Controls (role \"name\"; ~ = disabled, [menu] = menu bar):")
        for n in nodes {
            var line = "- \(n.role) \"\(n.name)\""
            if let v = n.value, !v.isEmpty { line += " value=\"\(v.prefix(60))\"" }
            if !n.enabled { line += " ~" }
            if n.isMenuBar { line += " [menu]" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Tree walk

    private static func walk(_ element: AXUIElement, depth: Int,
                             into nodes: inout [AXNode], cap: Int, menuBar: Bool) {
        guard depth < 16, nodes.count < cap else { return }
        if let node = node(from: element, menuBar: menuBar), !node.name.isEmpty || node.value != nil {
            nodes.append(node)
        }
        for child in children(element) {
            walk(child, depth: depth + 1, into: &nodes, cap: cap, menuBar: menuBar)
            if nodes.count >= cap { return }
        }
    }

    private static func node(from element: AXUIElement, menuBar: Bool) -> AXNode? {
        guard let role = string(element, kAXRoleAttribute),
              menuBar ? role == "AXMenuBarItem" : interactiveRoles.contains(role) else { return nil }
        guard let frame = frame(of: element), frame.width > 1, frame.height > 1 else { return nil }

        let name = string(element, kAXTitleAttribute)
            ?? string(element, kAXDescriptionAttribute)
            ?? string(element, "AXPlaceholderValue")
            ?? ""
        var value: String?
        if let v: CFTypeRef = attr(element, kAXValueAttribute) {
            if let s = v as? String { value = s }
            else if let n = v as? NSNumber { value = n.stringValue }
        }
        let enabled = (attr(element, kAXEnabledAttribute) as CFTypeRef? as? Bool) ?? true
        return AXNode(role: role, name: name, value: value,
                      enabled: enabled, frame: frame, isMenuBar: menuBar)
    }

    // MARK: AX plumbing

    private static func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &out) == .success else { return nil }
        return out as? T
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        let s: String? = attr(element, name)
        let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &out) == .success,
              let list = out as? [AXUIElement] else { return [] }
        return list
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
