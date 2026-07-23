//
//  FlowInspectorView.swift
//  MacON
//
//  The block inspector (rename, params, model pickers, last output) and the
//  flow's run history — every run this Mac recorded, down to each block's
//  output and timing. Ported from the companion, AppKit-native.
//

import SwiftUI

// MARK: - Node inspector

struct NodeInspector: View {
    @Binding var node: FlowNode
    let world: WorldStyle
    let flows: FlowsModel
    let result: FlowNodeResult?
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var spec: BlockSpec { BlockSpec.spec(node.type) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: spec.symbol)
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color(nsColor: spec.category.tint(world.box)),
                                        in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(spec.title)
                                .font(.system(.body, design: .rounded).weight(.bold))
                            Text(spec.blurb)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    TextField("Custom name (optional)", text: Binding(
                        get: { node.name ?? "" },
                        set: { node.name = $0.isEmpty ? nil : $0 }))
                    Toggle("Enabled", isOn: $node.enabled)
                }

                if !spec.params.isEmpty {
                    Section {
                        ForEach(spec.params) { param in control(param) }
                    } header: {
                        WorldSectionHeader(title: "Settings", symbol: "slider.horizontal.3",
                                           world: world)
                    }
                }

                if let result, result.status == "ok" || result.status == "failed" {
                    Section {
                        if let error = result.error, !error.isEmpty {
                            Text(error)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(world.bad)
                                .textSelection(.enabled)
                        }
                        if !result.output.isEmpty {
                            Text(result.output)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(14)
                        }
                        if result.ms > 0 {
                            Text("Took \(result.ms) ms")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        WorldSectionHeader(title: "Last run", symbol: "clock.arrow.circlepath",
                                           world: world,
                                           tint: result.status == "failed" ? world.bad : world.good)
                    }
                }

                Section {
                    Button(role: .destructive) { onDelete() } label: {
                        Label("Delete block", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .formStyle(.grouped)
            .worldChrome(world)
            .navigationTitle(node.name ?? spec.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Param controls

    @ViewBuilder
    private func control(_ param: BlockParam) -> some View {
        switch param.kind {
        case .text:
            LabeledContent(param.label) {
                TextField(param.placeholder.isEmpty ? param.fallback : param.placeholder,
                          text: binding(param))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
            }
        case .number:
            LabeledContent(param.label) {
                TextField(param.fallback, text: binding(param))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
        case .multiline:
            VStack(alignment: .leading, spacing: 4) {
                Text(param.label)
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: binding(param))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 76)
                    .autocorrectionDisabled()
                if !param.placeholder.isEmpty {
                    Text(param.placeholder)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
        case .pick(let options):
            Picker(param.label, selection: bindingWithFallback(param)) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        case .localModel, .visionModel:
            let models = models(visionOnly: {
                if case .visionModel = param.kind { return true }; return false
            }())
            if models.isEmpty {
                LabeledContent(param.label) {
                    Text("No models — is Ollama running?")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Picker(param.label, selection: bindingWithFallback(param, fallback: models.first ?? "")) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
        case .claudeModel:
            cloudControl(param, models: CloudAI.claudeModels, provider: "Claude",
                         key: Binding(get: { CloudAI.claudeKey }, set: { CloudAI.claudeKey = $0 }))
        case .openaiModel:
            cloudControl(param, models: CloudAI.openaiModels, provider: "OpenAI",
                         key: Binding(get: { CloudAI.openaiKey }, set: { CloudAI.openaiKey = $0 }))
        case .geminiModel:
            cloudControl(param, models: CloudAI.geminiModels, provider: "Gemini",
                         key: Binding(get: { CloudAI.geminiKey }, set: { CloudAI.geminiKey = $0 }))
        case .customProvider:
            let providers = CustomProviders.all
            if providers.isEmpty {
                LabeledContent(param.label) {
                    Text("Add one in Settings → AI Providers")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Picker(param.label, selection: bindingWithFallback(param, fallback: providers.first?.id ?? "")) {
                    ForEach(providers) { Text($0.name).tag($0.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func cloudControl(_ param: BlockParam,
                              models: [(id: String, label: String)],
                              provider: String, key: Binding<String>) -> some View {
        Picker(param.label, selection: bindingWithFallback(param)) {
            ForEach(models, id: \.id) { Text($0.label).tag($0.id) }
        }
        SecureField("\(provider) API key", text: key)
            .autocorrectionDisabled()
        if key.wrappedValue.isEmpty {
            Text("Add your \(provider) key — stored in this Mac's Keychain, used only when a run reaches this block.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(world.warm)
        }
    }

    private func models(visionOnly: Bool) -> [String] {
        flows.localModels.filter { visionOnly ? $0.vision : true }.map(\.name)
    }

    private func binding(_ param: BlockParam) -> Binding<String> {
        Binding(get: { node.params[param.key] ?? "" },
                set: { node.params[param.key] = $0.isEmpty ? nil : $0 })
    }

    private func bindingWithFallback(_ param: BlockParam, fallback: String = "") -> Binding<String> {
        let def = param.fallback.isEmpty ? fallback : param.fallback
        return Binding(get: { node.params[param.key] ?? def },
                       set: { node.params[param.key] = $0 })
    }
}

// MARK: - Run history

struct FlowRunHistoryView: View {
    let flow: Flow
    let flows: FlowsModel
    let world: WorldStyle

    @Environment(\.dismiss) private var dismiss
    @State private var runs: [FlowRun] = []

    var body: some View {
        NavigationStack {
            Group {
                if runs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 34))
                            .foregroundStyle(world.ink.opacity(0.3))
                        Text("No runs yet")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(world.ink.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WorldBackdrop(world: world))
                } else {
                    List {
                        ForEach(runs) { run in
                            NavigationLink {
                                FlowRunDetailView(run: run, flow: flow, world: world)
                            } label: { row(run) }
                        }
                    }
                    .worldChrome(world)
                }
            }
            .navigationTitle("Run history")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { runs = flows.runs(of: flow) }
    }

    private func row(_ run: FlowRun) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(run.status)).foregroundStyle(tint(run.status))
            VStack(alignment: .leading, spacing: 2) {
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                Text("\(run.trigger) · \(run.results.count) block\(run.results.count == 1 ? "" : "s")\(duration(run))")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(_ status: String) -> String {
        switch status {
        case "ok":        return "checkmark.circle.fill"
        case "failed":    return "xmark.circle.fill"
        case "cancelled": return "stop.circle.fill"
        default:          return "circle.dotted"
        }
    }

    private func tint(_ status: String) -> Color {
        switch status {
        case "ok":        return world.good
        case "failed":    return world.bad
        case "cancelled": return world.warm
        default:          return world.ink.opacity(0.4)
        }
    }

    private func duration(_ run: FlowRun) -> String {
        guard let end = run.finishedAt else { return "" }
        return String(format: " · %.1fs", end.timeIntervalSince(run.startedAt))
    }
}

/// One run, block by block: status, timing, output, error.
struct FlowRunDetailView: View {
    let run: FlowRun
    let flow: Flow
    let world: WorldStyle

    var body: some View {
        List {
            ForEach(run.results, id: \.nodeId) { result in
                Section {
                    if let error = result.error, !error.isEmpty {
                        Text(error)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(world.bad)
                            .textSelection(.enabled)
                    }
                    if !result.output.isEmpty {
                        Text(result.output)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if result.output.isEmpty && (result.error ?? "").isEmpty {
                        Text(result.status == "skipped" ? "Skipped" : "No output")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: statusIcon(result.status))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(statusTint(result.status))
                        Text(title(result.nodeId))
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundStyle(world.ink.opacity(0.6))
                        Spacer()
                        if result.ms > 0 {
                            Text("\(result.ms) ms")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .textCase(nil)
                }
            }
        }
        .worldChrome(world)
        .navigationTitle(run.startedAt.formatted(date: .omitted, time: .standard))
    }

    private func title(_ nodeId: String) -> String {
        guard let node = flow.nodes.first(where: { $0.id == nodeId }) else { return "Removed block" }
        return node.name ?? BlockSpec.spec(node.type).title
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "ok":      return "checkmark.circle.fill"
        case "failed":  return "xmark.circle.fill"
        case "skipped": return "minus.circle"
        default:        return "circle.dotted"
        }
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "ok":      return world.good
        case "failed":  return world.bad
        default:        return world.ink.opacity(0.4)
        }
    }
}
