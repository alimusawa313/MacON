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
    @State private var showEdit = false
    @State private var confirmDelete = false

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
            StatusBadge(color: agent.state.uiColor, symbol: agent.state.symbol, active: agent.state.isActive)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.instance.name).font(.title2.weight(.bold))
                HStack(spacing: 6) {
                    Text(agent.state.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(agent.state.uiColor)
                    if let started = agent.startedAt {
                        Text("· up since \(started.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                .buttonStyle(SoftButtonStyle())
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(SoftButtonStyle(danger: true))
        }
        .padding(18)
        .background {
            LinearGradient(colors: [agent.state.uiColor.opacity(0.16), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .background(.regularMaterial)
        }
        .animation(.spring(duration: 0.4), value: agent.state)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if agent.state.isActive {
                Button { agent.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(SoftButtonStyle(danger: true))
            } else {
                Button { agent.start() } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
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
            .buttonStyle(SoftButtonStyle())
            .disabled(agent.state.isActive || agent.isCleaning)
            .help("Delete this runner's working-directory contents")

            Spacer()

            Button { agent.clearLog() } label: { Label("Clear", systemImage: "text.badge.xmark") }
                .buttonStyle(SoftButtonStyle())
                .disabled(agent.log.isEmpty)
            Button { copyLog() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(SoftButtonStyle())
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
