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
    /// Visual appearance (background kind, color, glyph, image, hint).
    @Published var style: CurtainStyle {
        didSet {
            if let data = try? JSONEncoder().encode(style) {
                UserDefaults.standard.set(data, forKey: Self.styleKey)
            }
        }
    }

    /// Called whenever the wall is raised or lowered so capture can refresh
    /// which windows it excludes.
    var onChange: (() -> Void)?

    private var windows: [CurtainWindow] = []
    private var hotKey: GlobalHotKey?

    private static let msgKey = "companion.curtain.message"
    private static let styleKey = "companion.curtain.style"
    private static let passAccount = "companion.curtain.pass"
    private static let defaultMessage = "In use by MacOn — please don't touch."

    private init() {
        message = UserDefaults.standard.string(forKey: Self.msgKey) ?? Self.defaultMessage
        if let data = UserDefaults.standard.data(forKey: Self.styleKey),
           let s = try? JSONDecoder().decode(CurtainStyle.self, from: data) {
            style = s
        } else {
            style = CurtainStyle()
        }
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

    // MARK: Custom image

    /// Copy a chosen image into Application Support and use it as the backdrop.
    func setCustomImage(from url: URL) {
        let fm = FileManager.default
        guard let dir = try? appSupportDir() else { return }
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        let dest = dir.appendingPathComponent("curtain-background.\(ext)")
        // Clear any prior file(s).
        clearCustomImageFiles()
        do {
            try fm.copyItem(at: url, to: dest)
            style.imagePath = dest.path
            style.background = .image
        } catch {
            NSLog("MacOn: couldn't import curtain image — \(error.localizedDescription)")
        }
    }

    func clearCustomImage() {
        clearCustomImageFiles()
        style.imagePath = nil
        if style.background == .image { style.background = .aurora }
    }

    private func clearCustomImageFiles() {
        guard let dir = try? appSupportDir() else { return }
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(atPath: dir.path) {
            for name in items where name.hasPrefix("curtain-background.") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    private func appSupportDir() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacON", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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

// MARK: - Curtain colors

/// The curtain's accent presets — persisted by name (same names as the old
/// app-wide theme colors, so existing saved styles decode unchanged).
enum CurtainColor: String, CaseIterable, Identifiable, Codable {
    case blue, purple, pink, red, orange, green
    var id: String { rawValue }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }

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
    /// Diagonal gradient of this color (base → partner).
    var gradient: LinearGradient {
        LinearGradient(colors: [base, partner], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Style model

/// What the wall looks like. Persisted as JSON.
struct CurtainStyle: Codable, Equatable {
    var background: CurtainBackground = .aurora
    var color: CurtainColor = .blue
    var glyph: String = "hand.raised.fill"
    var glyphAnimation: CurtainGlyphAnimation = .breathe
    var showHint: Bool = true
    /// How the bright foreground moves — also the burn-in protection: keeping
    /// it moving stops any pixel staying lit in one place (this wall may sit up
    /// for hours). Defaults to a gentle drift.
    var motion: CurtainMotion = .drift
    var imagePath: String? = nil

    init() {}

    // Tolerant decoding so older saved styles (missing newer keys) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background     = try c.decodeIfPresent(CurtainBackground.self, forKey: .background) ?? .aurora
        color          = try c.decodeIfPresent(CurtainColor.self, forKey: .color) ?? .blue
        glyph          = try c.decodeIfPresent(String.self, forKey: .glyph) ?? "hand.raised.fill"
        glyphAnimation = try c.decodeIfPresent(CurtainGlyphAnimation.self, forKey: .glyphAnimation) ?? .breathe
        showHint       = try c.decodeIfPresent(Bool.self, forKey: .showHint) ?? true
        if let m = try c.decodeIfPresent(CurtainMotion.self, forKey: .motion) {
            motion = m
        } else if let old = try c.decodeIfPresent(Bool.self, forKey: .reduceBurnIn) {
            motion = old ? .drift : .none   // migrate the previous toggle
        }
        imagePath      = try c.decodeIfPresent(String.self, forKey: .imagePath)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(background, forKey: .background)
        try c.encode(color, forKey: .color)
        try c.encode(glyph, forKey: .glyph)
        try c.encode(glyphAnimation, forKey: .glyphAnimation)
        try c.encode(showHint, forKey: .showHint)
        try c.encode(motion, forKey: .motion)
        try c.encodeIfPresent(imagePath, forKey: .imagePath)
    }

    private enum CodingKeys: String, CodingKey {
        case background, color, glyph, glyphAnimation, showHint, motion, reduceBurnIn, imagePath
    }
}

/// How the bright foreground moves (and keeps pixels from burning in).
enum CurtainMotion: String, CaseIterable, Identifiable, Codable {
    case none, drift, bounce
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none:   return "Static"
        case .drift:  return "Gentle drift"
        case .bounce: return "DVD bounce"
        }
    }
}

enum CurtainBackground: String, CaseIterable, Identifiable, Codable {
    case aurora, gradient, solid, black, starfield, waves, orbs, rays, image, world
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aurora:    return "Aurora"
        case .gradient:  return "Gradient"
        case .solid:     return "Solid"
        case .black:     return "Pure Black"
        case .starfield: return "Stars"
        case .waves:     return "Waves"
        case .orbs:      return "Orbs"
        case .rays:      return "Rays"
        case .image:     return "Image"
        case .world:     return "3D World"
        }
    }
    var symbol: String {
        switch self {
        case .aurora:    return "sparkles"
        case .gradient:  return "square.fill.on.circle.fill"
        case .solid:     return "square.fill"
        case .black:     return "moon.fill"
        case .starfield: return "sparkle"
        case .waves:     return "water.waves"
        case .orbs:      return "circle.hexagongrid.fill"
        case .rays:      return "rays"
        case .image:     return "photo.fill"
        case .world:     return "cube.fill"
        }
    }
}

