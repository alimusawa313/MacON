//
//  WorldKit.swift
//  MacON
//
//  The world theme, shared with the companion app: 13 worlds (8 paint boxes +
//  5 model-swapping skins), each a full palette — paper backdrop, ink, clay
//  slots, semantic status hues — plus the resolved WorldStyle every view
//  reads and the clay UI kit (backdrop, headers, buttons, pills, dots).
//  Replaces the old accent/gradient appearance system.
//

import SwiftUI
import AppKit
import MaconKit

// MARK: - Worlds

/// What the world is MADE of. `machines` is the standard clay hardware;
/// `monsters` is a creature world; `cosmos` swaps in planets and a starfield;
/// `blocks` builds from toy bricks; `balloon` hangs everything from balloons;
/// `dessert` bakes it.
enum WorldSkin {
    case machines, monsters, cosmos, blocks, balloon, dessert
    case holo, puffy, pop, googly
}

enum WorldTheme: String, CaseIterable, Identifiable {
    case pastel, candy, ocean, sunset, forest, terracotta, graphite, neon
    case monster, cosmos, blocks, balloon, dessert
    case holo, puffy, pop, googly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pastel: return "Pastel"
        case .candy: return "Candy"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        case .forest: return "Forest"
        case .terracotta: return "Terracotta"
        case .graphite: return "Graphite"
        case .neon: return "Neon"
        case .monster: return "Monster"
        case .cosmos: return "Cosmos"
        case .blocks: return "Blocks"
        case .balloon: return "Balloon"
        case .dessert: return "Dessert"
        case .holo: return "Holo"
        case .puffy: return "Puffy"
        case .pop: return "Pop"
        case .googly: return "Googly"
        }
    }

    var icon: String {
        switch self {
        case .pastel: return "cloud.fill"
        case .candy: return "birthday.cake.fill"
        case .ocean: return "water.waves"
        case .sunset: return "sun.horizon.fill"
        case .forest: return "leaf.fill"
        case .terracotta: return "mug.fill"
        case .graphite: return "circle.lefthalf.filled"
        case .neon: return "bolt.fill"
        case .monster: return "eyes"
        case .cosmos: return "moon.stars.fill"
        case .blocks: return "square.stack.3d.up.fill"
        case .balloon: return "balloon.2.fill"
        case .dessert: return "cup.and.saucer.fill"
        case .holo: return "sparkles"
        case .puffy: return "cloud.sun.fill"
        case .pop: return "sun.max.fill"
        case .googly: return "eyes.inverse"
        }
    }

    /// Which set of 3D models this world builds from.
    var skin: WorldSkin {
        switch self {
        case .monster: return .monsters
        case .cosmos: return .cosmos
        case .blocks: return .blocks
        case .balloon: return .balloon
        case .dessert: return .dessert
        case .holo: return .holo
        case .puffy: return .puffy
        case .pop: return .pop
        case .googly: return .googly
        default: return .machines
        }
    }

    var palette: WorldPalette {
        switch self {
        case .pastel: return .pastel
        case .candy: return .candy
        case .ocean: return .ocean
        case .sunset: return .sunset
        case .forest: return .forest
        case .terracotta: return .terracotta
        case .graphite: return .graphite
        case .neon: return .neon
        case .monster: return .monster
        case .cosmos: return .cosmos
        case .blocks: return .blocks
        case .balloon: return .balloon
        case .dessert: return .dessert
        case .holo: return .holo
        case .puffy: return .puffy
        case .pop: return .pop
        case .googly: return .googly
        }
    }

    /// Some worlds have no light look — their "light" paper is still dark
    /// (neon, cosmos). The whole UI renders dark for them.
    var prefersDark: Bool { palette.paperLight.isDarkColor }
}

// MARK: - Appearance (Auto / Light / Dark)

