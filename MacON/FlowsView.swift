//
//  FlowsView.swift
//  MacON
//
//  The Flows screen in the Mac app: every automation saved on this Mac,
//  templates to start from, and the door into the canvas editor. Flows both
//  build and run right here — no companion needed.
//

import SwiftUI

struct FlowsView: View {
    @EnvironmentObject private var companion: CompanionManager
    @Environment(\.colorScheme) private var scheme
    @AppStorage(WorldStyle.themeKey) private var worldRaw = WorldTheme.pastel.rawValue

    @State private var flows = FlowsModel()
    @State private var path: [Flow] = []
    @State private var renaming: Flow?
    @State private var renameText = ""

    private var world: WorldStyle { WorldStyle(raw: worldRaw, dark: scheme == .dark) }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                WorldBackdrop(world: world)
                content
            }
            .navigationTitle("Flows")
            .toolbar { ToolbarItem(placement: .primaryAction) { addMenu } }
            .navigationDestination(for: Flow.self) { flow in
                FlowCanvasView(flows: flows, flowId: flow.id)
            }
        }
        .task {
            flows.wire(store: companion.flowStore, engine: companion.flowEngine)
            flows.load()
            await flows.loadModels()
        }
        .alert("Rename flow", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if var f = renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    f.name = renameText
                    flows.flush(f)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        if flows.flows.isEmpty {
            emptyState
        } else {
            list
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(flows.flows) { flow in
                    Button { path.append(flow) } label: { row(flow) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { renameText = flow.name; renaming = flow } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button { flows.duplicate(flow) } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            Button(role: .destructive) { flows.delete(flow) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 30)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ flow: Flow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                .font(.title3)
                .foregroundStyle(world.primary)
                .frame(width: 42, height: 42)
                .background(world.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(flow.name)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(world.ink)
                    .lineLimit(1)
                Text("\(flow.nodes.count) block\(flow.nodes.count == 1 ? "" : "s") · \(flow.edges.count) string\(flow.edges.count == 1 ? "" : "s")")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(world.ink.opacity(0.55))
            }
            Spacer()
            if flow.nodes.contains(where: {
                ["trigger.schedule", "trigger.daily", "trigger.watch"].contains($0.type)
            }) {
                Image(systemName: "clock.fill").font(.caption).foregroundStyle(world.warm)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(world.ink.opacity(0.3))
        }
        .padding(14)
        .background(world.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(world.line))
    }

    // MARK: Empty state

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(world.primary)
                    Text("Wire your Mac up")
                        .font(.system(.title2, design: .rounded).weight(.heavy))
                        .foregroundStyle(world.ink)
                    Text("Drop blocks on a canvas, tie them together with strings, and this Mac runs the whole thing — AI, files, shell, web.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(world.ink.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                .padding(.top, 44)

                Button { open(flows.create(named: "New flow")) } label: {
                    Label("Start from scratch", systemImage: "plus")
                }
                .buttonStyle(ClayButtonStyle(world: world))
                .frame(maxWidth: 280)

                VStack(alignment: .leading, spacing: 10) {
                    WorldSectionHeader(title: "Templates", symbol: "sparkles", world: world)
                    ForEach(FlowsModel.templates()) { template in
                        Button { adopt(template) } label: { templateRow(template) }
                            .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 460)
                .padding(.top, 14)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 30)
        }
    }

    private func templateRow(_ flow: Flow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(world.warm)
                .frame(width: 36, height: 36)
                .background(world.warm.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(flow.name)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(world.ink)
                Text("\(flow.nodes.count) blocks, ready to run")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(world.ink.opacity(0.5))
            }
            Spacer()
            Image(systemName: "plus.circle.fill").foregroundStyle(world.primary)
        }
        .padding(12)
        .background(world.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(world.line))
    }

    // MARK: New

    private var addMenu: some View {
        Menu {
            Button { open(flows.create(named: "New flow")) } label: {
                Label("Blank flow", systemImage: "square.dashed")
            }
            Section("Templates") {
                ForEach(FlowsModel.templates()) { template in
                    Button(template.name) { adopt(template) }
                }
            }
        } label: { Image(systemName: "plus") }
    }

    private func adopt(_ template: Flow) {
        var flow = template
        flow.id = UUID().uuidString
        flows.flush(flow)
        open(flow)
    }

    private func open(_ flow: Flow) { path.append(flow) }
}
