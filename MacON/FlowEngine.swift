//
//  FlowEngine.swift
//  MacON
//
//  Executes a Flow (the companion's block graph) on this Mac. Nodes run in
//  topological order; each node's text output travels its outgoing edges to
//  become the next node's input. An If block emits on only one of its two
//  ports, so the untaken branch is skipped. Everything a block touches —
//  models, files, the shell, the clipboard — stays on this machine.
//
//  Live runs are kept in the actor (the companion polls them for the canvas
//  glow); finished runs land in the FlowStore's capped history.
//

import Foundation
import AppKit
import PDFKit

actor FlowEngine {
    private let store: FlowStore
    private let ollama = OllamaService()

    /// Runs in flight, by run id — the poll route reads these until finished.
    private var live: [String: FlowRun] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Cloud keys (by provider) from the most recent device-started run,
    /// kept in memory only, so scheduled runs of cloud blocks keep working
    /// between launches of the companion. Never written to disk.
    private var rememberedKeys: [String: String] = [:]

    init(store: FlowStore) {
        self.store = store
    }

    // MARK: Starting / polling / cancelling

    /// Kick off a run and return its id immediately; execution continues in
    /// the background and is polled via `runDetail`.
    func start(flow: Flow, trigger: String, payload: String?,
               keys: [String: String] = [:]) -> String {
        for (provider, key) in keys where !key.isEmpty {
            rememberedKeys[provider] = key
        }
        let runId = UUID().uuidString
        let run = FlowRun(id: runId, flowId: flow.id, flowName: flow.name,
                          trigger: trigger, status: "running",
                          startedAt: Date(), finishedAt: nil, results: [])
        live[runId] = run
        tasks[runId] = Task { [weak self] in
            await self?.execute(flow: flow, runId: runId, trigger: trigger, payload: payload)
        }
        return runId
    }

    func runDetail(id: String) -> FlowRun? {
        live[id] ?? store.run(id: id)
    }

    func cancel(id: String) -> Bool {
        guard let task = tasks[id] else { return false }
        task.cancel()
        return true
    }

    // MARK: Execution

    private func execute(flow: Flow, runId: String, trigger: String, payload: String?) async {
        let nodes = flow.nodes.filter(\.enabled)
        let ids = Set(nodes.map(\.id))
        let edges = flow.edges.filter { ids.contains($0.from) && ids.contains($0.to) }

        // Kahn's — a cycle leaves nodes unordered; they're reported as failed.
        var indegree: [String: Int] = nodes.reduce(into: [:]) { $0[$1.id] = 0 }
        for edge in edges { indegree[edge.to, default: 0] += 1 }
        var queue = nodes.filter { indegree[$0.id] == 0 }.map(\.id)
        var order: [String] = []
        var remaining = indegree
        while let id = queue.first {
            queue.removeFirst()
            order.append(id)
            for edge in edges where edge.from == id {
                remaining[edge.to]! -= 1
                if remaining[edge.to] == 0 { queue.append(edge.to) }
            }
        }

        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var outputs: [String: [String: String]] = [:]     // node → port → text
        var finished: Set<String> = []
        var anyFailed = false
        var cancelled = false

        // Loop bodies: everything downstream of a loop's "each" port runs
        // inside that loop's iterations, not in the main pass.
        var bodyOf: [String: String] = [:]                // node → its loop
        for loop in nodes where loop.type == "logic.loop" || loop.type == "logic.repeat" {
            var frontier = edges.filter { $0.from == loop.id && $0.port == "each" }.map(\.to)
            while let id = frontier.popLast() {
                guard id != loop.id, bodyOf[id] == nil else { continue }
                bodyOf[id] = loop.id
                frontier += edges.filter { $0.from == id }.map(\.to)
            }
        }

        for id in order {
            guard let node = byId[id] else { continue }
            if bodyOf[id] != nil { continue }             // runs inside its loop
            if Task.isCancelled { cancelled = true; break }

            // Inputs: everything delivered on edges into this node. A source
            // that failed/was skipped (or an If's untaken port) delivers
            // nothing; a fed node whose deliveries all dried up is skipped.
            let incoming = edges.filter { $0.to == id }
            let delivered = incoming.compactMap { outputs[$0.from]?[$0.port] }
            if !incoming.isEmpty && delivered.isEmpty {
                setResult(runId, FlowNodeResult(nodeId: id, status: "skipped",
                                                output: "", error: nil, ms: 0))
                finished.insert(id)
                continue
            }
            let input = incoming.isEmpty ? (payload ?? "") : delivered.joined(separator: "\n\n")

            setResult(runId, FlowNodeResult(nodeId: id, status: "running",
                                            output: "", error: nil, ms: 0))
            let began = Date()
            do {
                let out: [String: String]
                if node.type == "logic.loop" || node.type == "logic.repeat" {
                    out = try await runLoop(node, input: input, runId: runId,
                                            order: order, edges: edges, byId: byId,
                                            bodyOf: bodyOf, outputs: outputs,
                                            payload: payload, trigger: trigger,
                                            finished: &finished)
                } else {
                    out = try await run(node: node, input: input,
                                        payload: payload, trigger: trigger)
                }
                outputs[id] = out
                let shown = out["out"] ?? out.values.first ?? ""
                setResult(runId, FlowNodeResult(
                    nodeId: id, status: "ok", output: Self.clip(shown), error: nil,
                    ms: Int(Date().timeIntervalSince(began) * 1000)))
            } catch is CancellationError {
                cancelled = true
                setResult(runId, FlowNodeResult(nodeId: id, status: "skipped",
                                                output: "", error: "Cancelled", ms: 0))
                break
            } catch {
                anyFailed = true
                setResult(runId, FlowNodeResult(
                    nodeId: id, status: "failed", output: "",
                    error: Self.clip(error.localizedDescription),
                    ms: Int(Date().timeIntervalSince(began) * 1000)))
            }
            finished.insert(id)
        }

        // Anything never reached (cycle, cancelled early) reports as skipped.
        for node in nodes where !finished.contains(node.id)
            && live[runId]?.results.contains(where: { $0.nodeId == node.id }) != true {
            setResult(runId, FlowNodeResult(nodeId: node.id, status: "skipped",
                                            output: "", error: nil, ms: 0))
        }

        if var run = live[runId] {
            run.status = cancelled ? "cancelled" : anyFailed ? "failed" : "ok"
            run.finishedAt = Date()
            live[runId] = nil
            tasks[runId] = nil
            store.record(run)
        }
    }

    private func setResult(_ runId: String, _ result: FlowNodeResult) {
        guard var run = live[runId] else { return }
        if let i = run.results.firstIndex(where: { $0.nodeId == result.nodeId }) {
            run.results[i] = result
        } else {
            run.results.append(result)
        }
        live[runId] = run
    }

    private static func clip(_ s: String, max: Int = 16_000) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "\n… (truncated)"
    }

    // MARK: Loops

    /// Run a For Each / Repeat block: everything hanging off its "each" port
    /// executes once per item, and the body's leaf outputs — one per
    /// iteration — come back joined on the "done" port. Iterations run the
    /// body in topological order with the loop item delivered where the
    /// "each" strings point.
    private func runLoop(_ node: FlowNode, input: String, runId: String,
                         order: [String], edges: [FlowEdge], byId: [String: FlowNode],
                         bodyOf: [String: String], outputs: [String: [String: String]],
                         payload: String?, trigger: String,
                         finished: inout Set<String>) async throws -> [String: String] {
        let bodyOrder = order.filter { bodyOf[$0] == node.id }
        guard !bodyOrder.isEmpty else {
            throw Fail("Nothing on the \"each\" branch — wire a block to the top port.")
        }
        if bodyOrder.contains(where: {
            byId[$0]?.type == "logic.loop" || byId[$0]?.type == "logic.repeat"
        }) {
            throw Fail("Loops can't nest (yet).")
        }

        let maxItems = 100
        var items: [String]
        if node.type == "logic.repeat" {
            let n = min(max(Int(node.params["times"] ?? "") ?? 3, 1), maxItems)
            items = Array(repeating: input, count: n)
        } else {
            items = input.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        var dropped = 0
        if items.count > maxItems {
            dropped = items.count - maxItems
            items = Array(items.prefix(maxItems))
        }

        // A body leaf feeds nothing else inside the body — its output is what
        // each iteration contributes.
        let leaves = bodyOrder.filter { bid in
            !edges.contains { $0.from == bid && bodyOf[$0.to] == node.id }
        }

        var collected: [String] = []
        for (index, item) in items.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            var local: [String: [String: String]] = [:]
            for bid in bodyOrder {
                guard let bnode = byId[bid] else { continue }
                let incoming = edges.filter { $0.to == bid }
                var delivered: [String] = []
                for edge in incoming {
                    if edge.from == node.id && edge.port == "each" {
                        delivered.append(item)
                    } else if bodyOf[edge.from] == node.id {
                        if let v = local[edge.from]?[edge.port] { delivered.append(v) }
                    } else if let v = outputs[edge.from]?[edge.port] {
                        delivered.append(v)
                    }
                }
                if !incoming.isEmpty && delivered.isEmpty { continue }   // untaken branch
                let binput = delivered.joined(separator: "\n\n")

                setResult(runId, FlowNodeResult(
                    nodeId: bid, status: "running",
                    output: "item \(index + 1)/\(items.count)", error: nil, ms: 0))
                let began = Date()
                do {
                    let out = try await run(node: bnode, input: binput,
                                            payload: payload, trigger: trigger)
                    local[bid] = out
                    let shown = out["out"] ?? out.values.first ?? ""
                    setResult(runId, FlowNodeResult(
                        nodeId: bid, status: "ok",
                        output: Self.clip("item \(index + 1)/\(items.count)\n" + shown),
                        error: nil, ms: Int(Date().timeIntervalSince(began) * 1000)))
                } catch {
                    setResult(runId, FlowNodeResult(
                        nodeId: bid, status: "failed", output: "",
                        error: Self.clip(error.localizedDescription),
                        ms: Int(Date().timeIntervalSince(began) * 1000)))
                    throw Fail("Item \(index + 1) failed at \"\(bnode.type)\": \(error.localizedDescription)")
                }
            }
            let contribution = leaves.compactMap {
                local[$0]?["out"] ?? local[$0]?.values.first
            }.joined(separator: "\n")
            if !contribution.isEmpty { collected.append(contribution) }
        }
        finished.formUnion(bodyOrder)

        var done = collected.joined(separator: "\n")
        if dropped > 0 { done += "\n… (\(dropped) more items skipped — 100 max)" }
        return ["done": done]
    }

    // MARK: One node

    /// Run one block; the returned dictionary maps output ports to text
    /// (every block emits on "out" except If, which picks "true"/"false").
    private func run(node: FlowNode, input: String,
                     payload: String?, trigger: String) async throws -> [String: String] {
        let p = node.params
        func param(_ key: String, _ fallback: String = "") -> String {
            (p[key]?.isEmpty == false) ? p[key]! : fallback
        }
        /// {{input}} interpolation for prompt/command/url templates.
        func fill(_ template: String) -> String {
            template.replacingOccurrences(of: "{{input}}", with: input)
        }

        switch node.type {

        // MARK: Triggers (sources — they emit what started the run)
        case "trigger.manual":
            return ["out": payload?.isEmpty == false ? payload! : param("payload", "run")]
        case "trigger.schedule", "trigger.watch", "trigger.daily":
            return ["out": payload?.isEmpty == false ? payload!
                : ISO8601DateFormatter().string(from: Date())]

        // MARK: AI
        case "ai.ollama":
            return ["out": try await ollamaChat(
                model: param("model"), system: param("system"),
                prompt: fill(param("prompt", "{{input}}")))]
        case "ai.claude":
            return ["out": try await claudeChat(
                model: param("model", "claude-sonnet-5"), system: param("system"),
                prompt: fill(param("prompt", "{{input}}")))]
        case "ai.openai":
            return ["out": try await openaiChat(
                model: param("model", "gpt-5.1"), system: param("system"),
                prompt: fill(param("prompt", "{{input}}")))]
        case "ai.gemini":
            return ["out": try await geminiChat(
                model: param("model", "gemini-2.5-flash"), system: param("system"),
                prompt: fill(param("prompt", "{{input}}")))]
        case "ai.devops":
            return ["out": try await devopsChat(
                model: param("model", "claude-haiku"), system: param("system"),
                prompt: fill(param("prompt", "{{input}}")))]
        case "ai.summarize":
            let length = param("length", "short")
            return ["out": try await ollamaChat(
                model: param("model"),
                system: "You summarize text. Reply with only the summary, no preamble.",
                prompt: "Give a \(length) summary of the following:\n\n\(input)")]
        case "ai.translate":
            return ["out": try await ollamaChat(
                model: param("model"),
                system: "You translate text. Reply with only the translation.",
                prompt: "Translate the following into \(param("language", "English")):\n\n\(input)")]
        case "ai.classify":
            let labels = param("labels", "positive, negative, neutral")
            return ["out": try await ollamaChat(
                model: param("model"),
                system: "You are a classifier. Reply with exactly one label from the list, nothing else.",
                prompt: "Labels: \(labels)\n\nClassify this:\n\n\(input)")]
        case "ai.extract":
            let fields = param("fields", "title, date, summary")
            return ["out": try await ollamaChat(
                model: param("model"),
                system: "You extract structured data. Reply with only a JSON object, no code fences.",
                prompt: "Extract these fields as JSON: \(fields)\n\nFrom:\n\n\(input)")]
        case "ai.rewrite":
            let styles = [
                "formal": "more formal and professional",
                "casual": "more casual and friendly",
                "shorter": "significantly shorter, keeping every key point",
                "longer": "more detailed and fleshed out",
                "bullets": "a clean bulleted list",
            ]
            let style = styles[param("style", "shorter")] ?? styles["shorter"]!
            return ["out": try await ollamaChat(
                model: param("model"),
                system: "You rewrite text. Reply with only the rewritten text.",
                prompt: "Rewrite this as \(style):\n\n\(input)")]
        case "ai.vision":
            // Input is an image path (e.g. from Screenshot or Watch Folder).
            let path = Self.expand(input.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first ?? "")
            guard let data = FileManager.default.contents(atPath: path) else {
                throw Fail("No image at \(path.isEmpty ? "(empty input)" : path)")
            }
            return ["out": try await ollamaChat(
                model: param("model"), system: "",
                prompt: param("prompt", "Describe this image."),
                images: [data.base64EncodedString()])]

        // MARK: Text
        case "text.template":
            return ["out": fill(param("template", "{{input}}"))]
        case "text.replace":
            return ["out": input.replacingOccurrences(of: param("find"), with: param("replace"))]
        case "text.regex":
            let regex = try NSRegularExpression(pattern: param("pattern"))
            let range = NSRange(input.startIndex..., in: input)
            let matches = regex.matches(in: input, range: range).compactMap { m -> String? in
                let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
                return Range(r, in: input).map { String(input[$0]) }
            }
            return ["out": matches.joined(separator: "\n")]
        case "text.case":
            switch param("mode", "upper") {
            case "lower": return ["out": input.lowercased()]
            case "title": return ["out": input.capitalized]
            default:      return ["out": input.uppercased()]
            }
        case "text.join":
            let sep = param("separator", ", ")
            return ["out": input.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }.joined(separator: sep)]
        case "text.trim":
            return ["out": input.trimmingCharacters(in: .whitespacesAndNewlines)]
        case "text.stats":
            let words = input.split { $0.isWhitespace || $0.isNewline }.count
            let lines = input.components(separatedBy: .newlines).count
            return ["out": "\(input.count) characters, \(words) words, \(lines) lines"]
        case "text.sort":
            let lines = input.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let sorted = lines.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            return ["out": (param("order", "az") == "za" ? sorted.reversed() : sorted)
                .joined(separator: "\n")]
        case "text.unique":
            var seen = Set<String>()
            return ["out": input.components(separatedBy: .newlines)
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .joined(separator: "\n")]
        case "text.first":
            let n = max(Int(param("count", "5")) ?? 5, 1)
            return ["out": input.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }.prefix(n).joined(separator: "\n")]
        case "text.base64":
            if param("mode", "encode") == "decode" {
                guard let data = Data(base64Encoded: input
                    .trimmingCharacters(in: .whitespacesAndNewlines)),
                      let text = String(data: data, encoding: .utf8) else {
                    throw Fail("Input isn't valid base64 text")
                }
                return ["out": text]
            }
            return ["out": Data(input.utf8).base64EncodedString()]
        case "text.date":
            let now = Date()
            switch param("format", "datetime") {
            case "iso":  return ["out": ISO8601DateFormatter().string(from: now)]
            case "date": return ["out": now.formatted(date: .abbreviated, time: .omitted)]
            case "time": return ["out": now.formatted(date: .omitted, time: .shortened)]
            case "unix": return ["out": String(Int(now.timeIntervalSince1970))]
            default:     return ["out": now.formatted(date: .abbreviated, time: .shortened)]
            }

        // MARK: Files
        case "file.read":
            let path = Self.expand(param("path", input))
            if path.lowercased().hasSuffix(".pdf") {
                guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
                      let text = doc.string else { throw Fail("Couldn't read PDF at \(path)") }
                return ["out": text]
            }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw Fail("Couldn't read \(path)")
            }
            return ["out": text]
        case "file.write", "file.append":
            let path = Self.expand(param("path"))
            guard !path.isEmpty else { throw Fail("No file path set") }
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if node.type == "file.append", let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((input + "\n").utf8))
            } else if node.type == "file.append", !FileManager.default.fileExists(atPath: path) {
                try (input + "\n").write(to: url, atomically: true, encoding: .utf8)
            } else {
                try input.write(to: url, atomically: true, encoding: .utf8)
            }
            return ["out": path]
        case "file.list":
            let path = Self.expand(param("path", "~"))
            let names = try FileManager.default.contentsOfDirectory(atPath: path)
                .filter { !$0.hasPrefix(".") }.sorted()
            return ["out": names.joined(separator: "\n")]
        case "file.move", "file.copy":
            let source = Self.expand(param("from", input)
                .components(separatedBy: .newlines).first ?? "")
            var dest = Self.expand(param("to"))
            guard !source.isEmpty, !dest.isEmpty else { throw Fail("Set a destination path") }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dest, isDirectory: &isDir), isDir.boolValue {
                dest = (dest as NSString).appendingPathComponent((source as NSString).lastPathComponent)
            }
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dest).deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if node.type == "file.move" {
                try FileManager.default.moveItem(atPath: source, toPath: dest)
            } else {
                try FileManager.default.copyItem(atPath: source, toPath: dest)
            }
            return ["out": dest]
        case "file.trash":
            let path = Self.expand(param("path", input)
                .components(separatedBy: .newlines).first ?? "")
            guard !path.isEmpty else { throw Fail("Nothing to trash") }
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path),
                                              resultingItemURL: nil)
            return ["out": path]

        // MARK: System
        case "sys.shell":
            let command = fill(param("command"))
            guard !command.isEmpty else { throw Fail("No command set") }
            let timeout = TimeInterval(param("timeout", "120")) ?? 120
            return ["out": try await Self.process("/bin/zsh", ["-lc", command], timeout: timeout)]
        case "sys.applescript":
            let script = fill(param("script"))
            guard !script.isEmpty else { throw Fail("No script set") }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("macon-flow-\(UUID().uuidString).scpt")
            try script.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            return ["out": try await Self.process("/usr/bin/osascript", [file.path], timeout: 120)]
        case "sys.clipboard.get":
            let text = await MainActor.run { NSPasteboard.general.string(forType: .string) }
            return ["out": text ?? ""]
        case "sys.clipboard.set":
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(input, forType: .string)
            }
            return ["out": input]
        case "sys.notify":
            let title = Self.appleScriptQuote(param("title", "MacON Flow"))
            let body = Self.appleScriptQuote(String(input.prefix(200)))
            _ = try await Self.process("/usr/bin/osascript",
                ["-e", "display notification \"\(body)\" with title \"\(title)\""], timeout: 10)
            return ["out": input]
        case "sys.speak":
            var args: [String] = []
            let voice = param("voice")
            if !voice.isEmpty { args += ["-v", voice] }
            _ = try await Self.process("/usr/bin/say", args + [String(input.prefix(500))], timeout: 120)
            return ["out": input]
        case "sys.open":
            let target = fill(param("target", input)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { throw Fail("Nothing to open") }
            let args = target.contains("://") || target.hasPrefix("/") || target.hasPrefix("~")
                ? [Self.expand(target)] : ["-a", target]
            _ = try await Self.process("/usr/bin/open", args, timeout: 15)
            return ["out": target]
        case "sys.screenshot":
            let path = Self.expand(param("path",
                "~/Desktop/macon-flow-\(Int(Date().timeIntervalSince1970)).png"))
            _ = try await Self.process("/usr/sbin/screencapture", ["-x", path], timeout: 15)
            return ["out": path]
        case "sys.volume":
            let level = min(max(Int(param("level", "50")) ?? 50, 0), 100)
            _ = try await Self.process("/usr/bin/osascript",
                ["-e", "set volume output volume \(level)"], timeout: 10)
            return ["out": "Volume set to \(level)%"]
        case "sys.sleepdisplay":
            _ = try await Self.process("/usr/bin/pmset", ["displaysleepnow"], timeout: 10)
            return ["out": "Display slept"]
        case "sys.info":
            let battery = (try? await Self.process("/usr/bin/pmset", ["-g", "batt"], timeout: 5)) ?? ""
            let uptime = (try? await Self.process("/usr/bin/uptime", [], timeout: 5)) ?? ""
            let disk = (try? await Self.process("/bin/df", ["-h", "/"], timeout: 5)) ?? ""
            return ["out": """
                Host: \(ProcessInfo.processInfo.hostName)
                \(uptime.trimmingCharacters(in: .whitespacesAndNewlines))
                \(battery.trimmingCharacters(in: .whitespacesAndNewlines))
                \(disk.trimmingCharacters(in: .whitespacesAndNewlines))
                """]

        // MARK: Apps
        case "app.launch":
            let app = param("app", input).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !app.isEmpty else { throw Fail("Which app?") }
            _ = try await Self.process("/usr/bin/open", ["-a", app], timeout: 15)
            return ["out": "Launched \(app)"]
        case "app.quit":
            let app = param("app").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !app.isEmpty else { throw Fail("Which app?") }
            _ = try await Self.process("/usr/bin/osascript",
                ["-e", "tell application \"\(Self.appleScriptQuote(app))\" to quit"], timeout: 15)
            return ["out": "Quit \(app)"]
        case "app.front":
            let name = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.localizedName
            }
            return ["out": name ?? "Unknown"]
        case "app.music":
            let action = param("action", "playpause")
            let verb: String
            switch action {
            case "play":     verb = "play"
            case "pause":    verb = "pause"
            case "next":     verb = "next track"
            case "previous": verb = "previous track"
            default:         verb = "playpause"
            }
            _ = try await Self.process("/usr/bin/osascript",
                ["-e", "tell application \"Music\" to \(verb)"], timeout: 15)
            let track = (try? await Self.process("/usr/bin/osascript",
                ["-e", "tell application \"Music\" to get name of current track & \" — \" & artist of current track"],
                timeout: 10)) ?? ""
            return ["out": track.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? "Music: \(action)" : track.trimmingCharacters(in: .whitespacesAndNewlines)]
        case "app.safari":
            let out = try await Self.process("/usr/bin/osascript", ["-e", """
                tell application "Safari" to get name of front document & linefeed & URL of front document
                """], timeout: 10)
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Fail("Safari has no open page") }
            return ["out": trimmed]
        case "app.finder":
            let script = """
                tell application "Finder"
                    set out to ""
                    repeat with f in (get selection)
                        set out to out & POSIX path of (f as alias) & linefeed
                    end repeat
                    out
                end tell
                """
            let out = try await Self.process("/usr/bin/osascript", ["-e", script], timeout: 10)
            return ["out": out.trimmingCharacters(in: .whitespacesAndNewlines)]
        case "app.shortcut":
            let name = param("name")
            guard !name.isEmpty else { throw Fail("Name the Shortcut to run") }
            let dir = FileManager.default.temporaryDirectory
            let inFile = dir.appendingPathComponent("macon-flow-in-\(UUID().uuidString).txt")
            let outFile = dir.appendingPathComponent("macon-flow-out-\(UUID().uuidString).txt")
            try input.write(to: inFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: inFile)
                    try? FileManager.default.removeItem(at: outFile) }
            _ = try await Self.process("/usr/bin/shortcuts",
                ["run", name, "-i", inFile.path, "-o", outFile.path], timeout: 300)
            let result = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
            return ["out": result.isEmpty ? "Ran \"\(name)\"" : result]

        // MARK: Web
        case "web.get":
            let url = try Self.url(fill(param("url", input)))
            let (data, resp) = try await URLSession.shared.data(from: url)
            try Self.checkHTTP(resp)
            return ["out": String(data: data, encoding: .utf8) ?? "(\(data.count) bytes, not text)"]
        case "web.post":
            let url = try Self.url(fill(param("url")))
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            let isJSON = param("format", "json") == "json"
            req.setValue(isJSON ? "application/json" : "text/plain",
                         forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(fill(param("body", "{{input}}")).utf8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try Self.checkHTTP(resp)
            return ["out": String(data: data, encoding: .utf8) ?? "(\(data.count) bytes, not text)"]
        case "web.rss":
            let url = try Self.url(fill(param("url", input)))
            let (data, resp) = try await URLSession.shared.data(from: url)
            try Self.checkHTTP(resp)
            let xml = String(data: data, encoding: .utf8) ?? ""
            // Titles the cheap way: enough for every mainstream feed, no
            // XML dependency. First <title> is the feed's own name.
            let regex = try NSRegularExpression(
                pattern: "<title[^>]*>(?:<!\\[CDATA\\[)?(.*?)(?:\\]\\]>)?</title>",
                options: [.dotMatchesLineSeparators])
            let range = NSRange(xml.startIndex..., in: xml)
            var titles = regex.matches(in: xml, range: range).compactMap { m -> String? in
                Range(m.range(at: 1), in: xml).map {
                    String(xml[$0]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if titles.count > 1 { titles.removeFirst() }
            let count = max(Int(param("count", "10")) ?? 10, 1)
            guard !titles.isEmpty else { throw Fail("No headlines found — is that an RSS feed?") }
            return ["out": titles.prefix(count).joined(separator: "\n")]
        case "web.json":
            guard let data = input.data(using: .utf8),
                  var current = try? JSONSerialization.jsonObject(with: data) else {
                throw Fail("Input isn't JSON")
            }
            for seg in param("path").split(separator: ".").map(String.init) where !seg.isEmpty {
                if let dict = current as? [String: Any], let next = dict[seg] {
                    current = next
                } else if let arr = current as? [Any], let i = Int(seg), arr.indices.contains(i) {
                    current = arr[i]
                } else {
                    throw Fail("Nothing at \"\(seg)\" in the JSON")
                }
            }
            if let s = current as? String { return ["out": s] }
            if let n = current as? NSNumber { return ["out": n.stringValue] }
            let out = try JSONSerialization.data(withJSONObject: current,
                                                 options: [.prettyPrinted, .fragmentsAllowed])
            return ["out": String(data: out, encoding: .utf8) ?? ""]
        case "web.download":
            let url = try Self.url(fill(param("url", input)))
            let path = Self.expand(param("path", "~/Downloads/\(url.lastPathComponent)"))
            let (data, resp) = try await URLSession.shared.data(from: url)
            try Self.checkHTTP(resp)
            try data.write(to: URL(fileURLWithPath: path))
            return ["out": path]

        // MARK: Logic
        case "logic.if":
            let value = param("value")
            let hit: Bool
            switch param("mode", "contains") {
            case "equals":   hit = input.trimmingCharacters(in: .whitespacesAndNewlines) == value
            case "matches":  hit = (try? NSRegularExpression(pattern: value).firstMatch(
                in: input, range: NSRange(input.startIndex..., in: input))) != nil
            case "nonempty": hit = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:         hit = input.localizedCaseInsensitiveContains(value)
            }
            return [hit ? "true" : "false": input]
        case "logic.filter":
            let value = param("value")
            let matcher: (String) -> Bool
            if param("mode", "contains") == "matches", let re = try? NSRegularExpression(pattern: value) {
                matcher = { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            } else {
                matcher = { $0.localizedCaseInsensitiveContains(value) }
            }
            return ["out": input.components(separatedBy: .newlines)
                .filter(matcher).joined(separator: "\n")]
        case "logic.delay":
            let seconds = min(max(Double(param("seconds", "2")) ?? 2, 0), 3600)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return ["out": input]
        case "logic.merge":
            return ["out": input]   // inputs already arrive joined; this makes the join explicit

        default:
            throw Fail("Unknown block type \"\(node.type)\" — update MacON on this Mac.")
        }
    }

    // MARK: AI providers

    private func ollamaChat(model: String, system: String, prompt: String,
                            images: [String]? = nil) async throws -> String {
        guard !model.isEmpty else { throw Fail("No model picked for this block") }
        guard await ollama.ensureRunning() else {
            throw Fail("Couldn't reach Ollama on this Mac — is it installed?")
        }
        struct Msg: Encodable { let role: String; let content: String; let images: [String]? }
        struct Req: Encodable { let model: String; let messages: [Msg]; let stream: Bool }
        struct Resp: Decodable {
            struct M: Decodable { let content: String }
            let message: M?
            let error: String?
        }
        var messages: [Msg] = []
        if !system.isEmpty { messages.append(Msg(role: "system", content: system, images: nil)) }
        messages.append(Msg(role: "user", content: prompt, images: images))

        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(model: model, messages: messages, stream: false))
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        if let error = resp.error { throw Fail("Ollama: \(error)") }
        return resp.message?.content ?? ""
    }

    /// A provider's key from the last device-started run, or a clear error.
    private func cloudKey(_ provider: String, label: String) throws -> String {
        guard let key = rememberedKeys[provider], !key.isEmpty else {
            throw Fail("No \(label) API key on this Mac yet — add one in the block's "
                       + "settings on the companion, then run the flow once from there.")
        }
        return key
    }

    private func claudeChat(model: String, system: String, prompt: String) async throws -> String {
        let key = try cloudKey("anthropic", label: "Claude")
        struct Msg: Encodable { let role: String; let content: String }
        struct Req: Encodable {
            let model: String; let maxTokens: Int
            let system: String; let messages: [Msg]
        }
        struct Resp: Decodable {
            struct Block: Decodable { let text: String? }
            struct Err: Decodable { let message: String? }
            let content: [Block]?
            let error: Err?
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try encoder.encode(Req(model: model, maxTokens: 4096,
                                              system: system, messages: [Msg(role: "user", content: prompt)]))
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        if let message = resp.error?.message { throw Fail("Claude: \(message)") }
        return resp.content?.compactMap(\.text).joined() ?? ""
    }

    private func openaiChat(model: String, system: String, prompt: String) async throws -> String {
        try await openAICompatChat(base: "https://api.openai.com/v1/chat/completions",
                                   provider: "openai", label: "OpenAI",
                                   model: model, system: system, prompt: prompt)
    }

    /// DevOps Institute learner gateway — OpenAI-compatible at a custom base URL.
    private func devopsChat(model: String, system: String, prompt: String) async throws -> String {
        try await openAICompatChat(base: CloudAI.devopsBase,
                                   provider: "devops", label: "DevOps Institute",
                                   model: model, system: system, prompt: prompt)
    }

    /// Shared OpenAI-style chat call — OpenAI itself and any compatible gateway.
    private func openAICompatChat(base: String, provider: String, label: String,
                                  model: String, system: String, prompt: String) async throws -> String {
        let key = try cloudKey(provider, label: label)
        struct Msg: Codable { let role: String; let content: String }
        struct Req: Encodable { let model: String; let messages: [Msg] }
        struct Resp: Decodable {
            struct Choice: Decodable { let message: Msg? }
            struct Err: Decodable { let message: String? }
            let choices: [Choice]?
            let error: Err?
        }
        var req = URLRequest(url: URL(string: base)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var messages: [Msg] = []
        if !system.isEmpty { messages.append(Msg(role: "system", content: system)) }
        messages.append(Msg(role: "user", content: prompt))
        req.httpBody = try JSONEncoder().encode(Req(model: model, messages: messages))
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        if let message = resp.error?.message { throw Fail("\(label): \(message)") }
        return resp.choices?.first?.message?.content ?? ""
    }

    private func geminiChat(model: String, system: String, prompt: String) async throws -> String {
        let key = try cloudKey("gemini", label: "Gemini")
        struct Part: Codable { let text: String }
        struct Content: Codable { var role: String?; let parts: [Part] }
        struct Req: Encodable {
            let contents: [Content]
            let systemInstruction: Content?
        }
        struct Resp: Decodable {
            struct Candidate: Decodable { let content: Content? }
            struct Err: Decodable { let message: String? }
            let candidates: [Candidate]?
            let error: Err?
        }
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)")
        else { throw Fail("Bad Gemini model name") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(
            contents: [Content(role: "user", parts: [Part(text: prompt)])],
            systemInstruction: system.isEmpty ? nil : Content(role: nil, parts: [Part(text: system)])))
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        if let message = resp.error?.message { throw Fail("Gemini: \(message)") }
        return resp.candidates?.first?.content?.parts.map(\.text).joined() ?? ""
    }

    // MARK: Helpers

    struct Fail: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func url(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard !trimmed.isEmpty, let url = URL(string: candidate) else {
            throw Fail("Bad URL: \(raw)")
        }
        return url
    }

    private static func checkHTTP(_ resp: URLResponse) throws {
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Fail("HTTP \(http.statusCode)")
        }
    }

    private static func appleScriptQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Run a process, capture stdout+stderr, kill it past `timeout`.
    private static func process(_ path: String, _ args: [String],
                                timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do { try proc.run() } catch {
                    cont.resume(throwing: Fail("Couldn't launch \(path): \(error.localizedDescription)"))
                    return
                }
                let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                killer.cancel()
                let out = String(data: data, encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 && out.isEmpty {
                    cont.resume(throwing: Fail("\((path as NSString).lastPathComponent) exited \(proc.terminationStatus)"))
                } else {
                    cont.resume(returning: out)
                }
            }
        }
    }
}

// MARK: - Scheduler

/// Fires flows whose triggers are time- or folder-based. Ticks every 30s
/// while the companion server runs; each tick re-checks the gate so flipping
/// the Flows toggle takes effect immediately.
@MainActor
final class FlowScheduler {
    private var timer: Timer?
    private var lastFire: [String: Date] = [:]           // schedule node id → last run
    private var snapshots: [String: Set<String>] = [:]   // watch node id → dir listing

    func start(store: FlowStore, engine: FlowEngine, gate: @escaping () -> Bool) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(store: store, engine: engine, gate: gate) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick(store: FlowStore, engine: FlowEngine, gate: () -> Bool) {
        guard gate() else { return }
        for flow in store.flows {
            for node in flow.nodes where node.enabled {
                switch node.type {
                case "trigger.schedule":
                    let minutes = max(1, Int(node.params["interval"] ?? "") ?? 60)
                    let last = lastFire[node.id] ?? .distantPast
                    // First sighting arms the timer instead of firing at once.
                    if last == .distantPast {
                        lastFire[node.id] = Date()
                    } else if Date().timeIntervalSince(last) >= Double(minutes) * 60 {
                        lastFire[node.id] = Date()
                        Task { _ = await engine.start(flow: flow, trigger: "schedule",
                                                      payload: nil) }
                    }
                case "trigger.daily":
                    // Fires once when the clock passes HH:mm. First sighting
                    // arms it: a time already past today waits for tomorrow.
                    let parts = (node.params["time"] ?? "09:00").split(separator: ":")
                    let hour = Int(parts.first ?? "9") ?? 9
                    let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
                    guard let target = Calendar.current.date(
                        bySettingHour: min(max(hour, 0), 23),
                        minute: min(max(minute, 0), 59),
                        second: 0, of: Date()) else { continue }
                    let last = lastFire[node.id] ?? .distantPast
                    if last == .distantPast {
                        lastFire[node.id] = Date()
                    } else if Date() >= target && last < target {
                        lastFire[node.id] = Date()
                        Task { _ = await engine.start(flow: flow, trigger: "schedule",
                                                      payload: nil) }
                    }
                case "trigger.watch":
                    let path = ((node.params["path"] ?? "") as NSString).expandingTildeInPath
                    guard !path.isEmpty,
                          let names = try? FileManager.default.contentsOfDirectory(atPath: path)
                    else { continue }
                    let now = Set(names.filter { !$0.hasPrefix(".") })
                    if let before = snapshots[node.id] {
                        let added = now.subtracting(before)
                        if !added.isEmpty {
                            let payload = added.sorted().map { path + "/" + $0 }
                                .joined(separator: "\n")
                            Task { _ = await engine.start(flow: flow, trigger: "watch",
                                                          payload: payload) }
                        }
                    }
                    snapshots[node.id] = now
                default:
                    break
                }
            }
        }
    }
}
