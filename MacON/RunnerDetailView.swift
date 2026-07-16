//
//  RunnerDetailView.swift
//  MacON
//
//  Per-runner controls + live logs.
//

import SwiftUI
import MaconKit

struct RunnerDetailView: View {
    @ObservedObject var agent: RunnerAgent
    @EnvironmentObject private var pool: RunnerPool
    @Environment(\.colorScheme) private var scheme
    @AppStorage(WorldStyle.themeKey) private var worldRaw = WorldTheme.pastel.rawValue
    @State private var showEdit = false
    @State private var confirmDelete = false

    private var world: WorldStyle { WorldStyle(raw: worldRaw, dark: scheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            LogConsole(lines: agent.log)
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 360)
        .sheet(isPresented: $showEdit) {
            RunnerEditView(agent: agent).environmentObject(pool)
        }
        .confirmationDialog("Delete “\(agent.instance.name)”?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { pool.remove(agent) }
        } message: {
            Text("Stops the runner and removes it from the pool. Its working directory is left on disk.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            StatusBadge(color: world.tint(agent.state), symbol: agent.state.symbol, active: agent.state.isActive)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.instance.name)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                HStack(spacing: 6) {
                    Text(agent.state.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(world.tint(agent.state))
                    if let started = agent.startedAt {
                        Text("· up since \(started.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                .buttonStyle(ClaySoftButtonStyle(world: world))
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(ClaySoftButtonStyle(world: world, danger: true))
        }
        .padding(18)
        .background {
            LinearGradient(colors: [world.tint(agent.state).opacity(0.16), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .background(world.card)
        }
        .animation(.spring(duration: 0.4), value: agent.state)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if agent.state.isActive {
                Button { agent.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(ClaySoftButtonStyle(world: world, danger: true))
            } else {
                Button { agent.start() } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(ClayButtonStyle(world: world))
                .disabled(agent.instance.startCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button {
                agent.cleanWorkingDir()
            } label: {
                if agent.isCleaning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Empty Workdir", systemImage: "trash")
                }
            }
            .buttonStyle(ClaySoftButtonStyle(world: world))
            .disabled(agent.state.isActive || agent.isCleaning)
            .help("Delete this runner's working-directory contents")

            Spacer()

            Button { agent.clearLog() } label: { Label("Clear", systemImage: "text.badge.xmark") }
                .buttonStyle(ClaySoftButtonStyle(world: world))
                .disabled(agent.log.isEmpty)
            Button { copyLog() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(ClaySoftButtonStyle(world: world))
                .disabled(agent.log.isEmpty)
        }
        .padding(16)
        .background(.bar)
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agent.logPlainText, forType: .string)
    }
}
