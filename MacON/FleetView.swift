//
//  FleetView.swift
//  MacON
//
//  The fleet map: this Mac in the middle, every paired device tied to it
//  with a real string — the same verlet ropes as the Flows canvas. A device
//  that's talking to the server right now glows green and its string shows
//  in color; quiet ones hang faded. Cards are draggable, because strings
//  that swing are the whole point.
//

import SwiftUI

struct FleetView: View {
    let world: WorldStyle
    @EnvironmentObject private var companion: CompanionManager

    /// Card centers, keyed by device short-token ("@mac" = this Mac).
    @State private var positions: [String: CGPoint] = [:]
    @State private var dragOrigin: (id: String, at: CGPoint)?
    @State private var ropes = RopeBox()
    @State private var viewSize: CGSize = .zero
    @State private var detail: FleetDeviceDTO?

    private static let macKey = "@mac"
    private static let macW: CGFloat = 220, macH: CGFloat = 86
    private static let devW: CGFloat = 190, devH: CGFloat = 76

    private var snapshot: FleetDevicesDTO { companion.fleetSnapshot() }

    var body: some View {
        GeometryReader { geo in
            let snap = snapshot
            ZStack {
                WorldBackdrop(world: world)

                ropeLayer(snap)

                macCard(snap)
                    .position(positions[Self.macKey] ?? center(geo.size))
                    .gesture(cardDrag(Self.macKey))

                ForEach(snap.devices) { device in
                    deviceCard(device)
                        .position(positions[device.short] ?? center(geo.size))
                        .gesture(cardDrag(device.short))
                        .onTapGesture { detail = device }
                        .popover(isPresented: Binding(
                            get: { detail?.short == device.short },
                            set: { if !$0 { detail = nil } })) {
                            FleetDeviceDetail(device: device, world: world) {
                                companion.revoke(short: device.short)
                                detail = nil
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                companion.revoke(short: device.short)
                            } label: { Label("Unpair \(device.label)", systemImage: "trash") }
                        }
                }

                if snap.devices.isEmpty { emptyHint }
            }
            .coordinateSpace(name: "fleet")
            .onAppear {
                viewSize = geo.size
                layout(snap, in: geo.size)
            }
            .onChange(of: geo.size) { _, size in
                viewSize = size
                layout(snap, in: size)
            }
            .onChange(of: snap.devices.map(\.short)) { _, _ in
                layout(snapshot, in: viewSize)
            }
        }
        .navigationTitle("Fleet")
        .task {
            // Catch fresh pairings while the map is open.
            while !Task.isCancelled {
                companion.refreshDevices()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Layout

    private func center(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height * 0.42)
    }

    /// The Mac holds the middle; new devices take seats on a ring below it.
    /// Dragged cards keep their spot — only unseen keys get placed.
    private func layout(_ snap: FleetDevicesDTO, in size: CGSize) {
        guard size.width > 50 else { return }
        if positions[Self.macKey] == nil { positions[Self.macKey] = center(size) }
        let mac = positions[Self.macKey] ?? center(size)
        let radius = min(size.width, size.height) * 0.34
        let fresh = snap.devices.filter { positions[$0.id] == nil }
        guard !fresh.isEmpty else { return }
        let total = snap.devices.count
        for device in fresh {
            let index = snap.devices.firstIndex(of: device) ?? 0
            // Fan across the lower half-circle so strings hang naturally,
            // clamped so no card pokes out of the pane.
            let t = total == 1 ? 0.5 : Double(index) / Double(total - 1)
            let angle = Double.pi * (0.15 + 0.7 * t)
            let x = min(max(mac.x + cos(angle) * radius, Self.devW / 2 + 10),
                        size.width - Self.devW / 2 - 10)
            let y = min(max(mac.y + sin(angle) * radius, Self.devH / 2 + 10),
                        size.height - Self.devH / 2 - 10)
            positions[device.id] = CGPoint(x: x, y: y)
        }
    }

    private func cardDrag(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("fleet"))
            .onChanged { v in
                if dragOrigin?.id != id {
                    dragOrigin = (id, positions[id] ?? .zero)
                }
                guard let origin = dragOrigin, origin.id == id else { return }
                positions[id] = CGPoint(x: origin.at.x + v.translation.width,
                                        y: origin.at.y + v.translation.height)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    // MARK: Ropes

    private func ropeLayer(_ snap: FleetDevicesDTO) -> some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, _ in
                let steps = ropes.tick(now: timeline.date.timeIntervalSinceReferenceDate)
                var alive = Set<String>()
                let mac = positions[Self.macKey] ?? .zero

                for device in snap.devices {
                    guard let to = positions[device.short] else { continue }
                    alive.insert(device.short)
                    let sim = ropes.sim(device.short, from: mac, to: to)
                    if steps == 0 { sim.pin(from: mac, to: to) }
                    for _ in 0..<steps { sim.step(from: mac, to: to, dt: RopeBox.h) }

                    let color = device.live ? world.good : world.ink.opacity(0.28)
                    var path = Path()
                    path.move(to: sim.pts[0])
                    for i in 1..<sim.pts.count - 1 {
                        let mid = CGPoint(x: (sim.pts[i].x + sim.pts[i + 1].x) / 2,
                                          y: (sim.pts[i].y + sim.pts[i + 1].y) / 2)
                        path.addQuadCurve(to: mid, control: sim.pts[i])
                    }
                    path.addLine(to: sim.pts[sim.pts.count - 1])
                    ctx.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    for end in [sim.pts[0], sim.pts[sim.pts.count - 1]] {
                        ctx.fill(Path(ellipseIn: CGRect(x: end.x - 4.5, y: end.y - 4.5,
                                                        width: 9, height: 9)),
                                 with: .color(color))
                    }
                }
                ropes.prune(keeping: alive)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Cards

    private func macCard(_ snap: FleetDevicesDTO) -> some View {
        let liveCount = snap.devices.filter(\.live).count
        return HStack(spacing: 11) {
            Image(systemName: "desktopcomputer")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(world.primary, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(snap.mac)
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(world.ink)
                    .lineLimit(1)
                Text("This Mac · \(liveCount) live of \(snap.devices.count)")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(world.ink.opacity(0.55))
            }
            Spacer(minLength: 0)
            PulseDot(color: companion.isRunning ? world.good : world.bad,
                     active: companion.isRunning, size: 10)
        }
        .padding(.horizontal, 13)
        .frame(width: Self.macW, height: Self.macH)
        .background(world.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(world.primary.opacity(0.6), lineWidth: 2))
        .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
    }

    private func deviceCard(_ device: FleetDeviceDTO) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.kind == "ipad" ? "ipad" : "iphone")
                .font(.body.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(device.live ? world.good : Color(nsColor: world.box.slate),
                            in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.label)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(world.ink)
                    .lineLimit(1)
                Text(status(device))
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(device.live ? world.good : world.ink.opacity(0.5))
            }
            Spacer(minLength: 0)
            if device.live { PulseDot(color: world.good, active: true, size: 8) }
        }
        .padding(.horizontal, 12)
        .frame(width: Self.devW, height: Self.devH)
        .background(world.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(device.live ? world.good.opacity(0.7) : world.line,
                          lineWidth: device.live ? 2 : 1.5))
        .opacity(device.live ? 1 : 0.8)
        .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
    }