/// The user's appearance override: Auto follows the system, Light/Dark pin
/// the app. Always-dark worlds (neon, cosmos, holo) stay dark regardless —
/// their paper has no light look.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, light, dark
    static let key = "macon.appearance"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:  return "Auto"
        case .light: return "Light"
        case .dark:  return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .auto:  return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark:  return "moon.fill"
        }
    }
}

/// Owns the theme + appearance storage so the window re-renders when
/// either changes.
private struct WorldSchemeModifier: ViewModifier {
    @AppStorage(WorldStyle.themeKey) private var worldRaw = WorldTheme.pastel.rawValue
    @AppStorage(AppearanceMode.key) private var appearanceRaw = AppearanceMode.auto.rawValue

    func body(content: Content) -> some View {
        let theme = WorldTheme(rawValue: worldRaw) ?? .pastel
        let mode = AppearanceMode(rawValue: appearanceRaw) ?? .auto
        content.preferredColorScheme(
            theme.prefersDark ? .dark
            : mode == .light ? .light
            : mode == .dark ? .dark
            : nil)
    }
}

extension View {
    /// The world's color scheme under the user's Auto/Light/Dark setting.
    func worldColorScheme() -> some View { modifier(WorldSchemeModifier()) }
}

// MARK: - Palettes

struct WorldPalette {
    // Backdrop + UI ink, per appearance.
    let paperLight: NSColor, edgeLight: NSColor, inkLight: NSColor
    let paperDark: NSColor, edgeDark: NSColor, inkDark: NSColor
    // Clay slots.
    let primary: NSColor, primaryDeep: NSColor       // signature hue
    let soft: NSColor, softShade: NSColor            // quiet fill
    let warm: NSColor, warmDeep: NSColor             // busy / energy
    let good: NSColor, goodDeep: NSColor             // success
    let bad: NSColor, badDeep: NSColor               // failure
    let slate: NSColor, slateDeep: NSColor           // title ink (light mode)
    let cloud: NSColor                               // screens & glow

    func paper(dark: Bool) -> NSColor { dark ? paperDark : paperLight }
    func edge(dark: Bool) -> NSColor { dark ? edgeDark : edgeLight }
    func ink(dark: Bool) -> NSColor { dark ? inkDark : inkLight }
    func titleFace(dark: Bool) -> NSColor { dark ? cloud : slate }
    func titleSide(dark: Bool) -> NSColor { dark ? softShade : slateDeep }

    private static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static let pastel = WorldPalette(
        paperLight: c(0.96, 0.96, 0.96), edgeLight: c(0.85, 0.85, 0.85), inkLight: c(0.28, 0.31, 0.45),
        paperDark: c(0.11, 0.11, 0.14), edgeDark: c(0.05, 0.05, 0.07), inkDark: c(0.93, 0.93, 0.93),
        primary: c(0.49, 0.58, 0.95), primaryDeep: c(0.36, 0.45, 0.85),
        soft: c(0.89, 0.90, 0.97), softShade: c(0.74, 0.76, 0.90),
        warm: c(0.96, 0.72, 0.47), warmDeep: c(0.88, 0.59, 0.34),
        good: c(0.52, 0.80, 0.63), goodDeep: c(0.39, 0.68, 0.51),
        bad: c(0.93, 0.55, 0.61), badDeep: c(0.84, 0.42, 0.49),
        slate: c(0.30, 0.33, 0.50), slateDeep: c(0.22, 0.24, 0.38),
        cloud: c(0.95, 0.95, 0.99))

