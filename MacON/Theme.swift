//
//  Theme.swift
//  MacON
//
//  The app's visual language: brand palette, animated status indicators, stat
//  chips, card + button styles, and a gentle animated background. Kept tasteful
//  — lively, not loud.
//

import SwiftUI

// MARK: - Palette

enum Brand {
    static let blue    = Color(red: 0.231, green: 0.510, blue: 0.965)
    static let indigo  = Color(red: 0.388, green: 0.400, blue: 0.945)
    static let cyan    = Color(red: 0.204, green: 0.722, blue: 0.949)
    static let amber   = Color(red: 0.961, green: 0.620, blue: 0.102)
    static let emerald = Color(red: 0.063, green: 0.725, blue: 0.506)
    static let rose    = Color(red: 0.961, green: 0.247, blue: 0.369)

    /// Signature diagonal gradient (blue → indigo).
    static let gradient = LinearGradient(colors: [blue, indigo],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    /// A soft top-to-bottom gradient derived from this color, for fills.
    var duo: LinearGradient {
        LinearGradient(colors: [self, opacity(0.7)], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Animated status dot

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

// MARK: - Stat chip

/// Compact metric pill: icon · big value · caption.
struct StatChip: View {
    var icon: String
    var value: String
    var label: String
    var tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.headline.monospacedDigit())
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

// MARK: - Pill

/// Small status/label pill: tinted icon + text.
struct Pill: View {
    var text: String
    var systemImage: String
    var tint: Color
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// A gradient icon tile (used as a header glyph).
struct IconTile: View {
    var systemImage: String
    var gradient: LinearGradient = Brand.gradient
    var size: CGFloat = 44
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25)))
            .shadow(color: Brand.blue.opacity(0.35), radius: 6, y: 2)
    }
}

/// Section header for themed forms: tinted icon + title.
struct FormSectionHeader: View {
    var title: String
    var systemImage: String
    var tint: Color = Brand.blue
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption).foregroundStyle(tint)
            Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
    }
}

// MARK: - Card

private struct Card: ViewModifier {
    var tint: Color?
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill((tint ?? .clear).opacity(0.07)))
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.09)))
            .shadow(color: .black.opacity(0.13), radius: 9, y: 3)
    }
}

extension View {
    func card(tint: Color? = nil, radius: CGFloat = 16) -> some View {
        modifier(Card(tint: tint, radius: radius))
    }

    /// Subtle lift on hover (macOS pointer).
    func hoverLift() -> some View { modifier(HoverLift()) }
}

private struct HoverLift: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.spring(duration: 0.3), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Buttons

/// Gradient capsule — the primary action.
struct PrimaryButtonStyle: ButtonStyle {
    var fill: LinearGradient = Brand.gradient
    var glow: Color = Brand.blue
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 17).padding(.vertical, 9)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.22)))
            .shadow(color: glow.opacity(0.45), radius: configuration.isPressed ? 2 : 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// Frosted secondary button.
struct SoftButtonStyle: ButtonStyle {
    var danger = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(danger ? Color.red : .primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

// MARK: - Aurora background

/// A slow, low-key animated mesh gradient for empty/welcome states.
struct AuroraBackground: View {
    var intensity: Double = 0.4

    private let colors: [Color] = [
        Brand.indigo, Brand.blue, Brand.cyan,
        Brand.blue, Brand.indigo, Brand.blue,
        Brand.cyan, Brand.blue, Brand.indigo,
    ]

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: points(t), colors: colors)
                .opacity(intensity)
                .blur(radius: 34)
                .ignoresSafeArea()
        }
    }

    private func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        func o(_ amp: Double, _ speed: Double, _ phase: Double) -> Float {
            Float(amp * sin(t * speed + phase))
        }
        return [
            [0, 0],                      [0.5 + o(0.10, 0.42, 0), 0],           [1, 0],
            [0, 0.5 + o(0.10, 0.37, 1)], [0.5 + o(0.12, 0.31, 2), 0.5 + o(0.12, 0.53, 3)], [1, 0.5 + o(0.10, 0.47, 4)],
            [0, 1],                      [0.5 + o(0.10, 0.40, 5), 1],           [1, 1],
        ]
    }
}