/// SF Symbol animation applied to the wall's glyph.
enum CurtainGlyphAnimation: String, CaseIterable, Identifiable, Codable {
    case none, breathe, pulse, bounce, wiggle, rotate, variableColor
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none:          return "None"
        case .breathe:       return "Breathe"
        case .pulse:         return "Pulse"
        case .bounce:        return "Bounce"
        case .wiggle:        return "Wiggle"
        case .rotate:        return "Rotate"
        case .variableColor: return "Variable Color"
        }
    }
}

/// Applies the chosen SF Symbol effect.
struct GlyphEffect: ViewModifier {
    var kind: CurtainGlyphAnimation
    @ViewBuilder func body(content: Content) -> some View {
        switch kind {
        case .none:          content
        case .breathe:       content.symbolEffect(.breathe)
        case .pulse:         content.symbolEffect(.pulse)
        case .bounce:        content.symbolEffect(.bounce, options: .repeating)
        case .wiggle:        content.symbolEffect(.wiggle, options: .repeating)
        case .rotate:        content.symbolEffect(.rotate)
        case .variableColor: content.symbolEffect(.variableColor.iterative)
        }
    }
}

/// Glyphs offered in the picker.
let curtainGlyphOptions = [
    "hand.raised.fill", "lock.fill", "moon.stars.fill", "cup.and.saucer.fill",
    "bolt.fill", "eye.slash.fill", "figure.walk", "powersleep", "exclamationmark.octagon.fill",
]

// MARK: - Backdrop

/// The animated/static background layer, driven entirely by the style.
struct CurtainBackdrop: View {
    var style: CurtainStyle

    @ViewBuilder
    var body: some View {
        let c = style.color
        switch style.background {
        case .aurora:
            ZStack {
                Color.black
                CurtainAurora(color: c).opacity(0.55)
                RadialGradient(colors: [c.base.opacity(0.25), .clear],
                               center: .center, startRadius: 10, endRadius: 640)
            }
        case .gradient:
            ZStack {
                Color.black
                LinearGradient(colors: [c.base.opacity(0.55), c.partner.opacity(0.30)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        case .solid:
            c.base.mix(with: .black, by: 0.72)
        case .black:
            Color.black
        case .starfield:
            ZStack {
                LinearGradient(colors: [.black, c.base.mix(with: .black, by: 0.85)],
                               startPoint: .top, endPoint: .bottom)
                Starfield(color: c.accent)
                RadialGradient(colors: [c.base.opacity(0.18), .clear],
                               center: .center, startRadius: 10, endRadius: 600)
            }
        case .waves:
            ZStack {
                LinearGradient(colors: [.black, c.base.mix(with: .black, by: 0.8)],
                               startPoint: .top, endPoint: .bottom)
                CurtainWaves(color: c)
            }
        case .orbs:
            ZStack {
                Color.black
                CurtainOrbs(color: c)
            }
        case .rays:
            ZStack {
                Color.black
                CurtainRays(color: c)
            }
        case .image:
            ZStack {
                Color.black
                if let path = style.imagePath, let img = NSImage(contentsOfFile: path) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                }
                Color.black.opacity(0.45)
            }
        case .world:
            // The world's dark paper — the 3D machine itself rides along with
            // the moving foreground (see CurtainStage).
            WorldBackdrop(world: WorldStyle.current(dark: true))
        }
    }
}

/// Slow color-tinted mesh (curtain flavor of AuroraBackground).
private struct CurtainAurora: View {
    var color: CurtainColor
    private var colors: [Color] {
        let a = color.base, b = color.partner, d = color.accent
        return [b, a, d, a, b, a, d, a, b]
    }
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: points(t), colors: colors)
                .blur(radius: 40)
        }
    }
    private func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        func o(_ amp: Double, _ speed: Double, _ phase: Double) -> Float { Float(amp * sin(t * speed + phase)) }
        return [
            [0, 0], [0.5 + o(0.10, 0.42, 0), 0], [1, 0],
            [0, 0.5 + o(0.10, 0.37, 1)], [0.5 + o(0.12, 0.31, 2), 0.5 + o(0.12, 0.53, 3)], [1, 0.5 + o(0.10, 0.47, 4)],
            [0, 1], [0.5 + o(0.10, 0.40, 5), 1], [1, 1],
        ]
    }
}