    static let candy = WorldPalette(
        paperLight: c(0.99, 0.94, 0.96), edgeLight: c(0.95, 0.83, 0.89), inkLight: c(0.45, 0.23, 0.36),
        paperDark: c(0.14, 0.09, 0.12), edgeDark: c(0.07, 0.03, 0.05), inkDark: c(0.98, 0.92, 0.95),
        primary: c(0.94, 0.47, 0.69), primaryDeep: c(0.85, 0.33, 0.57),
        soft: c(0.98, 0.88, 0.93), softShade: c(0.92, 0.73, 0.83),
        warm: c(0.97, 0.75, 0.42), warmDeep: c(0.90, 0.62, 0.28),
        good: c(0.51, 0.82, 0.66), goodDeep: c(0.38, 0.70, 0.54),
        bad: c(0.90, 0.38, 0.47), badDeep: c(0.80, 0.26, 0.36),
        slate: c(0.48, 0.25, 0.38), slateDeep: c(0.37, 0.17, 0.29),
        cloud: c(1.00, 0.97, 0.98))

    static let ocean = WorldPalette(
        paperLight: c(0.92, 0.96, 0.97), edgeLight: c(0.80, 0.89, 0.92), inkLight: c(0.16, 0.32, 0.42),
        paperDark: c(0.07, 0.11, 0.14), edgeDark: c(0.02, 0.05, 0.07), inkDark: c(0.90, 0.96, 0.97),
        primary: c(0.27, 0.63, 0.75), primaryDeep: c(0.17, 0.50, 0.62),
        soft: c(0.85, 0.92, 0.94), softShade: c(0.68, 0.82, 0.86),
        warm: c(0.93, 0.79, 0.53), warmDeep: c(0.85, 0.66, 0.38),
        good: c(0.45, 0.79, 0.68), goodDeep: c(0.32, 0.67, 0.56),
        bad: c(0.91, 0.51, 0.52), badDeep: c(0.81, 0.38, 0.39),
        slate: c(0.19, 0.34, 0.44), slateDeep: c(0.12, 0.25, 0.34),
        cloud: c(0.94, 0.98, 0.99))

    static let sunset = WorldPalette(
        paperLight: c(0.99, 0.95, 0.90), edgeLight: c(0.96, 0.86, 0.76), inkLight: c(0.42, 0.26, 0.28),
        paperDark: c(0.13, 0.09, 0.10), edgeDark: c(0.07, 0.03, 0.04), inkDark: c(0.98, 0.93, 0.89),
        primary: c(0.94, 0.55, 0.42), primaryDeep: c(0.86, 0.42, 0.30),
        soft: c(0.98, 0.90, 0.83), softShade: c(0.93, 0.77, 0.65),
        warm: c(0.96, 0.73, 0.36), warmDeep: c(0.89, 0.60, 0.22),
        good: c(0.56, 0.78, 0.56), goodDeep: c(0.43, 0.66, 0.44),
        bad: c(0.87, 0.36, 0.44), badDeep: c(0.77, 0.25, 0.33),
        slate: c(0.45, 0.28, 0.30), slateDeep: c(0.35, 0.20, 0.22),
        cloud: c(1.00, 0.97, 0.93))

    static let forest = WorldPalette(
        paperLight: c(0.93, 0.96, 0.92), edgeLight: c(0.83, 0.90, 0.81), inkLight: c(0.22, 0.33, 0.24),
        paperDark: c(0.08, 0.11, 0.08), edgeDark: c(0.03, 0.05, 0.03), inkDark: c(0.92, 0.96, 0.91),
        primary: c(0.42, 0.66, 0.47), primaryDeep: c(0.30, 0.54, 0.36),
        soft: c(0.88, 0.93, 0.86), softShade: c(0.74, 0.84, 0.71),
        warm: c(0.89, 0.73, 0.42), warmDeep: c(0.80, 0.60, 0.28),
        good: c(0.55, 0.79, 0.55), goodDeep: c(0.42, 0.67, 0.43),
        bad: c(0.86, 0.45, 0.40), badDeep: c(0.76, 0.33, 0.28),
        slate: c(0.25, 0.35, 0.27), slateDeep: c(0.17, 0.26, 0.19),
        cloud: c(0.96, 0.99, 0.95))

