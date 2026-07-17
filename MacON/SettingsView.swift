//
//  SettingsView.swift
//  MacON
//
//  Accounts, secrets, companion, and cleanup — dressed in the app's theme.
//

import SwiftUI
import UniformTypeIdentifiers
import MaconKit

struct SettingsView: View {
    @EnvironmentObject private var pool: RunnerPool
    @EnvironmentObject private var pipelines: PipelinePool
    @EnvironmentObject private var companion: CompanionManager
    @EnvironmentObject private var curtain: PrivacyCurtain
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage(WorldStyle.themeKey) private var worldRaw = WorldTheme.pastel.rawValue
    @State private var secretRows: [SecretRow] = []
    @State private var exportWithSecrets = false
    @State private var showPairing = false
    @State private var newPasscode = ""
    @State private var unlockPassword = ""
    @State private var selection: SettingsCategory = .appearance
    @State private var aiChecked = false
    @State private var aiModelCount: Int?              // nil once checked → Ollama unreachable
    /// Captured on open so Cancel can put the live-applied settings back.
    @State private var snapshot: SettingsSnapshot?

    private var world: WorldStyle { WorldStyle(raw: worldRaw, dark: scheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(SettingsCategory.allCases, selection: $selection) { cat in
                    Label {
                        Text(cat.title)
                    } icon: {
                        CategoryIcon(symbol: cat.symbol, tint: cat.tint(world))
                    }
                    .tag(cat)
                }
                .navigationSplitViewColumnWidth(min: 196, ideal: 210, max: 240)
                .listStyle(.sidebar)
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)

            Divider()
            footer
        }
        .frame(width: 760, height: 600)
        .background(WorldBackdrop(world: world))
        .sheet(isPresented: $showPairing) { CompanionPairingView() }
        .task {
            await pool.refreshReclaimable()
            secretRows = pipelines.globalSecretKeys.map {
                SecretRow(key: $0, value: Keychain.get(account: PipelinePool.globalSecretAccount($0)))
            }
            if snapshot == nil { snapshot = captureSnapshot() }
        }
    }

    // MARK: Chrome

    /// The right-hand pane: only the selected category's sections.
    @ViewBuilder private var detail: some View {
        Form {
            switch selection {
            case .appearance: appearanceSection
            case .accounts:   bitbucketSection; githubSection
            case .secrets:    secretsSection
            case .companion:  companionSection; aiSection
            case .power:      powerSection
            case .privacy:    privacyScreenSection
            case .portable:   portableSection
            case .cleanup:    cleanupSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(selection.title)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                revert()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Save") {
                pipelines.setGlobalSecrets(secretRows.map { ($0.key, $0.value) })
                dismiss()
            }
            .buttonStyle(ClayButtonStyle(world: world))
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: Snapshot / revert

    private func captureSnapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            email: pipelines.email, apiToken: pipelines.apiToken, githubToken: pipelines.githubToken,
            port: companion.port, shareScreen: companion.shareScreen,
            allowControl: companion.allowControl, remoteEnabled: companion.remoteEnabled,
            cleanup: pool.cleanupSettings,
            curtainStyle: curtain.style, curtainMessage: curtain.message)
    }

    /// Put back every live-applied value we changed. Explicit actions (starting
    /// the server, raising the curtain, saving a passcode, picking an image,
    /// cleaning caches) are one-shot and intentionally not undone here.
    private func revert() {
        guard let s = snapshot else { return }
        if pipelines.email != s.email { pipelines.email = s.email }
        if pipelines.apiToken != s.apiToken { pipelines.apiToken = s.apiToken }
        if pipelines.githubToken != s.githubToken { pipelines.githubToken = s.githubToken }
        if companion.port != s.port { companion.port = s.port }
        if companion.shareScreen != s.shareScreen { companion.shareScreen = s.shareScreen }
        if companion.allowControl != s.allowControl { companion.allowControl = s.allowControl }
        if companion.remoteEnabled != s.remoteEnabled { companion.remoteEnabled = s.remoteEnabled }
        if pool.cleanupSettings != s.cleanup { pool.cleanupSettings = s.cleanup }
        if curtain.style != s.curtainStyle { curtain.style = s.curtainStyle }
        if curtain.message != s.curtainMessage { curtain.message = s.curtainMessage }
    }

    // MARK: Sections

    private var appearanceSection: some View {
        Section {
            caption("The world the whole app is made of — colors, models, and every screen's paint. "
                    + "Shared look with the companion app; applies instantly and is remembered.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(WorldTheme.allCases) { theme in
                        WorldPreviewCard(theme: theme,
                                         selected: worldRaw == theme.rawValue) {
                            worldRaw = theme.rawValue
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
        } header: { WorldSectionHeader(title: "World", symbol: "cube.fill", world: world) }
    }

    private var bitbucketSection: some View {
        Section {
            caption("Used to poll for commits, clone over HTTPS, and post build status. "
                    + "Create an API token in Atlassian account settings.")
            TextField("Atlassian email", text: $pipelines.email).autocorrectionDisabled()
            SecureField("API token", text: $pipelines.apiToken)
            if pipelines.credentials.isComplete {
                Pill(text: "Account set", systemImage: "checkmark.seal.fill", tint: world.good)
            } else {
                Pill(text: "Incomplete", systemImage: "exclamationmark.triangle.fill", tint: world.warm)
            }
        } header: { WorldSectionHeader(title: "Bitbucket account", symbol: "cloud.fill", world: world) }
    }

    private var githubSection: some View {
        Section {
            caption("A Personal Access Token with repo access (classic `repo` scope, or "
                    + "fine-grained: Contents + Commit statuses + Pull requests).")
            SecureField("Personal Access Token", text: $pipelines.githubToken)
            if pipelines.hasCredentials(for: .github) {
                Pill(text: "Token set", systemImage: "checkmark.seal.fill", tint: world.good)
            } else {
                Pill(text: "Not set", systemImage: "exclamationmark.triangle.fill", tint: world.warm)
            }
        } header: { WorldSectionHeader(title: "GitHub account", symbol: "chevron.left.forwardslash.chevron.right", world: world) }
    }

    private var secretsSection: some View {
        Section {
            caption("Stored in the macOS Keychain, never in a repo. Shared by every pipeline — "
                    + "ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_CONTENT, SLACK_URL. A pipeline's own "
                    + "secret overrides a global one.")
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
        } header: { WorldSectionHeader(title: "Global secrets", symbol: "key.fill", world: world, tint: world.warm) }
    }

    private var portableSection: some View {
        Section {
            caption("Export your pipelines to JSON, then run them headless with "
                    + "`macon watch --config <file>`.")
            Toggle("Include secrets & tokens in the file", isOn: $exportWithSecrets)
            if exportWithSecrets {
                Pill(text: "Contains tokens in plain text — keep private",
                     systemImage: "exclamationmark.triangle.fill", tint: world.warm)
            }
            HStack {
                Button { exportConfig() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(ClaySoftButtonStyle(world: world))
                Button { importConfig() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(ClaySoftButtonStyle(world: world))
            }
        } header: { WorldSectionHeader(title: "Portable config", symbol: "terminal.fill", world: world) }
    }

    private var companionSection: some View {
        Section {
            caption("Monitor builds and control this Mac from your phone or iPad on the same "
                    + "network. Pair once; it reconnects on its own.")
            Toggle("Serve the companion app", isOn: Binding(
                get: { companion.isRunning },
                set: { on in
                    if on {
                        companion.start(runnerName: ProcessInfo.processInfo.hostName,
                                        runners: { pipelines.pipelines },
                                        pool: pipelines)
                    } else { companion.stop() }
                }))
            HStack {
                Text("Port")
                Spacer()
                TextField("8899", value: $companion.port, format: .number.grouping(.never))
                    .frame(width: 80).multilineTextAlignment(.trailing)
                    .disabled(companion.isRunning)
            }
            if companion.isRunning {
                HStack {
                    Pill(text: "Listening on \(companion.address)",
                         systemImage: "dot.radiowaves.left.and.right", tint: world.good)
                    Spacer()
                    Button { showPairing = true } label: { Label("Pair a device…", systemImage: "qrcode") }
                        .buttonStyle(ClaySoftButtonStyle(world: world))
                }
                if !companion.devices.isEmpty {
                    caption("\(companion.devices.count) paired device(s)")
                }

                Toggle("Remote access (internet tunnel)", isOn: $companion.remoteEnabled)
                remoteStatus
            }
            Toggle("Let paired devices view this screen", isOn: $companion.shareScreen)
            Toggle("Let paired devices control this Mac (cursor & keyboard)", isOn: $companion.allowControl)
            if companion.allowControl {
                accessibilityRow
            }
            Toggle("Let paired devices use Code (files & terminal)", isOn: $companion.allowCode)
            if companion.allowCode {
                caption("Powers the companion's native Code workspace: it browses and "
                        + "edits text files in your home folder over the paired "
                        + "connection — no screen stream — and opens a real shell "
                        + "(zsh) on this Mac in its terminal. VS Code picks edits up "
                        + "instantly.")
            }
        } header: { WorldSectionHeader(title: "Companion app", symbol: "ipad.and.iphone", world: world) }
    }

    /// Local AI: let a paired device chat with this Mac's Ollama.
    private var aiSection: some View {
        Section {
            caption("Chat with a large language model running locally on this Mac "
                    + "(via Ollama) from a paired device. Prompts and any attached "
                    + "files go to the model on this Mac and never leave it.")
            Toggle("Let paired devices use local AI (Ollama)", isOn: $companion.allowAI)
            if companion.allowAI {
                if !aiChecked {
                    Pill(text: "Checking for Ollama…", systemImage: "clock.fill", tint: world.warm)
                } else if let n = aiModelCount {
                    Pill(text: n == 0 ? "Ollama running — pull a model to start"
                                      : "Ollama running — \(n) model\(n == 1 ? "" : "s")",
                         systemImage: "cpu.fill",
                         tint: n == 0 ? world.warm : world.good)
                } else {
                    Pill(text: "Ollama not detected — install it from ollama.com",
                         systemImage: "exclamationmark.triangle.fill", tint: world.warm)
                }
                caption("Install Ollama and pull a model (e.g. `ollama pull llama3.2`). "
                        + "Vision models such as llava also accept image attachments "
                        + "from the device.")
            }
        } header: {
            WorldSectionHeader(title: "Local AI", symbol: "brain.head.profile",
                               world: world, tint: world.primary)
        }
        .task(id: companion.allowAI) {
            guard companion.allowAI else { aiChecked = false; return }
            aiChecked = false
            aiModelCount = await companion.probeOllama()
            aiChecked = true
        }
    }

    /// Tunnel state row(s) under the remote-access toggle.
    @ViewBuilder
    private var remoteStatus: some View {
        switch companion.tunnel.status {
        case .off:
            if companion.remoteEnabled { EmptyView() }
            else { caption("Reach this Mac from anywhere via a free Cloudflare quick tunnel. "
                           + "Pairing codes and device tokens are still required — the link alone grants nothing.") }
        case .notInstalled:
            HStack(spacing: 8) {
                Pill(text: "cloudflared is not installed",
                     systemImage: "exclamationmark.triangle.fill", tint: world.warm)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install cloudflared", forType: .string)
                } label: { Label("Copy install command", systemImage: "doc.on.doc") }
                    .buttonStyle(ClaySoftButtonStyle(world: world))
                Spacer()
            }
        case .starting:
            Pill(text: "Starting tunnel…", systemImage: "clock.fill", tint: world.primary)
        case .running(let url):
            HStack(spacing: 8) {
                Pill(text: url.replacingOccurrences(of: "https://", with: ""),
                     systemImage: "globe", tint: world.good)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy the public address")
                Spacer()
            }
            caption("Use this address in the companion app instead of the local one. "
                    + "It changes each time the tunnel restarts — update it on the device "
                    + "(no re-pairing needed).")
        case .failed(let message):
            HStack(spacing: 8) {
                Pill(text: message, systemImage: "xmark.octagon.fill", tint: world.bad)
                Button("Retry") { companion.remoteEnabled = false; companion.remoteEnabled = true }
                    .buttonStyle(ClaySoftButtonStyle(world: world))
                Spacer()
            }
        }
    }

    private var powerSection: some View {
        Section {
            caption("Keep this Mac reachable from a paired device — stay awake so "
                    + "it never idle-sleeps, and let the device wake the display or "
                    + "unlock the screen.")

            Toggle("Sync reachability over iCloud", isOn: $companion.iCloudEnabled)
            if companion.iCloudEnabled {
                if companion.iCloudActive {
                    Pill(text: companion.lastCloudPublish == nil ? "Publishing…" : "Published — device auto-follows",
                         systemImage: "cloud.fill", tint: world.good)
                } else if !companion.iCloudAvailable {
                    Pill(text: "Sign in to iCloud (and add the iCloud capability in Xcode)",
                         systemImage: "exclamationmark.icloud.fill", tint: world.warm)
                } else {
                    Pill(text: "Starts with the companion server", systemImage: "cloud", tint: world.warm)
                }
                caption("Publishes this Mac's current address (incl. a rotated tunnel "
                        + "URL) and status to your private iCloud database, so a paired "
                        + "device on the same Apple ID re-points itself with no action "
                        + "here. Wake/unlock can also arrive over iCloud.")
            }

            Divider().padding(.vertical, 2)

            Toggle("Stay awake while the companion is running", isOn: $companion.keepAwake)
            if companion.keepAwake {
                Pill(text: companion.isRunning ? "Awake — reachable" : "Applies when the server is on",
                     systemImage: "bolt.fill",
                     tint: companion.isRunning ? world.good : world.warm)
            } else {
                caption("The Mac may idle-sleep and drop off the network. From full "
                        + "sleep, the device's Wake-on-LAN packet only works if macOS "
                        + "“Wake for network access” is enabled (Energy settings).")
            }

            Divider().padding(.vertical, 2)

            Toggle("Let paired devices wake the display", isOn: $companion.allowWake)

            Toggle("Let paired devices unlock this Mac", isOn: $companion.allowUnlock)
            if companion.allowUnlock {
                SecureField(companion.hasUnlockPassword ? "Password saved — replace it" : "Login password",
                            text: $unlockPassword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { companion.unlockPassword = unlockPassword; unlockPassword = "" }
                HStack {
                    Button("Save password") {
                        companion.unlockPassword = unlockPassword; unlockPassword = ""
                    }
                    .buttonStyle(ClaySoftButtonStyle(world: world))
                    .disabled(unlockPassword.isEmpty)
                    if companion.hasUnlockPassword {
                        Button(role: .destructive) { companion.unlockPassword = "" } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(ClaySoftButtonStyle(world: world, danger: true))
                    }
                    Spacer()
                    Pill(text: companion.hasUnlockPassword ? "Stored in Keychain" : "No password set",
                         systemImage: companion.hasUnlockPassword ? "key.fill" : "exclamationmark.triangle.fill",
                         tint: companion.hasUnlockPassword ? world.good : world.warm)
                }
                accessibilityRow
                caption("Stored only in the macOS Keychain. Needs Accessibility. "
                        + "macOS blocks synthetic typing under Secure Keyboard Entry, "
                        + "so unlock is best-effort — it won't defeat a FileVault "
                        + "preboot screen.")
            }
        } header: { WorldSectionHeader(title: "Power & Access", symbol: "power", world: world, tint: world.good) }
    }

    /// Accessibility status + a one-tap "grant" that registers the app and
    /// opens the right System Settings pane. Needed for control and unlock.
    @ViewBuilder private var accessibilityRow: some View {
        if companion.accessibilityTrusted {
            Pill(text: "Accessibility granted", systemImage: "checkmark.seal.fill", tint: world.good)
        } else {
            HStack {
                Pill(text: "Accessibility needed", systemImage: "exclamationmark.triangle.fill", tint: world.warm)
                Spacer()
                Button { companion.requestAccessibility() } label: {
                    Label("Grant Accessibility…", systemImage: "hand.raised.fill")
                }
                .buttonStyle(ClaySoftButtonStyle(world: world))
            }
        }
    }

    private var privacyScreenSection: some View {
        Section {
            caption("Cover this Mac's screen with a “don't touch” wall while you keep "
                    + "using it from a paired device — the companion still sees and controls "
                    + "the real screen. It's a privacy curtain, not a lock: it deters a "
                    + "passerby, but isn't a security boundary.")

            // Live preview of the current look.
            HStack { Spacer(); CurtainPreview(curtain: curtain); Spacer() }
                .padding(.vertical, 2)

            // Background style.
            VStack(alignment: .leading, spacing: 6) {
                Text("Background").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(CurtainBackground.allCases) { bg in
                        let on = curtain.style.background == bg
                        Label(bg.title, systemImage: bg.symbol)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(on ? AnyShapeStyle(curtain.style.color.gradient) : AnyShapeStyle(.regularMaterial),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .foregroundStyle(on ? .white : .primary)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(.white.opacity(on ? 0.25 : 0.08)))
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.spring(duration: 0.3)) { curtain.style.background = bg } }
                    }
                }
            }

            if curtain.style.background == .image {
                HStack(spacing: 10) {
                    Button { chooseCurtainImage() } label: { Label("Choose Image…", systemImage: "photo") }
                        .buttonStyle(ClaySoftButtonStyle(world: world))
                    if curtain.style.imagePath != nil {
                        Button(role: .destructive) { curtain.clearCustomImage() } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(ClaySoftButtonStyle(world: world, danger: true))
                    } else {
                        caption("No image chosen yet.")
                    }
                    Spacer()
                }
            }

            // Accent color.
            VStack(alignment: .leading, spacing: 6) {
                Text("Color").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(CurtainColor.allCases) { c in
                        Circle()
                            .fill(c.gradient)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                            .overlay(Circle().strokeBorder(c.base, lineWidth: curtain.style.color == c ? 2.5 : 0).padding(-4))
                            .scaleEffect(curtain.style.color == c ? 1.1 : 1)
                            .onTapGesture { withAnimation(.spring(duration: 0.3)) { curtain.style.color = c } }
                    }
                    Spacer()
                }
            }

            // Glyph — replaced by the 3D machine in the World style.
            if curtain.style.background != .world {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Symbol").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(curtainGlyphOptions, id: \.self) { g in
                                Image(systemName: g)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(curtain.style.glyph == g ? AnyShapeStyle(curtain.style.color.gradient) : AnyShapeStyle(Color.secondary))
                                    .frame(width: 40, height: 34)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(curtain.style.glyph == g ? curtain.style.color.base : .white.opacity(0.08),
                                                      lineWidth: curtain.style.glyph == g ? 2 : 1))
                                    .onTapGesture { withAnimation { curtain.style.glyph = g } }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }

                // Symbol animation.
                Picker("Symbol animation", selection: $curtain.style.glyphAnimation) {
                    ForEach(CurtainGlyphAnimation.allCases) { Text($0.title).tag($0) }
                }
            }

            Toggle("Show the “Press ⌃⌥⌘U to unlock” hint", isOn: $curtain.style.showHint)

            Picker("Motion", selection: $curtain.style.motion) {
                ForEach(CurtainMotion.allCases) { Text($0.title).tag($0) }
            }
            caption("Keeps the text moving so it can't burn into an OLED display. "
                    + "“DVD bounce” ricochets it around the screen corners.")

            TextField("Wall message", text: $curtain.message)
                .textFieldStyle(.roundedBorder)

            // Optional dismiss passcode.
            HStack(spacing: 8) {
                SecureField(curtain.hasPasscode ? "Change passcode" : "Set a passcode (optional)",
                            text: $newPasscode)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button("Save") {
                    curtain.setPasscode(newPasscode); newPasscode = ""
                }
                .buttonStyle(ClaySoftButtonStyle(world: world))
                .disabled(newPasscode.isEmpty)
                if curtain.hasPasscode {
                    Button(role: .destructive) { curtain.clearPasscode() } label: {
                        Image(systemName: "trash").foregroundStyle(world.bad)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove passcode")
                }
            }
            if curtain.hasPasscode {
                Pill(text: "Passcode required to unlock", systemImage: "lock.fill", tint: world.good)
            } else {
                Pill(text: "No passcode — anyone can unlock with the hot key",
                     systemImage: "lock.open.fill", tint: world.warm)
            }

            HStack {
                Button {
                    curtain.raise(); dismiss()
                } label: { Label("Raise Privacy Screen", systemImage: "hand.raised.fill") }
                .buttonStyle(ClayButtonStyle(world: world))
                .disabled(curtain.isUp)
                Spacer()
                Pill(text: "Unlock with ⌃⌥⌘U", systemImage: "keyboard", tint: world.primary)
            }
        } header: { WorldSectionHeader(title: "Privacy screen", symbol: "hand.raised.fill", world: world, tint: world.warm) }
    }

    private var cleanupSection: some View {
        Section {
            Toggle("Empty the runner's working directory when it stops",
                   isOn: $pool.cleanupSettings.emptyWorkingDirOnStop)
            Divider().padding(.vertical, 2)
            caption("Shared caches — only cleaned when all runners are stopped.")
            Toggle("Xcode DerivedData", isOn: $pool.cleanupSettings.derivedData)
            Toggle("SwiftPM caches", isOn: $pool.cleanupSettings.swiftPMCache)
            Toggle("Xcode Archives", isOn: $pool.cleanupSettings.archives)
            Toggle("Delete unavailable simulators", isOn: $pool.cleanupSettings.pruneSimulators)
            HStack {
                Button { pool.cleanCaches() } label: {
                    if pool.isCleaningCaches { ProgressView().controlSize(.small) }
                    else { Label("Clean Caches Now", systemImage: "trash.fill") }
                }
                .buttonStyle(ClaySoftButtonStyle(world: world, danger: true))
                .disabled(pool.anyActive || pool.isCleaningCaches)
                Spacer()
                if pool.anyActive {
                    Pill(text: "Stop all runners first", systemImage: "exclamationmark.circle.fill", tint: world.warm)
                } else if pool.reclaimableBytes > 0 {
                    Pill(text: "~\(ByteCountFormatter.string(fromByteCount: pool.reclaimableBytes, countStyle: .file)) reclaimable",
                         systemImage: "internaldrive.fill", tint: world.primary)
                }
            }
        } header: { WorldSectionHeader(title: "Cleanup", symbol: "sparkles", world: world, tint: world.good) }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func chooseCurtainImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            curtain.setCustomImage(from: url)
        }
    }

    // MARK: - Export / Import

    private func exportConfig() {
        pipelines.setGlobalSecrets(secretRows.map { ($0.key, $0.value) })
        let bundle = pipelines.makeExport(includeSecrets: exportWithSecrets)
        guard let data = try? bundle.encoded() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macon-export.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
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

// MARK: - Snapshot

/// The live-applied settings captured when the sheet opens, so Cancel can
/// restore them exactly.
struct SettingsSnapshot {
    var email: String
    var apiToken: String
    var githubToken: String
    var port: Int
    var shareScreen: Bool
    var allowControl: Bool
    var remoteEnabled: Bool
    var cleanup: CleanupSettings
    var curtainStyle: CurtainStyle
    var curtainMessage: String
}

// MARK: - Categories

/// The settings panes, in sidebar order — one focused screen each, the way
/// System Settings splits things up.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance, accounts, secrets, companion, power, privacy, portable, cleanup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "World"
        case .accounts:   return "Accounts"
        case .secrets:    return "Global Secrets"
        case .companion:  return "Companion"
        case .power:      return "Power & Access"
        case .privacy:    return "Privacy Screen"
        case .portable:   return "Portable Config"
        case .cleanup:    return "Cleanup"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "cube.fill"
        case .accounts:   return "person.crop.circle.fill"
        case .secrets:    return "key.fill"
        case .companion:  return "ipad.and.iphone"
        case .power:      return "power"
        case .privacy:    return "hand.raised.fill"
        case .portable:   return "terminal.fill"
        case .cleanup:    return "sparkles"
        }
    }

    func tint(_ world: WorldStyle) -> Color {
        switch self {
        case .appearance: return world.primary
        case .accounts:   return world.warm
        case .secrets:    return world.warm
        case .companion:  return world.primary
        case .power:      return world.good
        case .privacy:    return world.bad
        case .portable:   return world.good
        case .cleanup:    return world.good
        }
    }
}

