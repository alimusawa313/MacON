//
//  RunnerEditView.swift
//  MacON
//
//  Edit a single runner's registration.
//

import SwiftUI
import MaconKit

struct RunnerEditView: View {
    @ObservedObject var agent: RunnerAgent
    @EnvironmentObject private var pool: RunnerPool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage(WorldStyle.themeKey) private var worldRaw = WorldTheme.pastel.rawValue

    private var world: WorldStyle { WorldStyle(raw: worldRaw, dark: scheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ClayTile(systemImage: "server.rack", fill: world.warm)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Runner").font(.system(.title2, design: .rounded).weight(.bold))
                    Text(agent.instance.name.isEmpty ? "New runner" : agent.instance.name)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .background {
                LinearGradient(colors: [world.warm.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                    .background(world.card)
            }

            Form {
                Section {
                    TextField("Name", text: $agent.instance.name)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Start command").font(.subheadline).bold()
                        Text("From the repo you want this runner to serve: "
                             + "Settings → Runners → add a macOS/Linux (shell) runner.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $agent.instance.startCommand)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 90)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }

                    LabeledContent("Working directory") {
                        HStack {
                            TextField("", text: $agent.instance.workingDirectory)
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") { chooseDir() }
                                .buttonStyle(ClaySoftButtonStyle(world: world))
                        }
                    }
                    Text("Give each runner its own directory so their checkouts don't collide.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("Restart automatically if it crashes",
                           isOn: $agent.instance.restartOnCrash)
                } header: { WorldSectionHeader(title: "Runner", symbol: "server.rack", world: world, tint: world.warm) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Done") { pool.commitEdits(); dismiss() }
                    .buttonStyle(ClayButtonStyle(world: world))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 520, height: 480)
        .background(WorldBackdrop(world: world))
    }

    private func chooseDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if !agent.instance.workingDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: agent.instance.workingDirectory)
        }
        if panel.runModal() == .OK, let url = panel.url {
            agent.instance.workingDirectory = url.path
        }
    }
}