    static let terracotta = WorldPalette(
        paperLight: c(0.97, 0.93, 0.89), edgeLight: c(0.91, 0.83, 0.76), inkLight: c(0.36, 0.26, 0.22),
        paperDark: c(0.12, 0.09, 0.08), edgeDark: c(0.06, 0.04, 0.03), inkDark: c(0.96, 0.92, 0.88),
        primary: c(0.80, 0.47, 0.36), primaryDeep: c(0.69, 0.35, 0.25),
        soft: c(0.93, 0.87, 0.81), softShade: c(0.84, 0.73, 0.64),
        warm: c(0.88, 0.68, 0.40), warmDeep: c(0.79, 0.55, 0.27),
        good: c(0.56, 0.72, 0.50), goodDeep: c(0.44, 0.60, 0.38),
        bad: c(0.83, 0.40, 0.36), badDeep: c(0.72, 0.29, 0.25),
        slate: c(0.38, 0.28, 0.24), slateDeep: c(0.29, 0.20, 0.17),
        cloud: c(0.99, 0.96, 0.92))

    static let graphite = WorldPalette(
        paperLight: c(0.96, 0.96, 0.96), edgeLight: c(0.80, 0.80, 0.80), inkLight: c(0.15, 0.15, 0.16),
        paperDark: c(0.11, 0.11, 0.12), edgeDark: c(0.04, 0.04, 0.05), inkDark: c(0.93, 0.93, 0.93),
        primary: c(0.45, 0.45, 0.48), primaryDeep: c(0.33, 0.33, 0.36),
        soft: c(0.86, 0.86, 0.87), softShade: c(0.71, 0.71, 0.73),
        warm: c(0.62, 0.62, 0.65), warmDeep: c(0.50, 0.50, 0.53),
        good: c(0.60, 0.72, 0.64), goodDeep: c(0.47, 0.60, 0.52),
        bad: c(0.89, 0.33, 0.33), badDeep: c(0.77, 0.23, 0.23),   // the one red pop
        slate: c(0.16, 0.16, 0.18), slateDeep: c(0.09, 0.09, 0.11),
        cloud: c(0.95, 0.95, 0.96))

    static let neon = WorldPalette(
        paperLight: c(0.13, 0.12, 0.18), edgeLight: c(0.05, 0.05, 0.09), inkLight: c(0.93, 0.92, 0.99),
        paperDark: c(0.10, 0.09, 0.15), edgeDark: c(0.03, 0.03, 0.06), inkDark: c(0.93, 0.92, 0.99),
        primary: c(0.62, 0.47, 0.98), primaryDeep: c(0.48, 0.33, 0.88),
        soft: c(0.33, 0.32, 0.45), softShade: c(0.24, 0.23, 0.35),
        warm: c(0.99, 0.85, 0.30), warmDeep: c(0.90, 0.72, 0.16),
        good: c(0.35, 0.93, 0.66), goodDeep: c(0.22, 0.80, 0.53),
        bad: c(0.99, 0.36, 0.52), badDeep: c(0.88, 0.24, 0.40),
        slate: c(0.91, 0.90, 0.99), slateDeep: c(0.66, 0.62, 0.88),
        cloud: c(0.95, 0.94, 1.00))

    static let monster = WorldPalette(
        paperLight: c(0.93, 0.97, 0.88), edgeLight: c(0.78, 0.88, 0.72), inkLight: c(0.31, 0.21, 0.45),
        paperDark: c(0.09, 0.12, 0.07), edgeDark: c(0.04, 0.06, 0.02), inkDark: c(0.93, 0.97, 0.89),
        primary: c(0.50, 0.80, 0.33), primaryDeep: c(0.38, 0.68, 0.23),
        soft: c(0.90, 0.95, 0.80), softShade: c(0.75, 0.85, 0.62),
        warm: c(0.64, 0.44, 0.94), warmDeep: c(0.51, 0.31, 0.84),
        good: c(0.72, 0.88, 0.32), goodDeep: c(0.58, 0.76, 0.21),
        bad: c(0.96, 0.36, 0.66), badDeep: c(0.86, 0.24, 0.54),
        slate: c(0.33, 0.22, 0.47), slateDeep: c(0.25, 0.15, 0.37),
        cloud: c(0.99, 0.99, 0.96))