/// The small colored rounded-square glyph used in the sidebar, like the icons
/// down the left of System Settings.
private struct CategoryIcon: View {
    let symbol: String
    let tint: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - World preview card

/// One world in the gallery: a real rendered snapshot of its station over
/// its own backdrop, with the world's name below.
private struct WorldPreviewCard: View {
    @Environment(\.colorScheme) private var scheme
    let theme: WorldTheme
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let accent = Color(nsColor: theme.palette.primary)
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    LinearGradient(
                        colors: [Color(nsColor: theme.palette.paper(dark: scheme == .dark)),
                                 Color(nsColor: theme.palette.edge(dark: scheme == .dark))],
                        startPoint: .top, endPoint: .bottom)
                    Image(nsImage: WorldPreview.image(for: theme, dark: scheme == .dark))
                        .resizable()
                        .scaledToFill()
                }
                .frame(width: 96, height: 154)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? accent : Color.primary.opacity(0.08),
                                      lineWidth: selected ? 2.5 : 1)
                }
                .scaleEffect(hovering && !selected ? 1.03 : 1)
                .animation(.spring(duration: 0.25), value: hovering)

                HStack(spacing: 4) {
                    Image(systemName: theme.icon).font(.system(size: 9))
                    Text(theme.label)
                }
                .font(.system(.caption2, design: .rounded).weight(selected ? .bold : .medium))
                .foregroundStyle(selected ? accent : .secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(theme.label)
    }
}
