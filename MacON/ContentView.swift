//
//  ContentView.swift
//  MacON
//
//  Sidebar with two sections — Runners (Bitbucket Pipelines agents) and
//  Pipelines (fully local CI) — plus a detail pane for the selection.
//

import SwiftUI
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
                Section("Local Pipelines") {
                    ForEach(pipelines.pipelines) { p in
                        PipelineRow(pipeline: p).tag(SidebarSelection.pipeline(p.id))
                    }
                    Button {
                        let p = pipelines.addPipeline()
                        selection = .pipeline(p.id)
                    } label: { Label("Add pipeline", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }

                Section("Bitbucket Runners") {
                    ForEach(pool.agents) { agent in
                        RunnerRow(agent: agent).tag(SidebarSelection.runner(agent.id))
                    }
                    Button {
                        let a = pool.addRunner()
                        selection = .runner(a.id)
                    } label: { Label("Add runner", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 270)
            .safeAreaInset(edge: .bottom) { poolBar }
        } detail: {
            detail
        }
        .navigationTitle("MacON")
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(pool).environmentObject(pipelines).environmentObject(companion)
        }
        .task { await pool.refreshReclaimable() }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .pipeline(let id):
            if let p = pipelines.pipelines.first(where: { $0.id == id }) {
                PipelineDetailView(pipeline: p).id(p.id)
            } else { placeholder }
        case .runner(let id):
            if let a = pool.agents.first(where: { $0.id == id }) {
                RunnerDetailView(agent: a).id(a.id)
            } else { placeholder }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            "Select an item",
            systemImage: "bolt.horizontal.circle",
            description: Text("Local Pipelines build commits on this Mac directly. "
                              + "Bitbucket Runners execute Bitbucket Pipelines jobs here."))
    }

    private var poolBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Label("\(pipelines.watchingCount) watching · \(pool.activeCount) runners",
                      systemImage: "bolt.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
            }
        }
        .padding(10)
        .background(.bar)
    }
}

private struct PipelineRow: View {
    @ObservedObject var pipeline: PipelineRunner
    var body: some View {
        HStack(spacing: 10) {
            Dot(color: pipeline.buildState.uiColor, glow: pipeline.isWatching)
            VStack(alignment: .leading, spacing: 1) {
                Text(pipeline.config.name).lineLimit(1)
                Text(pipeline.isWatching ? "Watching \(pipeline.config.branch)" : pipeline.buildState.label)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RunnerRow: View {
    @ObservedObject var agent: RunnerAgent
    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: agent.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.instance.name).lineLimit(1)
                Text(agent.state.label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
        .environmentObject(RunnerPool())
        .environmentObject(PipelinePool())
        .environmentObject(CompanionManager())
}
