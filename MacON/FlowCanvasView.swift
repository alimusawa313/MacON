//
//  FlowCanvasView.swift
//  MacON
//
//  The Mac's flow editor: clay block cards on a pannable, zoomable canvas,
//  tied together with strings that behave like strings — each connection is a
//  verlet-simulated rope (gravity, damping, distance constraints) that sags
//  at rest and swings when you drag a block. Drag out of a block's right port
//  to pull a fresh string; drop it on another block's left port to connect.
//  Runs execute right here through FlowEngine; the cards glow with results.
//
//  Ported from the companion's canvas — same physics, AppKit-native input.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Rope physics

/// One string between two anchors: a verlet chain with pinned ends.
final class RopeSim {
    private(set) var pts: [CGPoint]
    private var prev: [CGPoint]
    private let n: Int

    init(from: CGPoint, to: CGPoint, segments: Int = 13) {
        n = segments
        pts = (0...segments).map { i in
            let t = CGFloat(i) / CGFloat(segments)
            return CGPoint(x: from.x + (to.x - from.x) * t,
                           y: from.y + (to.y - from.y) * t + sin(t * .pi) * 14)
        }
        prev = pts
    }

    func pin(from: CGPoint, to: CGPoint) {
        pts[0] = from; prev[0] = from
        pts[n] = to;   prev[n] = to
    }

    func step(from: CGPoint, to: CGPoint, dt: CGFloat) {
        let dtc = min(max(dt, 0), 1 / 30)
        let g: CGFloat = 2400 * dtc * dtc
        let damp: CGFloat = 0.985
        for i in 1..<n {
            let p = pts[i]
            pts[i] = CGPoint(x: p.x + (p.x - prev[i].x) * damp,
                             y: p.y + (p.y - prev[i].y) * damp + g)
            prev[i] = p
        }
        pts[0] = from; prev[0] = from
        pts[n] = to;   prev[n] = to

        let span = hypot(to.x - from.x, to.y - from.y)
        let rest = max(span * 1.08, 50) / CGFloat(n)
        for _ in 0..<3 {
            for i in 0..<n {
                let a = pts[i], b = pts[i + 1]
                let dx = b.x - a.x, dy = b.y - a.y
                let d = max(hypot(dx, dy), 0.0001)
                let corr = (d - rest) / d * 0.5
                let ox = dx * corr, oy = dy * corr
                if i == 0 {
                    pts[i + 1].x -= ox * 2; pts[i + 1].y -= oy * 2
                } else if i + 1 == n {
                    pts[i].x += ox * 2; pts[i].y += oy * 2
                } else {
                    pts[i].x += ox;     pts[i].y += oy
                    pts[i + 1].x -= ox; pts[i + 1].y -= oy
                }
            }
            pts[0] = from; pts[n] = to
        }
    }
}

/// The canvas's rope pool — fixed 60Hz timestep so the sag equilibrium is
/// identical at any display refresh rate (ProMotion ramping would otherwise
/// re-settle every string on its own).
final class RopeBox {
    static let h: CGFloat = 1.0 / 60.0

    private var sims: [String: RopeSim] = [:]
    private var last: TimeInterval = 0
    private var acc: TimeInterval = 0

    func tick(now: TimeInterval) -> Int {
        if last == 0 { last = now; return 1 }
        acc += min(now - last, 0.25)
        last = now
        let steps = min(Int(acc / TimeInterval(Self.h)), 4)
        acc -= TimeInterval(steps) * TimeInterval(Self.h)
        return steps
    }

    func sim(_ key: String, from: CGPoint, to: CGPoint) -> RopeSim {
        if let s = sims[key] { return s }
        let s = RopeSim(from: from, to: to)
        sims[key] = s
        return s
    }

    func remove(_ key: String) { sims[key] = nil }
    func prune(keeping valid: Set<String>) {
        sims = sims.filter { valid.contains($0.key) }
    }
}