    static let cosmos = WorldPalette(
        paperLight: c(0.10, 0.10, 0.20), edgeLight: c(0.03, 0.03, 0.10), inkLight: c(0.92, 0.92, 0.99),
        paperDark: c(0.08, 0.08, 0.17), edgeDark: c(0.02, 0.02, 0.08), inkDark: c(0.92, 0.92, 0.99),
        primary: c(0.55, 0.51, 0.95), primaryDeep: c(0.42, 0.38, 0.85),
        soft: c(0.32, 0.32, 0.50), softShade: c(0.23, 0.23, 0.39),
        warm: c(0.98, 0.82, 0.41), warmDeep: c(0.90, 0.70, 0.26),
        good: c(0.42, 0.90, 0.71), goodDeep: c(0.29, 0.78, 0.58),
        bad: c(0.95, 0.42, 0.47), badDeep: c(0.85, 0.30, 0.35),
        slate: c(0.91, 0.91, 0.99), slateDeep: c(0.64, 0.62, 0.88),
        cloud: c(0.96, 0.95, 1.00))

    static let blocks = WorldPalette(
        paperLight: c(0.94, 0.95, 0.97), edgeLight: c(0.82, 0.84, 0.89), inkLight: c(0.16, 0.24, 0.42),
        paperDark: c(0.09, 0.10, 0.13), edgeDark: c(0.03, 0.04, 0.06), inkDark: c(0.92, 0.94, 0.98),
        primary: c(0.89, 0.30, 0.27), primaryDeep: c(0.77, 0.20, 0.18),
        soft: c(0.93, 0.91, 0.85), softShade: c(0.80, 0.77, 0.68),
        warm: c(0.98, 0.78, 0.20), warmDeep: c(0.89, 0.65, 0.08),
        good: c(0.30, 0.70, 0.38), goodDeep: c(0.20, 0.58, 0.28),
        bad: c(0.92, 0.42, 0.20), badDeep: c(0.80, 0.31, 0.11),
        slate: c(0.18, 0.27, 0.47), slateDeep: c(0.12, 0.19, 0.36),
        cloud: c(0.97, 0.97, 0.98))

    static let balloon = WorldPalette(
        paperLight: c(0.90, 0.95, 1.00), edgeLight: c(0.74, 0.85, 0.96), inkLight: c(0.22, 0.32, 0.50),
        paperDark: c(0.07, 0.10, 0.16), edgeDark: c(0.02, 0.04, 0.08), inkDark: c(0.91, 0.95, 1.00),
        primary: c(0.93, 0.36, 0.39), primaryDeep: c(0.82, 0.25, 0.28),
        soft: c(0.94, 0.97, 1.00), softShade: c(0.78, 0.87, 0.96),
        warm: c(0.99, 0.80, 0.38), warmDeep: c(0.91, 0.67, 0.23),
        good: c(0.47, 0.80, 0.52), goodDeep: c(0.34, 0.68, 0.40),
        bad: c(0.90, 0.35, 0.55), badDeep: c(0.79, 0.24, 0.44),
        slate: c(0.24, 0.34, 0.53), slateDeep: c(0.17, 0.25, 0.42),
        cloud: c(0.98, 0.99, 1.00))

