//
//  AgentRunner.swift
//  MacON
//
//  The dictate-to-drive loop. A device submits a task; this plans it once
//  against the accessibility snapshot (AXSnapshot), then executes steps
//  deterministically through the existing RemoteControl CGEvent path —
//  re-reading the tree before each step and re-planning only when a step's
//  target isn't there. The step feed is polled by the /agent WS route.
//
//  Everything here runs on the main actor (RemoteControl, AX and NSWorkspace
//  all want it), so run state needs no locking — network waits suspend without
//  leaving the actor.
//

import Foundation
import AppKit
import CoreGraphics
import MaconKit

@MainActor
final class AgentRunner {
    private let remote: RemoteControl
    /// Gate: a task is remote control, so it obeys the same toggle.
    private let allowControl: () -> Bool

    init(remote: RemoteControl, allowControl: @escaping () -> Bool) {
        self.remote = remote
        self.allowControl = allowControl
    }

    // MARK: Run state

    private final class Run {
        var events: [CompanionAgentEventDTO] = []
        var seq = 0
        var stopped = false
        var task: Task<Void, Never>?
        var pending: (seq: Int, cont: CheckedContinuation<Bool, Never>)?
    }
    private var runs: [String: Run] = [:]

    // MARK: Server-facing API (wired into CompanionServer.AgentOps)

    func start(_ req: CompanionAgentTaskRequestDTO) -> CompanionAgentStartResponseDTO? {
        guard allowControl() else { return nil }
        let task = req.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return nil }

        let id = String(UUID().uuidString.prefix(8))
        let run = Run()
        runs[id] = run
        let config = AgentBrainConfig(provider: req.provider ?? "anthropic",
                                      model: req.model ?? "",
                                      key: req.key)
        let supervised = (req.mode ?? "supervised") == "supervised"
        let maxSteps = min(max(req.maxSteps ?? 40, 1), 80)

