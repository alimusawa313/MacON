//
//  SettingsView.swift
//  MacON
//
//  Bitbucket account (for local pipelines) + pool-wide cleanup settings.
//

import SwiftUI
import UniformTypeIdentifiers
import MaconKit

struct SettingsView: View {
    @EnvironmentObject private var pool: RunnerPool
    @EnvironmentObject private var pipelines: PipelinePool
    @Environment(\.dismiss) private var dismiss
    @State private var secretRows: [SecretRow] = []
    @State private var exportWithSecrets = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Bitbucket account (for Bitbucket pipelines)") {
                    Text("Used to poll for commits, clone over HTTPS, and post build "
                         + "status. Create an API token in Atlassian account settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Atlassian email", text: $pipelines.email)
                        .autocorrectionDisabled()
                    SecureField("API token", text: $pipelines.apiToken)
                    Label(pipelines.credentials.isComplete ? "Account set" : "Incomplete",
                          systemImage: pipelines.credentials.isComplete ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(pipelines.credentials.isComplete ? .green : .orange)
                }

                Section("GitHub account (for GitHub pipelines)") {
                    Text("A Personal Access Token with repo access (classic: `repo` scope, "
                         + "or fine-grained: Contents + Commit statuses + Pull requests). "
                         + "Create one at github.com → Settings → Developer settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("Personal Access Token", text: $pipelines.githubToken)
                    Label(pipelines.hasCredentials(for: .github) ? "Token set" : "Not set",
                          systemImage: pipelines.hasCredentials(for: .github) ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(pipelines.hasCredentials(for: .github) ? .green : .orange)
                }

                Section("Global secrets (env for all pipelines)") {
                    Text("Stored in the macOS Keychain, never in a repo. Shared by every "
                         + "pipeline — put ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_CONTENT, "
                         + "SLACK_URL here. A pipeline's own secret overrides a global one.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach($secretRows) { $row in
                        HStack {
                            TextField("KEY", text: $row.key)
                                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                                .frame(width: 180)
                            SecureField("value", text: $row.value)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                secretRows.removeAll { $0.id == row.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button { secretRows.append(SecretRow(key: "", value: "")) } label: {
                        Label("Add secret", systemImage: "plus")
                    }
                }

                Section("Portable config (use in the terminal)") {
                    Text("Export your pipelines to a JSON file, then run them headless "
                         + "with `macon watch --config <file>`. See what's inside with "
                         + "`macon pipelines <file>`.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Include secrets & tokens in the file", isOn: $exportWithSecrets)
                    if exportWithSecrets {
                        Label("The file will contain your API tokens and secret values "
                              + "in plain text — keep it private.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Config only. Secret names are included; provide their values "
                             + "via the shell environment when you run macon.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button { exportConfig() } label: {
                            Label("Export Configuration…", systemImage: "square.and.arrow.up")
                        }
                        Button { importConfig() } label: {
                            Label("Import…", systemImage: "square.and.arrow.down")
                        }
                    }
                }

                Section("Per-runner cleanup (on stop)") {
                    Toggle("Empty the runner's working directory when it stops",
                           isOn: $pool.cleanupSettings.emptyWorkingDirOnStop)
                }

                Section("Shared machine caches") {
                    Text("Shared by every runner/pipeline, so only cleaned when all "
                         + "runners are stopped.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Xcode DerivedData", isOn: $pool.cleanupSettings.derivedData)
                    Toggle("SwiftPM caches", isOn: $pool.cleanupSettings.swiftPMCache)
                    Toggle("Xcode Archives", isOn: $pool.cleanupSettings.archives)
                    Toggle("Delete unavailable simulators",
                           isOn: $pool.cleanupSettings.pruneSimulators)
                    HStack {
                        Button {
                            pool.cleanCaches()
                        } label: {
                            if pool.isCleaningCaches {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Clean Caches Now", systemImage: "trash")
                            }
                        }
                        .disabled(pool.anyActive || pool.isCleaningCaches)
                        if pool.anyActive {
                            Text("Stop all runners first")
                                .font(.caption).foregroundStyle(.orange)
                        } else if pool.reclaimableBytes > 0 {
                            Text("~\(ByteCountFormatter.string(fromByteCount: pool.reclaimableBytes, countStyle: .file)) reclaimable")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    pipelines.setGlobalSecrets(secretRows.map { ($0.key, $0.value) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 540, height: 680)
        .task {
            await pool.refreshReclaimable()
            secretRows = pipelines.globalSecretKeys.map {
                SecretRow(key: $0, value: Keychain.get(account: PipelinePool.globalSecretAccount($0)))
            }
        }
    }

    // MARK: - Export / Import

    private func exportConfig() {
        // Commit any unsaved global-secret edits first so they're included.
        pipelines.setGlobalSecrets(secretRows.map { ($0.key, $0.value) })
        let bundle = pipelines.makeExport(includeSecrets: exportWithSecrets)
        guard let data = try? bundle.encoded() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macon-export.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let bundle = try? MaconExport.decoded(from: data) else { return }
        pipelines.importBundle(bundle, replaceExisting: false)
    }
}