    static let dessert = WorldPalette(
        paperLight: c(0.99, 0.96, 0.91), edgeLight: c(0.94, 0.86, 0.75), inkLight: c(0.37, 0.25, 0.19),
        paperDark: c(0.13, 0.10, 0.08), edgeDark: c(0.06, 0.04, 0.03), inkDark: c(0.98, 0.94, 0.89),
        primary: c(0.94, 0.55, 0.62), primaryDeep: c(0.85, 0.42, 0.50),
        soft: c(0.97, 0.92, 0.82), softShade: c(0.88, 0.79, 0.64),
        warm: c(0.85, 0.61, 0.36), warmDeep: c(0.74, 0.49, 0.25),
        good: c(0.66, 0.79, 0.50), goodDeep: c(0.53, 0.67, 0.38),
        bad: c(0.83, 0.28, 0.36), badDeep: c(0.72, 0.19, 0.27),
        slate: c(0.36, 0.24, 0.18), slateDeep: c(0.27, 0.17, 0.12),
        cloud: c(1.00, 0.98, 0.94))

    static let holo = WorldPalette(
        paperLight: c(0.05, 0.04, 0.08), edgeLight: c(0.00, 0.00, 0.02), inkLight: c(0.97, 0.92, 1.00),
        paperDark: c(0.05, 0.04, 0.08), edgeDark: c(0.00, 0.00, 0.02), inkDark: c(0.97, 0.92, 1.00),
        primary: c(0.98, 0.42, 0.82), primaryDeep: c(0.80, 0.25, 0.68),
        soft: c(0.30, 0.26, 0.44), softShade: c(0.20, 0.17, 0.32),
        warm: c(0.62, 0.48, 1.00), warmDeep: c(0.47, 0.33, 0.90),
        good: c(0.35, 0.92, 0.86), goodDeep: c(0.20, 0.78, 0.72),
        bad: c(1.00, 0.32, 0.55), badDeep: c(0.88, 0.20, 0.44),
        slate: c(0.95, 0.90, 1.00), slateDeep: c(0.72, 0.60, 0.95),
        cloud: c(0.97, 0.95, 1.00))

    static let puffy = WorldPalette(
        paperLight: c(0.33, 0.60, 0.89), edgeLight: c(0.22, 0.48, 0.80), inkLight: c(0.10, 0.20, 0.38),
        paperDark: c(0.06, 0.12, 0.22), edgeDark: c(0.02, 0.05, 0.10), inkDark: c(0.92, 0.96, 1.00),
        primary: c(0.90, 0.32, 0.40), primaryDeep: c(0.78, 0.20, 0.30),
        soft: c(0.60, 0.83, 0.88), softShade: c(0.44, 0.70, 0.77),
        warm: c(0.96, 0.68, 0.22), warmDeep: c(0.87, 0.55, 0.10),
        good: c(0.38, 0.77, 0.62), goodDeep: c(0.26, 0.64, 0.50),
        bad: c(0.93, 0.36, 0.48), badDeep: c(0.82, 0.25, 0.37),
        slate: c(0.99, 1.00, 1.00), slateDeep: c(0.60, 0.78, 0.92),
        cloud: c(0.99, 1.00, 1.00))

    static let pop = WorldPalette(
        paperLight: c(1.00, 0.86, 0.10), edgeLight: c(0.94, 0.74, 0.00), inkLight: c(0.62, 0.10, 0.34),
        paperDark: c(0.19, 0.14, 0.02), edgeDark: c(0.10, 0.07, 0.00), inkDark: c(0.99, 0.94, 0.82),
        primary: c(0.96, 0.33, 0.60), primaryDeep: c(0.83, 0.20, 0.47),
        soft: c(1.00, 0.93, 0.55), softShade: c(0.92, 0.80, 0.35),
        warm: c(0.98, 0.55, 0.35), warmDeep: c(0.88, 0.42, 0.22),
        good: c(0.45, 0.75, 0.42), goodDeep: c(0.33, 0.62, 0.30),
        bad: c(0.85, 0.20, 0.32), badDeep: c(0.72, 0.12, 0.24),
        slate: c(0.72, 0.14, 0.42), slateDeep: c(0.56, 0.07, 0.31),
        cloud: c(1.00, 0.98, 0.90))

