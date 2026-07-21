//
//  ContentView.swift
//  MacON
//
//  Sidebar (Local Pipelines + Bitbucket Runners) and a detail pane, dressed
//  in the clay world shared with the companion app — the welcome pane is a
//  real 3D station: a spinnable puffy title over a state-reactive machine.
//

import SwiftUI
import AppKit
import MaconKit

enum SidebarSelection: Hashable {
    case runner(UUID)
    case pipeline(UUID)
    case fleet
    case flows
}

struct ContentView: View {
    @EnvironmentObject private var pool: RunnerPool
    @EnvironmentObject private var pipelines: PipelinePool
    @EnvironmentObject private var companion: CompanionManager
    @Environment(\.colorScheme) private var scheme
    @AppStorage(WorldStyle.themeKey) private var worldRaw = WorldTheme.pastel.rawValue
    @State private var selection: SidebarSelection?
    @State private var showSettings = false

    private var world: WorldStyle { WorldStyle(raw: worldRaw, dark: scheme == .dark) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(pipelines.pipelines) { p in
                        PipelineRow(pipeline: p, world: world).tag(SidebarSelection.pipeline(p.id))
                    }
                    addButton("New pipeline") {
                        let p = pipelines.addPipeline(); selection = .pipeline(p.id)
                    }
                } header: { sectionHeader("Local Pipelines", "bolt.horizontal.fill", world.primary) }

                Section {
                    ForEach(pool.agents) { agent in
                        RunnerRow(agent: agent, world: world).tag(SidebarSelection.runner(agent.id))
                    }
                    addButton("Add runner") {
                        let a = pool.addRunner(); selection = .runner(a.id)
                    }
                } header: { sectionHeader("Bitbucket Runners", "server.rack", world.warm) }

                Section {
                    HStack(spacing: 11) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                            .foregroundStyle(world.primary)
                            .frame(width: 15)
                        Text("Flows").font(.body.weight(.medium))
                    }
                    .padding(.vertical, 3)
                    .tag(SidebarSelection.flows)

                    HStack(spacing: 11) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .foregroundStyle(world.primary)
                            .frame(width: 15)
                        Text("Fleet").font(.body.weight(.medium))
                        Spacer()
                        if !companion.devices.isEmpty {
                            Text("\(companion.devices.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(SidebarSelection.fleet)
                } header: { sectionHeader("Automations", "wand.and.stars", world.good) }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 280)
            .safeAreaInset(edge: .bottom) { poolBar }
            .toolbar {
                // Home: clear the selection to land back on the welcome pane.
                ToolbarItem(placement: .navigation) {
                    Button {
                        selection = nil
                    } label: {
                        Image(systemName: "house.fill")
                    }
                    .help("Home")
                    .disabled(selection == nil)
                }
            }
        } detail: {
            detail
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(pool).environmentObject(pipelines)
                .environmentObject(companion)
                .environmentObject(PrivacyCurtain.shared)
        }
        .task { await pool.refreshReclaimable() }
    }

    // MARK: Sidebar bits

    private func sectionHeader(_ title: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2).foregroundStyle(tint)
            Text(title)
        }
        .font(.caption.weight(.semibold))
    }

    private func addButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private var poolBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(activeAny ? AnyShapeStyle(world.primary.gradient) : AnyShapeStyle(Color.gray.opacity(0.2)))
                .frame(height: 2)
            HStack(spacing: 8) {
                PulseDot(color: activeAny ? world.primary : .gray, active: activeAny, size: 9)
                Text("\(pipelines.watchingCount) watching · \(pool.activeCount) live")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.bar)
        }
    }

    private var activeAny: Bool { pipelines.watchingCount > 0 || pool.anyActive }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .pipeline(let id):
            if let p = pipelines.pipelines.first(where: { $0.id == id }) {
                PipelineDetailView(pipeline: p).id(p.id)
            } else { welcome }
        case .runner(let id):
            if let a = pool.agents.first(where: { $0.id == id }) {
                RunnerDetailView(agent: a).id(a.id)
            } else { welcome }
        case .fleet:
            FleetView(world: world)
        case .flows:
            FlowsView().environmentObject(companion)
        case nil:
            welcome
        }
    }

    private var welcome: some View {
        WelcomeView(
            watching: pipelines.watchingCount,
            mood: welcomeMood,
            runners: pool.activeCount,
            reclaimable: pool.reclaimableBytes,
            world: world,
            newPipeline: { let p = pipelines.addPipeline(); selection = .pipeline(p.id) },
            addRunner: { let a = pool.addRunner(); selection = .runner(a.id) })
    }

    /// The machine's mood mirrors the fleet: building → busy, any failure →
    /// alert, otherwise calm.
    private var welcomeMood: WorldStage.Mood {
        if pipelines.pipelines.contains(where: { $0.isBuilding }) { return .busy }
        let anyFailed = pipelines.pipelines.contains {
            if case .failed = $0.buildState { return true } else { return false }
        }
        return anyFailed ? .alert : .calm
    }
}

