//
//  PipelineEditView.swift
//  MacON
//

import SwiftUI

struct SecretRow: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

struct PipelineEditView: View {
    @ObservedObject var pipeline: PipelineRunner
    @EnvironmentObject private var pool: PipelinePool
    @Environment(\.dismiss) private var dismiss

    @State private var repos: [String] = []
    @State private var branches: [String] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var secretRows: [SecretRow] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Pipeline") {
                    TextField("Name", text: $pipeline.config.name)
                }

                Section("Repository") {
                    if pool.credentials.isComplete {
                        repoControls
                    } else {
                        Text("⚠︎ Set your Bitbucket account in Settings to load repos "
                             + "and branches. Until then, enter values manually:")
                            .font(.caption).foregroundStyle(.orange)
                        manualFields
                    }
                }

                Section("Build") {
                    LabeledContent("Pipeline file") {
                        TextField("macon.yml", text: $pipeline.config.pipelineFile)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    }
                    LabeledContent("Workflow") {
                        TextField("auto (from triggers)", text: $pipeline.config.workflow)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    }
                    Text("If the file exists in the repo root, its workflow runs and the "
                         + "build command below is ignored. Leave Workflow blank to auto-pick "
                         + "by matching this branch against the file's triggers. Example:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("""
                    name: iOS CI
                    env: { TEST_DEVICE: "iPhone 17 Pro" }
                    workflows:
                      _setup:
                        steps:
                          - { name: Gems, script: "bundle install" }
                      test:
                        before_run: [_setup]
                        steps:
                          - name: Test
                            script: bundle exec fastlane test device:"$TEST_DEVICE"
                      beta:
                        before_run: [test]
                        steps:
                          - { name: Ship, script: "bundle exec fastlane beta" }
                    triggers:
                      - { branch: main, workflow: beta }
                      - { branch: "dev-*", workflow: test }
                    """)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Build command (fallback)").font(.subheadline).bold()
                        Text("Used only when no pipeline file is found. Runs in the repo root.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $pipeline.config.buildCommand)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 60)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }
                    LabeledContent("Checkout directory") {
                        HStack {
                            TextField("", text: $pipeline.config.workingDirectory)
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") { chooseDir() }
                        }
                    }
                }

                Section("Secrets (injected as env for every step)") {
                    Text("Stored in the macOS Keychain, never in the repo. For TestFlight "
                         + "add ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_CONTENT (base64 .p8). "
                         + "Also e.g. SLACK_URL.")
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

                Section("Trigger") {
                    Picker("Watch", selection: $pipeline.config.watchMode) {
                        ForEach(WatchMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if pipeline.config.watchMode == .branch {
                        Text("Builds new commits pushed to the selected branch.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("PR target branch") {
                            TextField("all (blank)", text: $pipeline.config.prTargetBranch)
                                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                        }
                        Text("Builds new commits on any open PR (optionally only those "
                             + "targeting the branch above). Sets PR env so Danger can post.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Stepper("Poll every \(pipeline.config.pollSeconds)s",
                            value: $pipeline.config.pollSeconds, in: 5...3600, step: 5)
                    Toggle("Post build status to Bitbucket commits",
                           isOn: $pipeline.config.postStatus)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") { commitSecrets(); pool.commitEdits(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 660)
        .task { loadSecretRows(); await reloadAll() }
        .onChange(of: pipeline.config.repoSlug) {
            pipeline.config.branch = ""
            Task { await reloadBranches() }
        }
    }

    // MARK: - Controls

    private var repoControls: some View {
        Group {
            // Workspace: free text. Atlassian deprecated listing all workspaces
            // (CHANGE-2770), so you type the slug (e.g. "academytools").
            LabeledContent("Workspace") {
                HStack {
                    TextField("workspace-slug", text: $pipeline.config.workspace)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await reloadRepos(clearing: true) } }
                    if loading { ProgressView().controlSize(.small) }
                    Button { Task { await reloadAll() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Load repos/branches for this workspace")
                }
            }

            // Repository: dropdown when listing works, text fallback otherwise.
            if repos.isEmpty {
                LabeledContent("Repository") {
                    TextField("repo-slug", text: $pipeline.config.repoSlug)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await reloadBranches() } }
                }
            } else {
                Picker("Repository", selection: $pipeline.config.repoSlug) {
                    Text("— Select —").tag("")
                    ForEach(options(repos, pipeline.config.repoSlug), id: \.self) {
                        Text($0).tag($0)
                    }
                }
            }

            // Branch: dropdown when listing works, text fallback otherwise.
            if branches.isEmpty {
                LabeledContent("Branch") {
                    TextField("branch", text: $pipeline.config.branch)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
            } else {
                Picker("Branch", selection: $pipeline.config.branch) {
                    Text("— Select —").tag("")
                    ForEach(options(branches, pipeline.config.branch), id: \.self) {
                        Text($0).tag($0)
                    }
                }
            }

            if let err = loadError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var manualFields: some View {
        Group {
            TextField("Workspace", text: $pipeline.config.workspace).autocorrectionDisabled()
            TextField("Repo slug", text: $pipeline.config.repoSlug).autocorrectionDisabled()
            TextField("Branch", text: $pipeline.config.branch).autocorrectionDisabled()
        }
    }

    /// Always include the current value so a Picker can display it.
    private func options(_ list: [String], _ current: String) -> [String] {
        var set = Set(list)
        if !current.isEmpty { set.insert(current) }
        return set.sorted()
    }

    // MARK: - Loading (no workspace listing — that endpoint is gone)

    private func reloadAll() async {
        await reloadRepos(clearing: false)
        await reloadBranches()
    }

    private func reloadRepos(clearing: Bool) async {
        if clearing { pipeline.config.repoSlug = ""; pipeline.config.branch = "" }
        guard let client = pool.makeClient(),
              !pipeline.config.workspace.isEmpty else { repos = []; return }
        loading = true; loadError = nil
        do {
            repos = try await client.listRepositories(workspace: pipeline.config.workspace)
            if repos.isEmpty { loadError = "No repos found in that workspace (check the slug)." }
        } catch {
            repos = []
            loadError = "Couldn't list repos: \(error.localizedDescription) — you can type the repo slug."
        }
        loading = false
    }

    private func reloadBranches() async {
        guard let client = pool.makeClient(),
              !pipeline.config.workspace.isEmpty,
              !pipeline.config.repoSlug.isEmpty else { branches = []; return }
        do {
            branches = try await client.listBranches(
                workspace: pipeline.config.workspace, repo: pipeline.config.repoSlug)
        } catch {
            branches = []
            loadError = "Couldn't list branches: \(error.localizedDescription) — you can type it."
        }
    }

    // MARK: - Secrets

    private func secretAccount(_ key: String) -> String {
        "secret:\(pipeline.config.id.uuidString):\(key)"
    }

    private func loadSecretRows() {
        secretRows = pipeline.config.secretKeys.map {
            SecretRow(key: $0, value: Keychain.get(account: secretAccount($0)))
        }
    }

    private func commitSecrets() {
        var keys: [String] = []
        for row in secretRows {
            let k = row.key.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { continue }
            Keychain.set(row.value, account: secretAccount(k))
            keys.append(k)
        }
        // Remove secrets whose key was deleted.
        for old in pipeline.config.secretKeys where !keys.contains(old) {
            Keychain.set("", account: secretAccount(old))
        }
        pipeline.config.secretKeys = keys
    }

    private func chooseDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if !pipeline.config.workingDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: pipeline.config.workingDirectory)
        }
        if panel.runModal() == .OK, let url = panel.url {
            pipeline.config.workingDirectory = url.path
        }
    }
}