private func cfrac(_ x: Double) -> Double { x - floor(x) }

/// Triangle wave in [-1, 1] — linear up then down, for edge-bouncing motion.
private func triWave(_ u: Double) -> CGFloat {
    let s = u - floor(u)                       // 0..1
    let v = s < 0.5 ? s * 2 : 2 - s * 2        // 0..1..0
    return CGFloat(v * 2 - 1)                   // -1..1
}

/// Drifting star field, tinted by the accent color.
private struct Starfield: View {
    var color: Color
    private let stars: [(x: Double, y: Double, r: Double, spd: Double)] = (0..<90).map { i in
        let a = Double(i) + 1
        return (x: cfrac(sin(a * 12.9898) * 43758.5453),
                y: cfrac(sin(a * 78.233) * 12345.678),
                r: 0.7 + 2.2 * cfrac(sin(a * 3.17) * 991.0),
                spd: 0.5 + cfrac(sin(a * 5.51) * 217.0))
    }
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                for s in stars {
                    let y = cfrac(s.y + t * 0.02 * s.spd)
                    let rect = CGRect(x: s.x * size.width, y: y * size.height, width: s.r, height: s.r)
                    g.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.55)))
                }
            }
        }
    }
}

/// Flowing stacked sine waves.
private struct CurtainWaves: View {
    var color: CurtainColor
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let layers: [(Color, Double, Double, Double)] = [
                    (color.base.opacity(0.30), 0.55, 0.35, 0.0),
                    (color.partner.opacity(0.24), 0.68, 0.5, 1.7),
                    (color.accent.opacity(0.18), 0.80, 0.28, 3.2),
                ]
                for (col, baseY, speed, phase) in layers {
                    var path = Path()
                    let midY = size.height * baseY
                    let amp = size.height * 0.06
                    path.move(to: CGPoint(x: 0, y: size.height))
                    path.addLine(to: CGPoint(x: 0, y: midY))
                    var x: CGFloat = 0
                    while x <= size.width {
                        let y = midY + amp * sin(Double(x) / size.width * 6.283 * 1.5 + t * speed + phase)
                        path.addLine(to: CGPoint(x: x, y: y))
                        x += 8
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    g.fill(path, with: .color(col))
                }
            }
        }
    }
}

/// Big soft blurred orbs drifting slowly (bokeh).
private struct CurtainOrbs: View {
    var color: CurtainColor
    private let seeds = Array(0..<6)
    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(seeds, id: \.self) { i in
                        let a = Double(i) + 1
                        let cols = [color.base, color.partner, color.accent]
                        let dia = geo.size.height * (0.35 + 0.22 * cfrac(sin(a * 3.1) * 51.7))
                        let x = (0.5 + 0.42 * sin(t * (0.05 + 0.02 * a) + a)) * geo.size.width
                        let y = (0.5 + 0.40 * cos(t * (0.045 + 0.015 * a) + a * 1.3)) * geo.size.height
                        Circle()
                            .fill(cols[i % 3].opacity(0.28))
                            .frame(width: dia, height: dia)
                            .blur(radius: dia * 0.35)
                            .position(x: x, y: y)
                    }
                }
            }
        }
    }
}

/// Slowly rotating conic glow.
private struct CurtainRays: View {
    var color: CurtainColor
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            AngularGradient(
                gradient: Gradient(colors: [
                    color.base.opacity(0.0), color.base.opacity(0.35),
                    color.partner.opacity(0.0), color.accent.opacity(0.32),
                    color.base.opacity(0.0),
                ]),
                center: .center,
                angle: .degrees(t * 6))
            .blur(radius: 60)
            .overlay(RadialGradient(colors: [.clear, .black.opacity(0.6)],
                                    center: .center, startRadius: 40, endRadius: 700))
        }
    }
}

// MARK: - Stage (backdrop + glyph + message)