    static let googly = WorldPalette(
        paperLight: c(0.94, 0.92, 0.87), edgeLight: c(0.84, 0.81, 0.74), inkLight: c(0.16, 0.20, 0.28),
        paperDark: c(0.08, 0.13, 0.20), edgeDark: c(0.03, 0.06, 0.10), inkDark: c(0.95, 0.94, 0.90),
        primary: c(0.13, 0.44, 0.72), primaryDeep: c(0.07, 0.32, 0.58),
        soft: c(0.88, 0.89, 0.90), softShade: c(0.72, 0.74, 0.78),
        warm: c(0.97, 0.72, 0.20), warmDeep: c(0.88, 0.58, 0.08),
        good: c(0.32, 0.72, 0.55), goodDeep: c(0.22, 0.60, 0.44),
        bad: c(0.90, 0.34, 0.30), badDeep: c(0.78, 0.23, 0.20),
        slate: c(0.18, 0.24, 0.34), slateDeep: c(0.10, 0.15, 0.24),
        cloud: c(0.99, 0.98, 0.96))
}

extension NSColor {
    /// Perceived-luminance check, for worlds whose paper is dark in both looks.
    var isDarkColor: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.5
    }

    /// Mix toward white — dark-mode card elevation on a themed paper.
    func lifted(_ amount: CGFloat) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: c.redComponent + (1 - c.redComponent) * amount,
                       green: c.greenComponent + (1 - c.greenComponent) * amount,
                       blue: c.blueComponent + (1 - c.blueComponent) * amount, alpha: 1)
    }
}

// MARK: - Resolved style

/// The current world + appearance, resolved once per view:
///
///   @AppStorage(WorldStyle.themeKey) private var worldRaw = WorldTheme.pastel.rawValue
///   @Environment(\.colorScheme) private var scheme
///   private var world: WorldStyle { WorldStyle(raw: worldRaw, dark: scheme == .dark) }
struct WorldStyle {
    static let themeKey = "macon.worldTheme"

    let theme: WorldTheme
    let dark: Bool
    var box: WorldPalette { theme.palette }

    init(raw: String, dark: Bool) {
        self.theme = WorldTheme(rawValue: raw) ?? .pastel
        self.dark = dark
    }

    /// For contexts without SwiftUI plumbing (the privacy curtain window).
    static func current(dark: Bool) -> WorldStyle {
        WorldStyle(raw: UserDefaults.standard.string(forKey: themeKey) ?? "", dark: dark)
    }

    // Backdrop + text.
    var paper: Color { Color(nsColor: box.paper(dark: dark)) }
    var edge: Color { Color(nsColor: box.edge(dark: dark)) }
    var ink: Color { Color(nsColor: box.ink(dark: dark)) }

    // Clay slots.
    var primary: Color { Color(nsColor: box.primary) }
    var primaryDeep: Color { Color(nsColor: box.primaryDeep) }
    var soft: Color { Color(nsColor: box.soft) }
    var warm: Color { Color(nsColor: box.warm) }
    var good: Color { Color(nsColor: box.good) }
    var bad: Color { Color(nsColor: box.bad) }

    /// Opaque clay card fill over the paper. Keyed off the resolved paper's
    /// brightness, not the system scheme: always-dark worlds (neon, cosmos)
    /// need lifted cards even in light mode.
    var card: Color {
        let paper = box.paper(dark: dark)
        return Color(nsColor: paper.isDarkColor ? paper.lifted(0.09) : box.cloud)
    }
    /// Hairline card stroke.
    var line: Color { ink.opacity(0.1) }

