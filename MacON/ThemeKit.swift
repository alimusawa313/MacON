//
//  ThemeKit.swift
//  MacON
//
//  App theming: pick a fill STYLE (gradient or solid) and one of six COLORS.
//  Only colors change — shapes, corner rounding, and type stay constant across
//  every theme. `ThemeManager` publishes the choice and feeds `Brand`
//  (see Theme.swift), so every `Brand.blue` / `Brand.gradient` call site
//  re-skins automatically.
//

import SwiftUI
import Combine

// MARK: - Style

enum ThemeStyle: String, CaseIterable, Identifiable {
    case gradient
    case solid
    var id: String { rawValue }
    var title: String { self == .gradient ? "Gradient" : "Solid" }
}

// MARK: - Colors

enum ThemeColor: String, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, green

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }

    /// The primary brand color.
    var base: Color {
        switch self {
        case .blue:   return Self.rgb(0.231, 0.510, 0.965)
        case .purple: return Self.rgb(0.541, 0.286, 0.968)
        case .pink:   return Self.rgb(0.925, 0.263, 0.600)
        case .red:    return Self.rgb(0.918, 0.243, 0.310)
        case .orange: return Self.rgb(0.961, 0.545, 0.114)
        case .green:  return Self.rgb(0.106, 0.694, 0.427)
        }
    }

    /// The second gradient stop (used only in gradient style).
    var partner: Color {
        switch self {
        case .blue:   return Self.rgb(0.388, 0.400, 0.945)
        case .purple: return Self.rgb(0.729, 0.333, 0.929)
        case .pink:   return Self.rgb(0.976, 0.451, 0.451)
        case .red:    return Self.rgb(0.976, 0.435, 0.267)
        case .orange: return Self.rgb(0.976, 0.412, 0.180)
        case .green:  return Self.rgb(0.153, 0.741, 0.671)
        }
    }

    /// A brighter accent tint.
    var accent: Color {
        switch self {
        case .blue:   return Self.rgb(0.204, 0.722, 0.949)
        case .purple: return Self.rgb(0.647, 0.549, 0.976)
        case .pink:   return Self.rgb(0.976, 0.545, 0.741)
        case .red:    return Self.rgb(0.976, 0.529, 0.451)
        case .orange: return Self.rgb(0.988, 0.741, 0.290)
        case .green:  return Self.rgb(0.290, 0.831, 0.643)
        }
    }
}

// MARK: - Palette

/// The tokens `Brand` reads. Brand-family colors follow the chosen theme;
/// the three status colors (warning / success / danger) stay fixed so build
/// state always reads the same.
struct Palette {
    var primary:   Color
    var secondary: Color
    var accent:    Color
    var warning:   Color
    var success:   Color
    var danger:    Color
    var gradient:  LinearGradient

    static func make(style: ThemeStyle, color: ThemeColor) -> Palette {
        let base = color.base
        let second = style == .gradient ? color.partner : base
        let grad = LinearGradient(colors: [base, second],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        return Palette(
            primary: base,
            secondary: second,
            accent: color.accent,
            warning: Color(red: 0.961, green: 0.620, blue: 0.102),
            success: Color(red: 0.063, green: 0.725, blue: 0.506),
            danger:  Color(red: 0.961, green: 0.247, blue: 0.369),
            gradient: grad)
    }
}

// MARK: - Manager

/// Holds the active style + color, persists them, and re-skins the app.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var style: ThemeStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey) }
    }
    @Published var color: ThemeColor {
        didSet { UserDefaults.standard.set(color.rawValue, forKey: Self.colorKey) }
    }

    /// The live palette `Brand` reads from.
    var palette: Palette { Palette.make(style: style, color: color) }

    /// A value that changes whenever the look changes (for `.id`-based reskins).
    var token: String { "\(style.rawValue)-\(color.rawValue)" }

    private static let styleKey = "macon.theme.style"
    private static let colorKey = "macon.theme.color"

    private init() {
        let s = UserDefaults.standard.string(forKey: Self.styleKey)
        let c = UserDefaults.standard.string(forKey: Self.colorKey)
        style = s.flatMap(ThemeStyle.init(rawValue:)) ?? .gradient
        color = c.flatMap(ThemeColor.init(rawValue:)) ?? .blue
    }
}

// MARK: - Controls

/// Style switch + six color swatches. Applies live.
struct ThemeControls: View {
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Fill", selection: Binding(
                get: { theme.style },
                set: { s in withAnimation(.spring(duration: 0.3)) { theme.style = s } })) {
                ForEach(ThemeStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                ForEach(ThemeColor.allCases) { c in
                    ColorSwatch(color: c, style: theme.style, selected: theme.color == c) {
                        withAnimation(.spring(duration: 0.3)) { theme.color = c }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct ColorSwatch: View {
    let color: ThemeColor
    let style: ThemeStyle
    let selected: Bool
    let action: () -> Void

    private var fill: LinearGradient {
        let second = style == .gradient ? color.partner : color.base
        return LinearGradient(colors: [color.base, second],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                    }
                }
                .overlay(
                    Circle()
                        .strokeBorder(color.base, lineWidth: selected ? 2.5 : 0)
                        .padding(-4))
                .shadow(color: color.base.opacity(selected ? 0.5 : 0.25),
                        radius: selected ? 6 : 3, y: 2)
                .scaleEffect(selected ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .help(color.title)
    }
}
