//
//  PipelineEditView.swift
//  MacON
//

import SwiftUI
import MaconKit

struct SecretRow: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

struct PipelineEditView: View {
    @ObservedObject var pipeline: PipelineRunner
    @EnvironmentObject private var pool: PipelinePool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage(WorldStyle.themeKey) private var worldRaw = WorldTheme.pastel.rawValue

    @State private var repos: [String] = []
    @State private var branches: [String] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var secretRows: [SecretRow] = []

    private var world: WorldStyle { WorldStyle(raw: worldRaw, dark: scheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    TextField("Name", text: $pipeline.config.name)
                } header: { WorldSectionHeader(title: "Pipeline", symbol: "bolt.horizontal.fill", world: world) }

                Section {
                    Picker("Provider", selection: $pipeline.config.provider) {
                        ForEach(GitProviderKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if pool.hasCredentials(for: pipeline.config.provider) {
                        repoControls
                    } else {
                        Label("Set your \(pipeline.config.provider.label) credentials in Settings to "
                              + "load repos and branches. Until then, enter values manually:",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(world.warm)
                        manualFields
                    }
                } header: { WorldSectionHeader(title: "Repository", symbol: "arrow.triangle.branch", world: world) }

                Section {
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
                          - name: UI Tests
                            matrix:
                              device: ["iPhone 16", "iPad Air"]
                              os: ["17.5", "18.2"]
                            script: bundle exec fastlane test device:"$MACON_MATRIX_DEVICE" os:"$MACON_MATRIX_OS"
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
                                .buttonStyle(ClaySoftButtonStyle(world: world))
                        }
                    }
                } header: { WorldSectionHeader(title: "Build", symbol: "hammer.fill", world: world, tint: world.good) }

                Section {
                    Text("Stored in the macOS Keychain, never in the repo. For TestFlight "
                         + "add ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_CONTENT (base64 .p8). "
                         + "Also e.g. SLACK_URL.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach($secretRows) { $row in
                        HStack(spacing: 8) {
                            TextField("KEY", text: $row.key)
                                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                                .labelsHidden()
                                .frame(width: 190)
                            SecureField("value", text: $row.value)
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            Button(role: .destructive) {
                                secretRows.removeAll { $0.id == row.id }
                            } label: { Image(systemName: "minus.circle.fill").foregroundStyle(world.bad) }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button { secretRows.append(SecretRow(key: "", value: "")) } label: {
                        Label("Add secret", systemImage: "plus")
                    }
                    .buttonStyle(ClaySoftButtonStyle(world: world))
                } header: { WorldSectionHeader(title: "Secrets", symbol: "key.fill", world: world, tint: world.warm) }

                Section {
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

                    Picker("How", selection: $pipeline.config.triggerMode) {
                        ForEach(TriggerMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if pipeline.config.triggerMode == .polling {
                        Stepper("Poll every \(pipeline.config.pollSeconds)s",
                                value: $pipeline.config.pollSeconds, in: 5...3600, step: 5)
                        Text("Asks Bitbucket on a timer. Simple and works anywhere; up to "
                             + "\(pipeline.config.pollSeconds)s between a commit and the build.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Listen on port") {
                            TextField("8787", value: $pipeline.config.webhookPort, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 90)
                        }
                        LabeledContent("Secret (recommended)") {
                            SecureField("blank = accept any POST", text: $pipeline.config.webhookSecret)
                                .textFieldStyle(.roundedBorder)
                        }
                        Text(webhookHelp).font(.caption).foregroundStyle(.secondary)
                    }

                    Stepper(pipeline.config.buildTimeoutSeconds == 0
                            ? "Build timeout: none"
                            : "Build timeout: \(pipeline.config.buildTimeoutSeconds / 60) min",
                            value: $pipeline.config.buildTimeoutSeconds, in: 0...7200, step: 300)
                    Text("Cancel a build that runs longer than this. Keeps a hung build "
                         + "from wedging an unattended runner.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("Post build status to commits",
                           isOn: $pipeline.config.postStatus)
                } header: { WorldSectionHeader(title: "Trigger", symbol: "dot.radiowaves.left.and.right", world: world, tint: world.warm) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            footer
        }
        .frame(width: 560, height: 680)
        .background(WorldBackdrop(world: world))
        .task { loadSecretRows(); await reloadAll() }
        .onChange(of: pipeline.config.repoSlug) {
            pipeline.config.branch = ""
            Task { await reloadBranches() }
        }
        .onChange(of: pipeline.config.provider) {
            repos = []; branches = []; loadError = nil
            Task { await reloadAll() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ClayTile(systemImage: "slider.horizontal.3", fill: world.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Pipeline").font(.system(.title2, design: .rounded).weight(.bold))
                Text(pipeline.config.name.isEmpty ? "New pipeline" : pipeline.config.name)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .background {
            LinearGradient(colors: [world.primary.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                .background(world.card)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { commitSecrets(); pool.commitEdits(); dismiss() }
                .buttonStyle(ClayButtonStyle(world: world))
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .background(.bar)
    }

    private var webhookHelp: String {
        let events = pipeline.config.watchMode == .pullRequests ? "Push and Pull Request" : "Push"
        return "Builds the instant Bitbucket calls us — no lag, no idle polling. In the "
            + "repo's Settings → Webhooks, add a hook to "
            + "http://<this-mac>:\(pipeline.config.webhookPort)/ for \(events) events. "
            + "The Mac must be reachable at that URL (same LAN, or a tunnel like cloudflared/ngrok)."
    }

    // MARK: - Controls

    private var repoControls: some View {
        Group {
            // Workspace: free text. Atlassian deprecated listing all workspaces
            // (CHANGE-2770), so you type the slug (e.g. "academytools").
            LabeledContent(pipeline.config.provider.ownerLabel) {
                HStack {
                    TextField(pipeline.config.provider.ownerPlaceholder, text: $pipeline.config.workspace)
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
        guard let client = pool.makeClient(for: pipeline.config.provider),
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
        guard let client = pool.makeClient(for: pipeline.config.provider),
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
