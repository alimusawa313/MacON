//
//  FlowsModel.swift
//  MacON
//
//  State for the Mac's own Flows editor. Unlike the companion — which edits
//  over the network and treats the Mac as the source of truth — this drives
//  the local FlowStore and FlowEngine directly: no HTTP, no "allow paired
//  devices" gate (that toggle is only about remote access). Edits autosave to
//  the same store the companion reaches, so a flow built here shows up there.
//

import Foundation
import Observation

@MainActor
@Observable
final class FlowsModel {
    private var store: FlowStore?
    private var engine: FlowEngine?
    private let ollama = OllamaService()

    private(set) var flows: [Flow] = []
    private(set) var loading = false
    /// Kept for parity with the companion's list view; always nil on the Mac.
    private(set) var loadError: String?

    /// Installed Ollama models, for the block inspectors' pickers.
    private(set) var localModels: [AIModelVM] = []

    /// A lightweight model row for the pickers (mirrors Ollama's DTO).
    struct AIModelVM: Identifiable, Hashable {
        let name: String
        let vision: Bool
        var id: String { name }
    }

    /// The run being watched live (the open flow's), polled until it finishes.
    private(set) var activeRun: FlowRun?
    private var pollTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    /// Point the model at the app's shared store + engine (from CompanionManager).
    func wire(store: FlowStore, engine: FlowEngine) {
        self.store = store
        self.engine = engine
    }

    // MARK: Loading