    // State hues.
    func tint(_ state: RunnerState) -> Color {
        switch state {
        case .running:  return good
        case .starting: return warm
        case .stopped:  return ink.opacity(0.45)
        case .crashed:  return bad
        }
    }
    func tint(_ state: BuildState) -> Color {
        switch state {
        case .idle:      return ink.opacity(0.45)
        case .running:   return warm
        case .succeeded: return good
        case .failed:    return bad
        }
    }
    func tint(_ result: RunResult) -> Color {
        switch result {
        case .succeeded: return good
        case .failed:    return bad
        case .cancelled: return warm
        }
    }
}

// MARK: - Backdrop

/// The world's radial studio backdrop.
struct WorldBackdrop: View {
    let world: WorldStyle
    var body: some View {
        RadialGradient(colors: [world.paper, world.edge],
                       center: .center, startRadius: 120, endRadius: 750)
            .ignoresSafeArea()
    }
}

extension View {
    /// Standard world treatment for a Form/List pane: the themed backdrop
    /// behind transparent list chrome, controls tinted in the world's primary.
    func worldChrome(_ world: WorldStyle) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(WorldBackdrop(world: world))
            .tint(world.primary)
    }
}

// MARK: - Headings

/// Tracked-out rounded caps section header with a palette-tinted icon.
struct WorldSectionHeader: View {
    let title: String
    let symbol: String
    let world: WorldStyle
    var tint: Color?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.caption.weight(.bold))
                .foregroundStyle(tint ?? world.primary)
            Text(title.uppercased())
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(world.ink.opacity(0.55))
                .kerning(0.6)
            Spacer()
        }
        .textCase(nil)
    }
}

// MARK: - Small parts

/// Filled dot with a pulsing halo while `active`.
struct PulseDot: View {
    var color: Color
    var active: Bool = false
    var size: CGFloat = 11

    @State private var pulse = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: 2)
                    .scaleEffect(pulse ? 2.3 : 1)
                    .opacity(pulse ? 0 : 0.7)
            }
            Circle()
                .fill(color.gradient)
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                .shadow(color: color.opacity(active ? 0.85 : 0.35), radius: active ? 5 : 1.5)
        }
        .frame(width: size, height: size)
        .onAppear { if active { start() } }
        .onChange(of: active) { _, now in now ? start() : stop() }
    }

    private func start() {
        pulse = false
        withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { pulse = true }
    }
    private func stop() { withAnimation(.default) { pulse = false } }
}

/// Small status/label pill: tinted icon + text.
struct Pill: View {
    var text: String
    var systemImage: String
    var tint: Color
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(.caption, design: .rounded).weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// Compact metric chip on clay: icon · big value · caption.
struct StatChip: View {
    var icon: String
    var value: String
    var label: String
    var tint: Color
    var world: WorldStyle

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(.headline, design: .rounded).monospacedDigit())
                    .foregroundStyle(world.ink)
                Text(label)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(world.ink.opacity(0.55))
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(world.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(world.line))
    }
}

/// A puffy clay icon tile (header glyph).
struct ClayTile: View {
    var systemImage: String
    var fill: Color
    var size: CGFloat = 44
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(fill.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(.white.opacity(0.25)))
            .shadow(color: fill.opacity(0.35), radius: 6, y: 2)
    }
}

// MARK: - Buttons

/// The primary action — a puffy clay capsule in the world's signature hue.
struct ClayButtonStyle: ButtonStyle {
    let world: WorldStyle
    var fill: Color?

    func makeBody(configuration: Configuration) -> some View {
        let color = fill ?? world.primary
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 17).padding(.vertical, 9)
            .background(color, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.22)))
            .shadow(color: color.opacity(0.45), radius: configuration.isPressed ? 2 : 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// Quiet clay secondary button.
struct ClaySoftButtonStyle: ButtonStyle {
    let world: WorldStyle
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.medium))
            .foregroundStyle(danger ? world.bad : world.ink)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(world.card, in: Capsule())
            .overlay(Capsule().strokeBorder(danger ? world.bad.opacity(0.35) : world.line))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}