// MARK: - Welcome / empty state

/// The clay station: "MacOn" as a spinnable 3D title, the watched-pipeline
/// count as the state-reactive machine beneath it, stat chips and the two
/// first actions below.
private struct WelcomeView: View {
    var watching: Int
    var mood: WorldStage.Mood
    var runners: Int
    var reclaimable: Int64
    var world: WorldStyle
    var newPipeline: () -> Void
    var addRunner: () -> Void

    @State private var appear = false

    var body: some View {
        ZStack {
            WorldBackdrop(world: world)

            VStack(spacing: 14) {
                WorldStage(title: "MacOn", figure: "\(watching)", mood: mood,
                           dark: world.dark, theme: world.theme)
                    .aspectRatio(0.62, contentMode: .fit)
                    .frame(maxHeight: 460)

                Text("Your Mac is the CI runner.")
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundStyle(world.ink.opacity(0.65))

                HStack(spacing: 12) {
                    StatChip(icon: "eye.fill", value: "\(watching)", label: "watching",
                             tint: world.primary, world: world)
                    StatChip(icon: "bolt.fill", value: "\(runners)", label: "runners live",
                             tint: world.good, world: world)
                    StatChip(icon: "internaldrive.fill",
                             value: reclaimable > 0 ? ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file) : "—",
                             label: "reclaimable", tint: world.warm, world: world)
                }

                HStack(spacing: 12) {
                    Button(action: newPipeline) {
                        Label("New Pipeline", systemImage: "plus")
                    }
                    .buttonStyle(ClayButtonStyle(world: world))
                    Button(action: addRunner) {
                        Label("Add Runner", systemImage: "server.rack")
                    }
                    .buttonStyle(ClaySoftButtonStyle(world: world))
                }
                .padding(.top, 2)

                Text("Local Pipelines build commits right here. Bitbucket Runners execute Pipelines jobs on this Mac.")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(world.ink.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(28)
            .opacity(appear ? 1 : 0)
            .scaleEffect(appear ? 1 : 0.96)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.6)) { appear = true }
        }
    }
}

// MARK: - Sidebar rows

private struct PipelineRow: View {
    @ObservedObject var pipeline: PipelineRunner
    let world: WorldStyle
    var body: some View {
        HStack(spacing: 11) {
            PulseDot(color: world.tint(pipeline.buildState),
                     active: pipeline.isWatching || pipeline.isBuilding)
            VStack(alignment: .leading, spacing: 1) {
                Text(pipeline.config.name).lineLimit(1).font(.body.weight(.medium))
                Text(pipeline.isWatching ? "Watching \(pipeline.config.branch)" : pipeline.buildState.label)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct RunnerRow: View {
    @ObservedObject var agent: RunnerAgent
    let world: WorldStyle
    var body: some View {
        HStack(spacing: 11) {
            PulseDot(color: world.tint(agent.state), active: agent.state.isActive)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.instance.name).lineLimit(1).font(.body.weight(.medium))
                Text(agent.state.label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

#Preview {
    ContentView()
        .environmentObject(RunnerPool())
        .environmentObject(PipelinePool())
        .environmentObject(CompanionManager())
}
