//
//  ContentView.swift
//  MacON
//
//  Sidebar (Local Pipelines + Bitbucket Runners) and a detail pane, dressed up
//  with the app's visual language.
//

import SwiftUI
import AppKit
import MaconKit

enum SidebarSelection: Hashable {
    case runner(UUID)
    case pipeline(UUID)
}

struct ContentView: View {
    @EnvironmentObject private var pool: RunnerPool
    @EnvironmentObject private var pipelines: PipelinePool
    @EnvironmentObject private var companion: CompanionManager
    @State private var selection: SidebarSelection?
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(pipelines.pipelines) { p in
                        PipelineRow(pipeline: p).tag(SidebarSelection.pipeline(p.id))
                    }
                    addButton("New pipeline") {
                        let p = pipelines.addPipeline(); selection = .pipeline(p.id)
                    }
                } header: { sectionHeader("Local Pipelines", "bolt.horizontal.fill", Brand.blue) }

                Section {
                    ForEach(pool.agents) { agent in
                        RunnerRow(agent: agent).tag(SidebarSelection.runner(agent.id))
                    }
                    addButton("Add runner") {
                        let a = pool.addRunner(); selection = .runner(a.id)
                    }
                } header: { sectionHeader("Bitbucket Runners", "server.rack", Brand.indigo) }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 280)
            .safeAreaInset(edge: .bottom) { poolBar }
        } detail: {
            detail
        }
        .navigationTitle("MacOn")
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(pool).environmentObject(pipelines).environmentObject(companion)
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
                .fill(activeAny ? Brand.gradient : LinearGradient(colors: [.gray.opacity(0.2)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 2)
            HStack(spacing: 8) {
                PulseDot(color: activeAny ? Brand.blue : .gray, active: activeAny, size: 9)
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
        case nil:
            welcome
        }
    }

    private var welcome: some View {
        WelcomeView(
            watching: pipelines.watchingCount,
            runners: pool.activeCount,
            reclaimable: pool.reclaimableBytes,
            newPipeline: { let p = pipelines.addPipeline(); selection = .pipeline(p.id) },
            addRunner: { let a = pool.addRunner(); selection = .runner(a.id) })
    }
}

// MARK: - Welcome / empty state

private struct WelcomeView: View {
    var watching: Int
    var runners: Int
    var reclaimable: Int64
    var newPipeline: () -> Void
    var addRunner: () -> Void

    @State private var float = false
    @State private var appear = false

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.33)

            VStack(spacing: 24) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 128, height: 128)
                    .shadow(color: Brand.blue.opacity(0.35), radius: 24, y: 12)
                    .offset(y: float ? -8 : 8)
                    .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: float)

                VStack(spacing: 7) {
                    Text("MacOn").font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("Your Mac is the CI runner.")
                        .font(.title3).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    StatChip(icon: "eye.fill", value: "\(watching)", label: "watching", tint: Brand.blue)
                    StatChip(icon: "bolt.fill", value: "\(runners)", label: "runners live", tint: Brand.emerald)
                    StatChip(icon: "internaldrive.fill",
                             value: reclaimable > 0 ? ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file) : "—",
                             label: "reclaimable", tint: Brand.amber)
                }

                HStack(spacing: 12) {
                    Button(action: newPipeline) {
                        Label("New Pipeline", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button(action: addRunner) {
                        Label("Add Runner", systemImage: "server.rack")
                    }
                    .buttonStyle(SoftButtonStyle())
                }
                .padding(.top, 2)

                Text("Local Pipelines build commits right here. Bitbucket Runners execute Pipelines jobs on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.top, 4)
            }
            .padding(40)
            .opacity(appear ? 1 : 0)
            .scaleEffect(appear ? 1 : 0.96)
        }
        .onAppear {
            float = true
            withAnimation(.spring(duration: 0.6)) { appear = true }
        }
    }
}

// MARK: - Sidebar rows

private struct PipelineRow: View {
    @ObservedObject var pipeline: PipelineRunner
    var body: some View {
        HStack(spacing: 11) {
            PulseDot(color: pipeline.buildState.uiColor, active: pipeline.isWatching || pipeline.isBuilding)
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
    var body: some View {
        HStack(spacing: 11) {
            PulseDot(color: agent.state.uiColor, active: agent.state.isActive)
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
