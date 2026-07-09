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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconTile(systemImage: "server.rack", gradient: LinearGradient(colors: [Brand.indigo, Brand.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Runner").font(.title2.weight(.bold))
                    Text(agent.instance.name.isEmpty ? "New runner" : agent.instance.name)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .background {
                LinearGradient(colors: [Brand.indigo.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                    .background(.regularMaterial)
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
                                .buttonStyle(SoftButtonStyle())
                        }
                    }
                    Text("Give each runner its own directory so their checkouts don't collide.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("Restart automatically if it crashes",
                           isOn: $agent.instance.restartOnCrash)
                } header: { FormSectionHeader(title: "Runner", systemImage: "server.rack", tint: Brand.indigo) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Done") { pool.commitEdits(); dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 520, height: 480)
        .background(.regularMaterial)
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