// MARK: - Canvas

struct FlowCanvasView: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(WorldStyle.themeKey) private var worldRaw = WorldTheme.pastel.rawValue

    let flows: FlowsModel
    @State private var flow: Flow

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var pinchStart: (scale: CGFloat, offset: CGSize)?

    @State private var dragOrigin: (id: String, at: CGPoint)?
    @State private var wire: (from: String, port: String, at: CGPoint)?
    @State private var cutTarget: (id: String, at: CGPoint)?

    @State private var inspecting: FlowNode?
    @State private var showPalette = false
    @State private var showHistory = false
    @State private var renameText = ""
    @State private var renaming = false
    @State private var viewSize: CGSize = .zero
    @State private var didFit = false

    @State private var ropes = RopeBox()

    private static let nodeW: CGFloat = 178
    private static let nodeH: CGFloat = 72

    private var world: WorldStyle { WorldStyle(raw: worldRaw, dark: scheme == .dark) }

    init(flows: FlowsModel, flowId: String) {
        self.flows = flows
        let found = flows.flows.first { $0.id == flowId }
        _flow = State(initialValue: found ?? Flow.empty(name: "Flow"))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                WorldBackdrop(world: world)
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture(coordinateSpace: .named("flowcanvas")) { location in
                        tapCanvas(at: location)
                    }

                ropeLayer
                nodeLayer

                if let cut = cutTarget { cutButton(cut) }
                if flow.nodes.isEmpty { emptyHint }
                if showPalette { palette(height: geo.size.height) }
            }
            .coordinateSpace(name: "flowcanvas")
            .onDrop(of: [.plainText], isTargeted: nil) { providers, location in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let type = object as? String else { return }
                    Task { @MainActor in addNode(BlockSpec.spec(type), at: toWorld(location)) }
                }
                return true
            }
            .simultaneousGesture(pinchGesture(center: CGPoint(x: geo.size.width / 2,
                                                              y: geo.size.height / 2)))
            .overlay(alignment: .bottomTrailing) { runStatus }
            .overlay(alignment: .bottomLeading) { paletteButton }
            .onAppear {
                viewSize = geo.size
                if flow.nodes.isEmpty { showPalette = true }
                fitOnce(geo.size)
            }
            .onChange(of: geo.size) { _, size in viewSize = size; fitOnce(size) }
        }
        .clipped()
        .navigationTitle(flow.name)
        .toolbar { toolbarItems }
        .worldColorScheme()
        .sheet(item: $inspecting) { node in
            NodeInspector(node: nodeBinding(node), world: world, flows: flows,
                          result: flows.nodeResult(node.id, in: flow)) {
                removeNode(node.id)
                inspecting = nil
            }
            .frame(minWidth: 460, minHeight: 560)
            .worldColorScheme()
        }
        .sheet(isPresented: $showHistory) {
            FlowRunHistoryView(flow: flow, flows: flows, world: world)
                .frame(minWidth: 520, minHeight: 560)
                .worldColorScheme()
        }
        .alert("Rename flow", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { flow.name = name }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: flow) { _, f in flows.stage(f) }
        .onDisappear {
            flows.flush(flow)
            flows.clearRun()
        }
        .task { await flows.loadModels() }
    }

    // MARK: Layers

    private var ropeLayer: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, _ in
                let steps = ropes.tick(now: timeline.date.timeIntervalSinceReferenceDate)
                var alive = Set<String>()

                func advance(_ sim: RopeSim, from: CGPoint, to: CGPoint) {
                    if steps == 0 { sim.pin(from: from, to: to) }
                    for _ in 0..<steps { sim.step(from: from, to: to, dt: RopeBox.h) }
                }

                for edge in flow.edges {
                    guard let a = outAnchor(edge.from, port: edge.port),
                          let b = inAnchor(edge.to) else { continue }
                    alive.insert(edge.id)
                    let sim = ropes.sim(edge.id, from: a, to: b)
                    advance(sim, from: a, to: b)
                    draw(ctx, rope: sim.pts, color: ropeColor(edge),
                         highlight: cutTarget?.id == edge.id)
                }

                if let wire, let a = outAnchor(wire.from, port: wire.port) {
                    alive.insert("@wire")
                    let sim = ropes.sim("@wire", from: a, to: wire.at)
                    advance(sim, from: a, to: wire.at)
                    draw(ctx, rope: sim.pts, color: world.primary.opacity(0.8), highlight: false)
                }

                ropes.prune(keeping: alive)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ ctx: GraphicsContext, rope pts: [CGPoint],
                      color: Color, highlight: Bool) {
        var path = Path()
        path.move(to: pts[0])
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2,
                              y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])

        if highlight {
            ctx.stroke(path, with: .color(world.bad.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 7 * scale, lineCap: .round))
        }
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: 3.5 * scale, lineCap: .round))
        for end in [pts[0], pts[pts.count - 1]] {
            let r = 4.5 * scale
            ctx.fill(Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(color))
        }
    }

    private func ropeColor(_ edge: FlowEdge) -> Color {
        guard let node = flow.nodes.first(where: { $0.id == edge.from }) else {
            return world.ink.opacity(0.5)
        }
        if edge.port == "true" || edge.port == "done" { return world.good }
        if edge.port == "false" { return world.bad }
        if edge.port == "each" { return world.warm }
        return Color(nsColor: BlockSpec.spec(node.type).category.tint(world.box)).opacity(0.85)
    }

    private var nodeLayer: some View {
        ZStack {
            ForEach(flow.nodes) { node in
                nodeCard(node)
                    .position(x: node.x + Self.nodeW / 2, y: node.y + Self.nodeH / 2)
            }
        }
        .scaleEffect(scale, anchor: .topLeading)
        .offset(offset)
    }

    // MARK: Node cards

    private func nodeCard(_ node: FlowNode) -> some View {
        let spec = BlockSpec.spec(node.type)
        let tint = Color(nsColor: spec.category.tint(world.box))
        let result = flows.nodeResult(node.id, in: flow)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: spec.symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(tint, in: RoundedRectangle(cornerRadius: 7))
                Text(node.name ?? spec.title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(world.ink)
                    .lineLimit(1)
                Spacer(minLength: 2)
                statusBadge(result)
            }
            Text(spec.summary(node))
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(world.ink.opacity(0.55))
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(width: Self.nodeW, height: Self.nodeH, alignment: .topLeading)
        .background(world.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(borderColor(result, tint: tint),
                              lineWidth: result?.status == "running" ? 2.5 : 1.5)
        )
        .opacity(node.enabled ? 1 : 0.45)
        .overlay(alignment: .leading) {
            if spec.hasInput { inPort(tint: tint).offset(x: -7) }
        }
        .overlay(alignment: .trailing) { outPorts(node, spec: spec).offset(x: 7) }
        .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
        .gesture(nodeDrag(node))
        .onTapGesture { inspecting = node }
        .contextMenu {
            Button { inspecting = node } label: { Label("Configure", systemImage: "slider.horizontal.3") }
            Button { toggleEnabled(node.id) } label: {
                Label(node.enabled ? "Disable" : "Enable",
                      systemImage: node.enabled ? "pause.circle" : "play.circle")
            }
            Button { duplicateNode(node) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { removeNode(node.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func borderColor(_ result: FlowNodeResult?, tint: Color) -> Color {
        switch result?.status {
        case "running": return tint
        case "ok":      return world.good
        case "failed":  return world.bad
        case "skipped": return world.ink.opacity(0.25)
        default:        return world.line
        }
    }

    @ViewBuilder
    private func statusBadge(_ result: FlowNodeResult?) -> some View {
        switch result?.status {
        case "running": ProgressView().controlSize(.small)
        case "ok":
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(world.good)
        case "failed":
            Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(world.bad)
        case "skipped":
            Image(systemName: "minus.circle").font(.caption).foregroundStyle(world.ink.opacity(0.35))
        default: EmptyView()
        }
    }

    private func inPort(tint: Color) -> some View {
        Circle()
            .fill(world.card)
            .overlay(Circle().strokeBorder(tint, lineWidth: 2.5))
            .frame(width: 14, height: 14)
    }

    private func outPorts(_ node: FlowNode, spec: BlockSpec) -> some View {
        VStack(spacing: 14) {
            ForEach(spec.ports, id: \.self) { port in
                Circle()
                    .fill(portColor(port, spec: spec))
                    .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                    .frame(width: 16, height: 16)
                    .contentShape(Circle().inset(by: -12))
                    .gesture(wireDrag(node, port: port))
            }
        }
    }

    private func portColor(_ port: String, spec: BlockSpec) -> Color {
        if port == "true" || port == "done" { return world.good }
        if port == "false" { return world.bad }
        if port == "each" { return world.warm }
        return Color(nsColor: spec.category.tint(world.box))
    }

    // MARK: Anchors (screen space)

    private func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.width, y: p.y * scale + offset.height)
    }

    private func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.width) / scale, y: (p.y - offset.height) / scale)
    }

    private func inAnchor(_ id: String) -> CGPoint? {
        guard let node = flow.nodes.first(where: { $0.id == id }) else { return nil }
        return toScreen(CGPoint(x: node.x - 7, y: node.y + Self.nodeH / 2))
    }

    private func outAnchor(_ id: String, port: String) -> CGPoint? {
        guard let node = flow.nodes.first(where: { $0.id == id }) else { return nil }
        let spec = BlockSpec.spec(node.type)
        let count = spec.ports.count
        let idx = CGFloat(spec.ports.firstIndex(of: port) ?? 0)
        let y: CGFloat = count == 1
            ? node.y + Self.nodeH / 2
            : node.y + Self.nodeH / 2 + (idx - CGFloat(count - 1) / 2) * 30
        return toScreen(CGPoint(x: node.x + Self.nodeW + 7, y: y))
    }

    // MARK: Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if panStart == nil { panStart = offset }
                offset = CGSize(width: panStart!.width + v.translation.width,
                                height: panStart!.height + v.translation.height)
            }
            .onEnded { _ in panStart = nil }
    }

    private func pinchGesture(center: CGPoint) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchStart == nil { pinchStart = (scale, offset) }
                guard let start = pinchStart else { return }
                let newScale = min(max(start.scale * v.magnification, 0.35), 2.2)
                let k = newScale / start.scale
                offset = CGSize(width: center.x - (center.x - start.offset.width) * k,
                                height: center.y - (center.y - start.offset.height) * k)
                scale = newScale
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func nodeDrag(_ node: FlowNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("flowcanvas"))
            .onChanged { v in
                if dragOrigin?.id != node.id {
                    dragOrigin = (node.id, CGPoint(x: node.x, y: node.y))
                }
                guard let origin = dragOrigin, origin.id == node.id,
                      let idx = flow.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                flow.nodes[idx].x = origin.at.x + v.translation.width / scale
                flow.nodes[idx].y = origin.at.y + v.translation.height / scale
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func wireDrag(_ node: FlowNode, port: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("flowcanvas"))
            .onChanged { v in wire = (node.id, port, v.location) }
            .onEnded { v in
                defer { wire = nil; ropes.remove("@wire") }
                guard let target = flow.nodes.first(where: { candidate in
                    guard candidate.id != node.id,
                          BlockSpec.spec(candidate.type).hasInput,
                          let anchor = inAnchor(candidate.id) else { return false }
                    return hypot(anchor.x - v.location.x, anchor.y - v.location.y) < 44 * scale + 20
                }) else { return }
                guard !flow.edges.contains(where: {
                    $0.from == node.id && $0.port == port && $0.to == target.id
                }) else { return }
                flow.edges.append(FlowEdge(id: UUID().uuidString,
                                           from: node.id, port: port, to: target.id))
            }
    }

    private func tapCanvas(at location: CGPoint) {
        for edge in flow.edges {
            guard let a = outAnchor(edge.from, port: edge.port),
                  let b = inAnchor(edge.to) else { continue }
            let sim = ropes.sim(edge.id, from: a, to: b)
            if let hit = sim.pts.first(where: {
                hypot($0.x - location.x, $0.y - location.y) < 26
            }) {
                cutTarget = (edge.id, hit)
                return
            }
        }
        cutTarget = nil
    }

    private func cutButton(_ cut: (id: String, at: CGPoint)) -> some View {
        Button {
            flow.edges.removeAll { $0.id == cut.id }
            ropes.remove(cut.id)
            cutTarget = nil
        } label: {
            Image(systemName: "scissors")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(world.bad, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .position(cut.at)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: Palette

    private var paletteButton: some View {
        Button {
            withAnimation(.spring(duration: 0.35)) { showPalette.toggle() }
        } label: {
            Image(systemName: showPalette ? "xmark" : "plus")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(world.primary, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                .shadow(color: world.primary.opacity(0.45), radius: 9, y: 4)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .padding(.leading, 18)
        .padding(.bottom, 18)
    }

    /// The block drawer: click to drop a block mid-canvas, or drag one straight
    /// onto the canvas.
    private func palette(height: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Click to add · drag onto the canvas to place")
                    .font(.system(.caption2, design: .rounded).weight(.medium))
                    .foregroundStyle(world.ink.opacity(0.45))
                    .frame(maxWidth: .infinity)
                ForEach(BlockSpec.grouped, id: \.category) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: group.category.symbol)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color(nsColor: group.category.tint(world.box)))
                            Text(group.category.label.uppercased())
                                .font(.system(.caption2, design: .rounded).weight(.bold))
                                .foregroundStyle(world.ink.opacity(0.5))
                                .kerning(0.5)
                        }
                        ForEach(group.blocks) { spec in paletteRow(spec) }
                    }
                }
            }
            .padding(12)
            .padding(.bottom, 80)
        }
        .frame(width: 236)
        .frame(maxHeight: height - 24)
        .background(world.paper.opacity(0.96), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(world.line))
        .shadow(color: .black.opacity(0.18), radius: 14, x: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 10)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private func paletteRow(_ spec: BlockSpec) -> some View {
        let tint = Color(nsColor: spec.category.tint(world.box))
        return HStack(spacing: 9) {
            Image(systemName: spec.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(spec.title)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(world.ink)
                Text(spec.blurb)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(world.ink.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(world.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture { addNode(spec, at: nil) }
        .onDrag { NSItemProvider(object: spec.type as NSString) }
    }

    private func addNode(_ spec: BlockSpec, at world: CGPoint?) {
        var params: [String: String] = [:]
        for p in spec.params where !p.fallback.isEmpty { params[p.key] = p.fallback }
        let drop = world ?? dropPoint()
        flow.nodes.append(FlowNode(id: UUID().uuidString, type: spec.type, name: nil,
                                   x: drop.x - Self.nodeW / 2, y: drop.y - Self.nodeH / 2,
                                   params: params))
    }

    private func dropPoint() -> CGPoint {
        let size = viewSize == .zero ? CGSize(width: 900, height: 600) : viewSize
        let base = toWorld(CGPoint(x: size.width / 2 + 40, y: size.height * 0.38))
        let jitter = CGFloat(flow.nodes.count % 5) * 26
        return CGPoint(x: base.x + jitter, y: base.y + jitter)
    }

    // MARK: Node ops

    private func nodeBinding(_ node: FlowNode) -> Binding<FlowNode> {
        Binding(
            get: { flow.nodes.first(where: { $0.id == node.id }) ?? node },
            set: { updated in
                if let i = flow.nodes.firstIndex(where: { $0.id == node.id }) {
                    flow.nodes[i] = updated
                }
            })
    }

    private func removeNode(_ id: String) {
        flow.nodes.removeAll { $0.id == id }
        flow.edges.removeAll { $0.from == id || $0.to == id }
    }

    private func duplicateNode(_ node: FlowNode) {
        var copy = node
        copy.id = UUID().uuidString
        copy.x += 28; copy.y += 28
        flow.nodes.append(copy)
    }

    private func toggleEnabled(_ id: String) {
        guard let idx = flow.nodes.firstIndex(where: { $0.id == id }) else { return }
        flow.nodes[idx].enabled.toggle()
    }

    // MARK: Toolbar / run

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if flows.activeRun?.isRunning == true && flows.activeRun?.flowId == flow.id {
                Button { flows.cancelActiveRun() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button { Task { await flows.run(flow) } } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .disabled(flow.nodes.isEmpty)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { renameText = flow.name; renaming = true } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button { showHistory = true } label: {
                    Label("Run history", systemImage: "clock.arrow.circlepath")
                }
                Button { withAnimation(.spring(duration: 0.4)) { fitToNodes() } } label: {
                    Label("Zoom to fit", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    @ViewBuilder
    private var runStatus: some View {
        if let run = flows.activeRun, run.flowId == flow.id {
            HStack(spacing: 8) {
                switch run.status {
                case "running":
                    ProgressView().controlSize(.small)
                    Text("Running…")
                case "ok":
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(world.good)
                    Text(durationLabel(run))
                case "cancelled":
                    Image(systemName: "stop.circle.fill").foregroundStyle(world.warm)
                    Text("Stopped")
                default:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(world.bad)
                    Text("Failed — click a red block")
                }
            }
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .foregroundStyle(world.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(world.card, in: Capsule())
            .overlay(Capsule().strokeBorder(world.line))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .padding(.trailing, 16)
            .padding(.bottom, 20)
            .onTapGesture { flows.clearRun() }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func durationLabel(_ run: FlowRun) -> String {
        guard let end = run.finishedAt else { return "Done" }
        let s = end.timeIntervalSince(run.startedAt)
        return s < 1 ? "Done" : String(format: "Done in %.1fs", s)
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.title2)
                .foregroundStyle(world.ink.opacity(0.3))
            Text("Drag blocks out of the drawer,\nthen pull a string between them")
                .font(.system(.footnote, design: .rounded).weight(.medium))
                .foregroundStyle(world.ink.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .offset(x: 60)
    }

    // MARK: Fit

    private func fitOnce(_ size: CGSize) {
        guard !didFit, size.width > 50, size.height > 50, !flow.nodes.isEmpty else { return }
        didFit = true
        fitToNodes(viewSize: size)
    }

    private func fitToNodes(viewSize: CGSize? = nil) {
        guard !flow.nodes.isEmpty else { return }
        let size = viewSize ?? (self.viewSize == .zero ? CGSize(width: 900, height: 600) : self.viewSize)
        let minX = flow.nodes.map(\.x).min()! - 40
        let minY = flow.nodes.map(\.y).min()! - 40
        let maxX = flow.nodes.map(\.x).max()! + Double(Self.nodeW) + 40
        let maxY = flow.nodes.map(\.y).max()! + Double(Self.nodeH) + 80
        let w = maxX - minX, h = maxY - minY
        let s = min(min(size.width / w, size.height / h), 1.2)
        scale = max(s, 0.35)
        offset = CGSize(width: (size.width - w * scale) / 2 - minX * scale,
                        height: (size.height - h * scale) / 2 - minY * scale)
    }
}
