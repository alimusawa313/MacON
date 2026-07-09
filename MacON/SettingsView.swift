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
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var curtain: PrivacyCurtain
    @Environment(\.dismiss) private var dismiss
    @State private var secretRows: [SecretRow] = []
    @State private var exportWithSecrets = false
    @State private var showPairing = false
    @State private var newPasscode = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                appearanceSection
                bitbucketSection
                githubSection
                secretsSection
                portableSection
                companionSection
                privacyScreenSection
                cleanupSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            footer
        }
        .frame(width: 560, height: 720)
        .background(.regularMaterial)
        .sheet(isPresented: $showPairing) { CompanionPairingView() }
        .task {
            await pool.refreshReclaimable()
            secretRows = pipelines.globalSecretKeys.map {
                SecretRow(key: $0, value: Keychain.get(account: PipelinePool.globalSecretAccount($0)))
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 14) {
            IconTile(systemImage: "gearshape.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(.title2.weight(.bold))
                Text("Accounts · secrets · companion · cleanup")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .background {
            LinearGradient(colors: [Brand.blue.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                .background(.regularMaterial)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                pipelines.setGlobalSecrets(secretRows.map { ($0.key, $0.value) })
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: Sections

    private var appearanceSection: some View {
        Section {
            caption("Choose a fill style and an accent color. Applies instantly and is remembered.")
            ThemeControls()
                .padding(.vertical, 4)
        } header: { FormSectionHeader(title: "Appearance", systemImage: "paintpalette.fill", tint: Brand.blue) }
    }

    private var bitbucketSection: some View {
        Section {
            caption("Used to poll for commits, clone over HTTPS, and post build status. "
                    + "Create an API token in Atlassian account settings.")
            TextField("Atlassian email", text: $pipelines.email).autocorrectionDisabled()
            SecureField("API token", text: $pipelines.apiToken)
            if pipelines.credentials.isComplete {
                Pill(text: "Account set", systemImage: "checkmark.seal.fill", tint: Brand.emerald)
            } else {
                Pill(text: "Incomplete", systemImage: "exclamationmark.triangle.fill", tint: Brand.amber)
            }
        } header: { FormSectionHeader(title: "Bitbucket account", systemImage: "cloud.fill", tint: Brand.blue) }
    }

    private var githubSection: some View {
        Section {
            caption("A Personal Access Token with repo access (classic `repo` scope, or "
                    + "fine-grained: Contents + Commit statuses + Pull requests).")
            SecureField("Personal Access Token", text: $pipelines.githubToken)
            if pipelines.hasCredentials(for: .github) {
                Pill(text: "Token set", systemImage: "checkmark.seal.fill", tint: Brand.emerald)
            } else {
                Pill(text: "Not set", systemImage: "exclamationmark.triangle.fill", tint: Brand.amber)
            }
        } header: { FormSectionHeader(title: "GitHub account", systemImage: "chevron.left.forwardslash.chevron.right", tint: Brand.indigo) }
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
                    } label: { Image(systemName: "minus.circle.fill").foregroundStyle(Brand.rose) }
                        .buttonStyle(.borderless)
                }
            }
            Button { secretRows.append(SecretRow(key: "", value: "")) } label: {
                Label("Add secret", systemImage: "plus")
            }
            .buttonStyle(SoftButtonStyle())
        } header: { FormSectionHeader(title: "Global secrets", systemImage: "key.fill", tint: Brand.amber) }
    }

    private var portableSection: some View {
        Section {
            caption("Export your pipelines to JSON, then run them headless with "
                    + "`macon watch --config <file>`.")
            Toggle("Include secrets & tokens in the file", isOn: $exportWithSecrets)
            if exportWithSecrets {
                Pill(text: "Contains tokens in plain text — keep private",
                     systemImage: "exclamationmark.triangle.fill", tint: Brand.amber)
            }
            HStack {
                Button { exportConfig() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(SoftButtonStyle())
                Button { importConfig() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(SoftButtonStyle())
            }
        } header: { FormSectionHeader(title: "Portable config", systemImage: "terminal.fill", tint: Brand.cyan) }
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
                                        runners: { pipelines.pipelines })
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
                         systemImage: "dot.radiowaves.left.and.right", tint: Brand.emerald)
                    Spacer()
                    Button { showPairing = true } label: { Label("Pair a device…", systemImage: "qrcode") }
                        .buttonStyle(SoftButtonStyle())
                }
                if !companion.devices.isEmpty {
                    caption("\(companion.devices.count) paired device(s)")
                }
            }
            Toggle("Let paired devices view this screen", isOn: $companion.shareScreen)
            Toggle("Let paired devices control this Mac (cursor & keyboard)", isOn: $companion.allowControl)
            if companion.allowControl {
                Pill(text: "Grant Accessibility in System Settings → Privacy & Security",
                     systemImage: "exclamationmark.triangle.fill", tint: Brand.amber)
            }
        } header: { FormSectionHeader(title: "Companion app", systemImage: "ipad.and.iphone", tint: Brand.blue) }
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
                        .buttonStyle(SoftButtonStyle())
                    if curtain.style.imagePath != nil {
                        Button(role: .destructive) { curtain.clearCustomImage() } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(SoftButtonStyle(danger: true))
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
                    ForEach(ThemeColor.allCases) { c in
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

            // Glyph.
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
                .buttonStyle(SoftButtonStyle())
                .disabled(newPasscode.isEmpty)
                if curtain.hasPasscode {
                    Button(role: .destructive) { curtain.clearPasscode() } label: {
                        Image(systemName: "trash").foregroundStyle(Brand.rose)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove passcode")
                }
            }
            if curtain.hasPasscode {
                Pill(text: "Passcode required to unlock", systemImage: "lock.fill", tint: Brand.emerald)
            } else {
                Pill(text: "No passcode — anyone can unlock with the hot key",
                     systemImage: "lock.open.fill", tint: Brand.amber)
            }

            HStack {
                Button {
                    curtain.raise(); dismiss()
                } label: { Label("Raise Privacy Screen", systemImage: "hand.raised.fill") }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(curtain.isUp)
                Spacer()
                Pill(text: "Unlock with ⌃⌥⌘U", systemImage: "keyboard", tint: Brand.cyan)
            }
        } header: { FormSectionHeader(title: "Privacy screen", systemImage: "hand.raised.fill", tint: Brand.indigo) }
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
                .buttonStyle(SoftButtonStyle(danger: true))
                .disabled(pool.anyActive || pool.isCleaningCaches)
                Spacer()
                if pool.anyActive {
                    Pill(text: "Stop all runners first", systemImage: "exclamationmark.circle.fill", tint: Brand.amber)
                } else if pool.reclaimableBytes > 0 {
                    Pill(text: "~\(ByteCountFormatter.string(fromByteCount: pool.reclaimableBytes, countStyle: .file)) reclaimable",
                         systemImage: "internaldrive.fill", tint: Brand.cyan)
                }
            }
        } header: { FormSectionHeader(title: "Cleanup", systemImage: "sparkles", tint: Brand.emerald) }
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
