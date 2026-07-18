//
//  FlowModel.swift
//  MacON
//
//  The Flows feature: visual automations the companion draws as blocks wired
//  together, and this Mac executes. A flow is a small DAG — nodes carry a
//  block type + string params, edges carry text from one node's output port
//  to the next node's input. These are the wire shapes (CompanionJSON:
//  snake_case keys, ISO-8601 dates; param keys stay single-word lowercase so
//  the key strategy can't mangle them), plus the on-disk store for flows and
//  their run history.
//

import Foundation

// MARK: - Flow (the graph)

nonisolated struct FlowNode: Codable, Identifiable {
    var id: String
    var type: String               // block type, e.g. "ai.ollama", "sys.shell"
    var name: String?              // user override of the block's title
    var x: Double                  // canvas position (world coords)
    var y: Double
    var params: [String: String]   // single-word lowercase keys only
    var enabled: Bool = true
}

nonisolated struct FlowEdge: Codable, Identifiable {
    var id: String
    var from: String               // source node id
    var port: String               // source port ("out", or "true"/"false" on If)
    var to: String                 // destination node id
}

nonisolated struct Flow: Codable, Identifiable {
    var id: String
    var name: String
    var nodes: [FlowNode]
    var edges: [FlowEdge]
    var createdAt: Date
    var updatedAt: Date
}

nonisolated struct FlowsListDTO: Codable { var flows: [Flow] }

// MARK: - Runs (history + live state)

nonisolated struct FlowNodeResult: Codable {
    var nodeId: String
    var status: String             // "running" | "ok" | "failed" | "skipped"
    var output: String
    var error: String?
    var ms: Int
}

nonisolated struct FlowRun: Codable, Identifiable {
    var id: String
    var flowId: String
    var flowName: String
    var trigger: String            // "manual" | "schedule" | "watch"
    var status: String             // "running" | "ok" | "failed" | "cancelled"
    var startedAt: Date
    var finishedAt: Date?
    var results: [FlowNodeResult]
}

nonisolated struct FlowRunsDTO: Codable { var runs: [FlowRun] }
nonisolated struct FlowRunStartDTO: Codable { var runId: String }

/// POST /flows/{id}/run body. The Claude key rides along from the phone's
/// Keychain (never persisted here) so cloud blocks can run on this Mac.
nonisolated struct FlowRunRequest: Codable {
    var payload: String?
    var key: String?
}

// MARK: - Store

/// Flows + capped run history as JSON in Application Support. Everything is
/// called from the engine's actor or the main actor via `await`, so a simple
/// serial pattern (load once, save on change) is enough.
nonisolated final class FlowStore: @unchecked Sendable {
    private(set) var flows: [Flow] = []
    private(set) var runs: [FlowRun] = []

    private let dir: URL
    private var flowsURL: URL { dir.appendingPathComponent("flows.json") }
    private var runsURL: URL { dir.appendingPathComponent("flow-runs.json") }
    private let queue = DispatchQueue(label: "macon.flowstore")
    private static let maxRuns = 100

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("MacON", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        flows = Self.read([Flow].self, from: flowsURL) ?? []
        runs = Self.read([FlowRun].self, from: runsURL) ?? []
    }

    func upsert(_ flow: Flow) {
        queue.sync {
            var f = flow
            if let i = flows.firstIndex(where: { $0.id == flow.id }) {
                f.createdAt = flows[i].createdAt
                flows[i] = f
            } else {
                flows.append(f)
            }
            Self.write(flows, to: flowsURL)
        }
    }

    func remove(id: String) -> Bool {
        queue.sync {
            let before = flows.count
            flows.removeAll { $0.id == id }
            runs.removeAll { $0.flowId == id }
            Self.write(flows, to: flowsURL)
            Self.write(runs, to: runsURL)
            return flows.count != before
        }
    }

    func flow(id: String) -> Flow? {
        queue.sync { flows.first { $0.id == id } }
    }

    /// Record a finished run (running state lives in the engine, not on disk).
    func record(_ run: FlowRun) {
        queue.sync {
            runs.append(run)
            if runs.count > Self.maxRuns {
                runs.removeFirst(runs.count - Self.maxRuns)
            }
            Self.write(runs, to: runsURL)
        }
    }

    /// This flow's finished runs, newest first.
    func runs(flowId: String) -> [FlowRun] {
        queue.sync { runs.filter { $0.flowId == flowId }.sorted { $0.startedAt > $1.startedAt } }
    }

    func run(id: String) -> FlowRun? {
        queue.sync { runs.first { $0.id == id } }
    }

    // MARK: Disk

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