    private func status(_ device: FleetDeviceDTO) -> String {
        guard !device.live else { return "Connected now" }
        guard let s = device.seconds else { return "Quiet since launch" }
        if s < 60 { return "Seen \(s)s ago" }
        if s < 3600 { return "Seen \(s / 60)m ago" }
        return "Seen \(s / 3600)h ago"
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "ipad.and.iphone")
                .font(.system(size: 38))
                .foregroundStyle(world.ink.opacity(0.3))
            Text("Nothing on the string yet")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(world.ink.opacity(0.7))
            Text("Pair an iPhone or iPad from Settings → Companion app\nand it appears here, tied to this Mac.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(world.ink.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .offset(y: 120)
        .allowsHitTesting(false)
    }
}

// MARK: - Device detail (popover)

private struct FleetDeviceDetail: View {
    let device: FleetDeviceDTO
    let world: WorldStyle
    let onUnpair: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: device.kind == "ipad" ? "ipad" : "iphone")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(device.live ? world.good : world.primary,
                                in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.label)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text(device.live ? "Connected now" : "Not connected")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(device.live ? world.good : .secondary)
                }
            }
            Divider()
            row("Full name", device.name)
            row("Type", device.kind == "ipad" ? "iPad" : "iPhone")
            row("Last seen", lastSeen)
            row("Paired", device.pairedAt.formatted(date: .abbreviated, time: .shortened))
            row("Token", device.short, mono: true)
            Divider()
            Button(role: .destructive, action: onUnpair) {
                Label("Unpair this device", systemImage: "trash")
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private var lastSeen: String {
        if device.live { return "Now" }
        guard let s = device.seconds else { return "Quiet since launch" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(.system(.footnote, design: mono ? .monospaced : .rounded))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