        run.task = Task { [weak self] in
            await self?.drive(id: id, task: task, config: config,
                              supervised: supervised, maxSteps: maxSteps)
        }
        return CompanionAgentStartResponseDTO(agentId: id)
    }

    func eventsSince(_ id: String, after seq: Int) -> [CompanionAgentEventDTO] {
        (runs[id]?.events ?? []).filter { $0.seq > seq }
    }

    func stop(_ id: String) -> Bool {
        guard let run = runs[id] else { return false }
        run.stopped = true
        if let pending = run.pending { run.pending = nil; pending.cont.resume(returning: false) }
        run.task?.cancel()
        if !run.events.contains(where: { $0.kind == "stopped" || $0.kind == "done" || $0.kind == "error" }) {
            emit(run, kind: "stopped", text: "Stopped.")
        }
        return true
    }

    func decision(_ id: String, seq: Int, approve: Bool) -> Bool {
        guard let run = runs[id], let pending = run.pending, pending.seq == seq else { return false }
        run.pending = nil
        pending.cont.resume(returning: approve)
        return true
    }

    // MARK: The loop

    private func drive(id: String, task: String, config: AgentBrainConfig,
                       supervised: Bool, maxSteps: Int) async {
        guard let run = runs[id] else { return }

        guard remote.isTrusted else {
            emit(run, kind: "error", text: "Accessibility isn't granted on the Mac — enable it in System Settings → Privacy → Accessibility.")
            return
        }

        emit(run, kind: "plan", text: "Planning: \(task)")
        var snap = AXSnapshotter.snapshot()
        var plan: AgentPlan
        do {
            plan = try await AgentBrain.plan(task: task,
                                             snapshot: AXSnapshotter.promptText(app: snap.app, window: snap.window, nodes: snap.nodes),
                                             config: config)
        } catch {
            emit(run, kind: "error", text: error.localizedDescription); return
        }
        announce(run, plan)

        var done: [String] = []
        var stepsTaken = 0
        var replans = 0
        var index = 0

        while index < plan.steps.count {
            if run.stopped || Task.isCancelled { return }
            if stepsTaken >= maxSteps {
                emit(run, kind: "error", text: "Hit the \(maxSteps)-step limit — stopping."); return
            }
            let step = plan.steps[index]
            stepsTaken += 1

            // Re-read the tree so resolution uses what's on screen right now.
            snap = AXSnapshotter.snapshot()
            let resolved = resolve(step, in: snap.nodes)

            if step.action == "click" || step.action == "doubleclick" || step.action == "rightclick",
               resolved == nil {
                // EXCEPTION: the control we planned to click isn't here.
                guard replans < 4 else {
                    emit(run, kind: "error", text: "Couldn't find “\(step.target ?? "")” after re-planning."); return
                }
                replans += 1
                emit(run, kind: "replan", text: "“\(step.target ?? "")” isn't on screen — re-planning.")
                do {
                    plan = try await AgentBrain.replan(
                        task: task,
                        snapshot: AXSnapshotter.promptText(app: snap.app, window: snap.window, nodes: snap.nodes),
                        done: done, problem: "Control “\(step.target ?? "")” not found.", config: config)
                } catch {
                    emit(run, kind: "error", text: error.localizedDescription); return
                }
                if plan.steps.isEmpty { break }
                announce(run, plan)
                index = 0
                continue
            }

            // Supervised, or an auto run about to do something destructive →
            // wait for the tap.
            if supervised || isDestructive(step) {
                let approvalSeq = emit(run, kind: "approval", text: step.intent, step: index)
                let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    run.pending = (approvalSeq, cont)
                }
                if run.stopped { return }
                if !ok { emit(run, kind: "action", text: "Skipped: \(step.intent)", status: "skipped"); done.append(step.intent); index += 1; continue }
            }

            let outcome = perform(step, resolved: resolved)
            emit(run, kind: "action",
                 text: outcome.ok ? step.intent : "\(step.intent) — \(outcome.problem ?? "failed")",
                 status: outcome.ok ? "ok" : "fail", step: index)

            if !outcome.ok {
                guard replans < 4 else { emit(run, kind: "error", text: outcome.problem ?? "Step failed."); return }
                replans += 1
                do {
                    snap = AXSnapshotter.snapshot()
                    plan = try await AgentBrain.replan(
                        task: task,
                        snapshot: AXSnapshotter.promptText(app: snap.app, window: snap.window, nodes: snap.nodes),
                        done: done, problem: outcome.problem ?? "A step failed.", config: config)
                } catch {
                    emit(run, kind: "error", text: error.localizedDescription); return
                }
                if plan.steps.isEmpty { break }
                announce(run, plan); index = 0; continue
            }

            done.append(step.intent)
            await settle(for: step)
            index += 1
        }

        if !run.stopped {
            emit(run, kind: "done", text: "Done — \(done.count) step\(done.count == 1 ? "" : "s").")
        }
    }

    // MARK: Step resolution + execution

    /// Find the snapshot node a click step refers to. Preference: exact name,
    /// then prefix, then contains; enabled and role-matching win ties.
    private func resolve(_ step: AgentStep, in nodes: [AXNode]) -> AXNode? {
        guard let raw = step.target?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let target = raw.lowercased()
        let roleHint = step.role
        func score(_ n: AXNode) -> Int {
            let name = n.name.lowercased()
            var s = 0
            if name == target { s += 100 }
            else if name.hasPrefix(target) { s += 60 }
            else if name.contains(target) { s += 30 }
            else if target.contains(name), !name.isEmpty { s += 15 }
            else { return -1 }
            if let roleHint, n.role == roleHint { s += 10 }
            if n.enabled { s += 5 }
            return s
        }
        return nodes.map { ($0, score($0)) }.filter { $0.1 >= 0 }.max { $0.1 < $1.1 }?.0
    }

    private func perform(_ step: AgentStep, resolved: AXNode?) -> (ok: Bool, problem: String?) {
        switch step.action {
        case "launch":
            guard let app = step.app, launch(app: app) else {
                return (false, "Couldn't open “\(step.app ?? "")”.")
            }
            return (true, nil)

        case "click", "doubleclick", "rightclick":
            guard let node = resolved else { return (false, "control not found") }
            let center = CGPoint(x: node.frame.midX, y: node.frame.midY)
            guard let (nx, ny) = normalize(center) else { return (false, "off-screen") }
            var e = ControlEvent(t: "click")
            e.x = nx; e.y = ny
            e.button = step.action == "rightclick" ? "right" : "left"
            e.count = step.action == "doubleclick" ? 2 : 1
            remote.handle(e)
            return (true, nil)

        case "type":
            guard let text = step.text, !text.isEmpty else { return (false, "nothing to type") }
            var e = ControlEvent(t: "text"); e.s = text
            remote.handle(e)
            return (true, nil)

        case "key":
            guard let chord = step.keys, let (code, mods) = Self.keyChord(chord) else {
                return (false, "unknown key “\(step.keys ?? "")”")
            }
            var e = ControlEvent(t: "combo"); e.code = code; e.mods = mods
            remote.handle(e)
            return (true, nil)

        case "scroll":
            var e = ControlEvent(t: "scroll")
            e.dx = 0; e.dy = -((step.amount ?? 3) * 40)   // positive amount scrolls down
            remote.handle(e)
            return (true, nil)

        case "wait":
            return (true, nil)   // the settle handles the delay

        default:
            return (false, "unknown action “\(step.action)”")
        }
    }

    /// Give the UI time to react. Fixed per-action budgets — modest, since a
    /// re-read + resolve guards the next step anyway. (Frame-diff settle off
    /// the screen broadcaster is the future upgrade.)
    private func settle(for step: AgentStep) async {
        let ms: UInt64
        switch step.action {
        case "launch":                 ms = 1_500
        case "wait":                   ms = UInt64((step.seconds ?? 2) * 1000)
        case "click", "doubleclick",
             "rightclick":             ms = 450
        case "key":                    ms = 350
        case "type":                   ms = 150
        default:                       ms = 300
        }
        try? await Task.sleep(nanoseconds: min(ms, 8_000) * 1_000_000)
    }

    // MARK: Helpers

    private func launch(app name: String) -> Bool {
        let lower = name.lowercased()
        if let match = AppCatalog.list().apps.first(where: {
            $0.name.lowercased() == lower || $0.name.lowercased().contains(lower)
        }) {
            var e = ControlEvent(t: "launch"); e.s = match.path
            remote.handle(e)
            return true
        }
        // Fall back to NSWorkspace by name.
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            NSWorkspace.shared.openApplication(at: url, configuration: cfg); return true
        }
        return false
    }

    private func normalize(_ p: CGPoint) -> (Double, Double)? {
        let b = CGDisplayBounds(CGMainDisplayID())
        guard b.width > 0, b.height > 0 else { return nil }
        let nx = (p.x - b.minX) / b.width
        let ny = (p.y - b.minY) / b.height
        return (min(max(nx, 0), 1), min(max(ny, 0), 1))
    }

    private func isDestructive(_ step: AgentStep) -> Bool {
        let hay = ((step.target ?? "") + " " + step.intent).lowercased()
        return ["delete", "remove", "trash", "erase", "send", "discard", "uninstall", "empty "]
            .contains { hay.contains($0) }
    }

    // MARK: Event feed

    @discardableResult
    private func emit(_ run: Run, kind: String, text: String,
                      status: String? = nil, step: Int? = nil, steps: [String]? = nil) -> Int {
        run.seq += 1
        run.events.append(CompanionAgentEventDTO(seq: run.seq, kind: kind, text: text,
                                                 steps: steps, status: status, step: step))
        return run.seq
    }

    private func announce(_ run: Run, _ plan: AgentPlan) {
        emit(run, kind: "plan", text: plan.note ?? "Plan ready.",
             steps: plan.steps.map { $0.intent })
    }

    // MARK: Key chords

    /// Parse "cmd+shift+4" / "return" / "esc" → (keycode, [modifiers]).
    static func keyChord(_ chord: String) -> (Int, [String])? {
        let parts = chord.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last else { return nil }
        var mods: [String] = []
        for p in parts.dropLast() {
            switch p {
            case "cmd", "command", "⌘":  mods.append("cmd")
            case "ctrl", "control", "⌃": mods.append("ctrl")
            case "opt", "option", "alt", "⌥": mods.append("opt")
            case "shift", "⇧":           mods.append("shift")
            default: break
            }
        }
        guard let code = keyCode(keyName) else { return nil }
        return (code, mods)
    }

    private static func keyCode(_ name: String) -> Int? {
        switch name {
        case "return", "enter": return 36
        case "tab":             return 48
        case "space":           return 49
        case "esc", "escape":   return 53
        case "delete", "backspace": return 51
        case "up":              return 126
        case "down":            return 125
        case "left":            return 123
        case "right":           return 124
        default:
            guard name.count == 1, let ch = name.first else { return nil }
            return base[ch]
        }
    }

    private static let base: [Character: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "`": 50,
    ]
}