    func load() {
        flows = (store?.flows ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadModels() async {
        guard localModels.isEmpty else { return }
        localModels = await ollama.installedModels()
            .map { AIModelVM(name: $0.name, vision: $0.vision) }
    }

    // MARK: Editing

    /// Update in place and autosave (debounced — canvas drags burst).
    func stage(_ flow: Flow) {
        var f = flow
        f.updatedAt = Date()
        replace(f)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.store?.upsert(f)
        }
    }

    /// Save immediately (leaving the canvas, adopting a template).
    func flush(_ flow: Flow) {
        saveTask?.cancel()
        var f = flow
        f.updatedAt = Date()
        replace(f)
        store?.upsert(f)
    }

    private func replace(_ f: Flow) {
        if let i = flows.firstIndex(where: { $0.id == f.id }) { flows[i] = f }
        else { flows.insert(f, at: 0) }
    }

    @discardableResult
    func create(named name: String) -> Flow {
        let flow = Flow.empty(name: name)
        flows.insert(flow, at: 0)
        store?.upsert(flow)
        return flow
    }

    func delete(_ flow: Flow) {
        flows.removeAll { $0.id == flow.id }
        _ = store?.remove(id: flow.id)
    }

    func duplicate(_ flow: Flow) {
        var copy = flow
        copy.id = UUID().uuidString
        copy.name = flow.name + " copy"
        copy.createdAt = Date(); copy.updatedAt = Date()
        flows.insert(copy, at: 0)
        store?.upsert(copy)
    }

    // MARK: Running

    /// Start the flow on this Mac and poll its run until it finishes. Cloud
    /// keys the graph needs come straight from this Mac's Keychain.
    func run(_ flow: Flow) async {
        guard let engine else { return }
        flush(flow)
        let runId = await engine.start(flow: flow, trigger: "manual",
                                       payload: nil, keys: CloudAI.keys(for: flow))
        watch(runId: runId)
    }

    private func watch(runId: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let engine = self.engine else { return }
                if let run = await engine.runDetail(id: runId) {
                    self.activeRun = run
                    if !run.isRunning { return }
                }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    func cancelActiveRun() {
        guard let run = activeRun, run.isRunning else { return }
        Task { [weak self] in _ = await self?.engine?.cancel(id: run.id) }
    }

    /// Node states for the open flow's canvas badges.
    func nodeResult(_ nodeId: String, in flow: Flow) -> FlowNodeResult? {
        guard let run = activeRun, run.flowId == flow.id else { return nil }
        return run.results.first { $0.nodeId == nodeId }
    }

    func clearRun() {
        pollTask?.cancel()
        activeRun = nil
    }

    // MARK: History

    func runs(of flow: Flow) -> [FlowRun] {
        store?.runs(flowId: flow.id) ?? []
    }

    // MARK: Templates

    /// Prebuilt flows — one click in the empty state / templates menu. They
    /// use local AI so they work without any API key.
    static func templates() -> [Flow] {
        func node(_ type: String, _ x: Double, _ y: Double,
                  _ params: [String: String] = [:]) -> FlowNode {
            FlowNode(id: UUID().uuidString, type: type, name: nil, x: x, y: y, params: params)
        }
        func wire(_ from: FlowNode, _ to: FlowNode, port: String = "out") -> FlowEdge {
            FlowEdge(id: UUID().uuidString, from: from.id, port: port, to: to.id)
        }

        let t1: Flow = {
            let start = node("trigger.manual", 60, 140)
            let clip = node("sys.clipboard.get", 320, 120)
            let sum = node("ai.summarize", 580, 160, ["length": "short"])
            let notify = node("sys.notify", 840, 130, ["title": "Clipboard summary"])
            var f = Flow.empty(name: "Summarize my clipboard")
            f.nodes = [start, clip, sum, notify]
            f.edges = [wire(start, clip), wire(clip, sum), wire(sum, notify)]
            return f
        }()

        let t2: Flow = {
            let watch = node("trigger.watch", 40, 150, ["path": "~/Desktop"])
            let each = node("logic.loop", 300, 150)
            let vision = node("ai.vision", 560, 60, ["prompt": "Describe this image in one line."])
            let log = node("file.append", 820, 100, ["path": "~/Desktop/screenshots.log"])
            let notify = node("sys.notify", 560, 280, ["title": "Screenshots described"])
            var f = Flow.empty(name: "Describe new screenshots")
            f.nodes = [watch, each, vision, log, notify]
            f.edges = [wire(watch, each),
                       wire(each, vision, port: "each"), wire(vision, log),
                       wire(each, notify, port: "done")]
            return f
        }()

        let t3: Flow = {
            let start = node("trigger.schedule", 50, 150, ["interval": "30"])
            let get = node("web.get", 300, 120, ["url": "https://example.com"])
            let check = node("logic.if", 560, 160, ["mode": "nonempty", "value": ""])
            let ok = node("text.template", 820, 90, ["template": "Site is up ✅"])
            let alert = node("sys.notify", 820, 230, ["title": "Site is DOWN"])
            var f = Flow.empty(name: "Uptime check")
            f.nodes = [start, get, check, ok, alert]
            f.edges = [wire(start, get), wire(get, check),
                       wire(check, ok, port: "true"), wire(check, alert, port: "false")]
            return f
        }()

        let t4: Flow = {
            let start = node("trigger.manual", 60, 140)
            let info = node("sys.info", 320, 120)
            let brief = node("ai.ollama", 580, 160,
                             ["prompt": "Turn this machine report into a cheerful two-sentence morning brief:\n\n{{input}}"])
            let speak = node("sys.speak", 840, 130)
            var f = Flow.empty(name: "Morning brief, spoken")
            f.nodes = [start, info, brief, speak]
            f.edges = [wire(start, info), wire(info, brief), wire(brief, speak)]
            return f
        }()

        let t5: Flow = {
            let daily = node("trigger.daily", 50, 150, ["time": "09:30"])
            let log = node("sys.shell", 310, 120,
                           ["command": "git -C ~/Project log --since=yesterday --oneline"])
            let sum = node("ai.summarize", 580, 160, ["length": "short"])
            let notify = node("sys.notify", 840, 130, ["title": "Standup digest"])
            var f = Flow.empty(name: "Standup digest")
            f.nodes = [daily, log, sum, notify]
            f.edges = [wire(daily, log), wire(log, sum), wire(sum, notify)]
            return f
        }()

        let t6: Flow = {
            let start = node("trigger.manual", 60, 140)
            let rss = node("web.rss", 320, 120,
                           ["url": "https://hnrss.org/frontpage", "count": "5"])
            let speak = node("sys.speak", 590, 160)
            var f = Flow.empty(name: "News, spoken")
            f.nodes = [start, rss, speak]
            f.edges = [wire(start, rss), wire(rss, speak)]
            return f
        }()

        let t7: Flow = {
            let start = node("trigger.manual", 50, 150)
            let clip = node("sys.clipboard.get", 300, 120)
            let translate = node("ai.translate", 560, 160, ["language": "English"])
            let back = node("sys.clipboard.set", 820, 120)
            let notify = node("sys.notify", 1080, 160, ["title": "Translated & copied"])
            var f = Flow.empty(name: "Translate my clipboard")
            f.nodes = [start, clip, translate, back, notify]
            f.edges = [wire(start, clip), wire(clip, translate),
                       wire(translate, back), wire(back, notify)]
            return f
        }()

        return [t1, t2, t3, t4, t5, t6, t7]
    }
}