/// The full visual, sized to fill whatever frame it's given. Used at screen
/// size in the window and scaled down in the settings preview.
struct CurtainStage: View {
    var style: CurtainStyle
    var message: String
    var showHint: Bool
    var animate: Bool = true

    @State private var pulse = false
    @State private var driftX = false
    @State private var driftY = false

    private var driftOn: Bool { animate && style.motion == .drift }
    private var bounceOn: Bool { animate && style.motion == .bounce }

    var body: some View {
        ZStack {
            CurtainBackdrop(style: style)

            if bounceOn {
                bounceForeground
            } else {
                // Gentle drift: two out-of-sync ~70–90s sweeps trace a slow 2-D
                // path via implicit animation (no per-frame re-render, so the
                // glyph and pulse animations aren't disturbed).
                foreground
                    .offset(x: driftOn ? (driftX ? 26 : -26) : 0,
                            y: driftOn ? (driftY ? 20 : -16) : 0)
                    .animation(.easeInOut(duration: 67).repeatForever(autoreverses: true), value: driftX)
                    .animation(.easeInOut(duration: 89).repeatForever(autoreverses: true), value: driftY)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            if animate { pulse = true }
            if driftOn { driftX = true; driftY = true }
        }
    }

    /// DVD-logo bounce: the content travels in straight lines and ricochets off
    /// the edges (two triangle waves at different rates trace the classic path).
    private var bounceForeground: some View {
        GeometryReader { geo in
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                // The 3D machine is taller than the glyph — keep it on-screen.
                let halfH: CGFloat = style.background == .world ? 330 : 200
                let ax = max(0, geo.size.width / 2 - min(geo.size.width * 0.30, 380))
                let ay = max(0, geo.size.height / 2 - min(geo.size.height * 0.24, halfH))
                foreground
                    .position(x: geo.size.width / 2 + triWave(t * 0.045) * ax,
                              y: geo.size.height / 2 + triWave(t * 0.032) * ay)
            }
        }
    }

    private var foreground: some View {
        VStack(spacing: 22) {
            if style.background == .world {
                // The world's signature clay piece is the wandering mascot
                // (gear, blob, brick tower, balloon, donut, planet) — it
                // drifts or DVD-bounces with the rest of the foreground.
                WorldSprite(dark: true, theme: WorldStyle.current(dark: true).theme)
                    .frame(width: 280, height: 300)
            } else {
                ZStack {
                    Circle().fill(style.color.base.opacity(0.16))
                        .frame(width: 128, height: 128)
                        .scaleEffect(pulse ? 1.12 : 0.94)
                    Image(systemName: style.glyph)
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(style.color.gradient)
                        .modifier(GlyphEffect(kind: animate ? style.glyphAnimation : .none))
                }
                .animation(animate ? .easeInOut(duration: 1.8).repeatForever(autoreverses: true) : nil, value: pulse)
            }

            VStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                Text("This Mac is being used remotely.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: 640)

            if showHint {
                Label("Press ⌃⌥⌘U to unlock", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 8)
            }
        }
        .padding(40)
    }
}

// MARK: - Live preview (for Settings)

/// A scaled, rounded preview that mirrors the current style + message live.
struct CurtainPreview: View {
    @ObservedObject var curtain: PrivacyCurtain
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 1440
            CurtainStage(style: curtain.style, message: curtain.message, showHint: curtain.style.showHint)
                .frame(width: 1440, height: 900)
                .scaleEffect(s, anchor: .topLeading)
        }
        .aspectRatio(1440.0 / 900.0, contentMode: .fit)
        .frame(maxWidth: 400)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

// MARK: - Window content

private struct CurtainView: View {
    @ObservedObject var curtain: PrivacyCurtain
    var primary: Bool

    @State private var code = ""
    @State private var shake: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            CurtainStage(style: curtain.style,
                         message: curtain.message,
                         showHint: curtain.style.showHint && !(primary && curtain.unlocking))

            if primary && curtain.unlocking {
                VStack {
                    Spacer()
                    passcodeCard.padding(.bottom, 90)
                }
            }
        }
        .onChange(of: curtain.unlocking) { _, now in
            if now { focused = true } else { code = "" }
        }
        .onChange(of: curtain.wrongAttempts) { _, _ in
            code = ""
            withAnimation(.default) { shake = 1 }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.25)) { shake = 0 }
        }
    }

    private var world: WorldStyle { .current(dark: true) }

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
                    .buttonStyle(ClaySoftButtonStyle(world: world))
                Button("Unlock") { curtain.submit(code) }
                    .buttonStyle(ClayButtonStyle(world: world))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .offset(x: shake == 0 ? 0 : -10)
    }
}
