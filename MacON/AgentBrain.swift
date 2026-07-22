//
//  AgentBrain.swift
//  MacON
//
//  The agent's planner — provider-agnostic: any Anthropic / OpenAI / Gemini
//  model, or a local one through Ollama. Plans are plain JSON in, JSON out
//  (no provider-specific tool APIs), so every backend speaks the same
//  contract. Cloud keys arrive with the task (like flow keys) and live only
//  in memory.
//

import Foundation

/// One planned step. `action` picks the verb; the other fields feed it.
struct AgentStep: Codable {
    var intent: String          // human-readable, shown in the step feed
    var action: String          // launch | click | doubleclick | rightclick |
                                // type | key | scroll | wait
    var app: String?            // launch: app name
    var target: String?         // click*: control name from the snapshot
    var role: String?           // click*: optional role hint (AXButton…)
    var text: String?           // type: what to type
    var keys: String?           // key: chord, e.g. "return", "cmd+s"
    var amount: Double?         // scroll: positive scrolls down
    var seconds: Double?        // wait
}

struct AgentPlan: Codable {
    var steps: [AgentStep]
    var note: String?
}

struct AgentBrainConfig {
    var provider: String        // anthropic | openai | gemini | ollama
    var model: String           // empty → provider default
    var key: String?            // cloud key (nil for ollama)

    var resolvedModel: String {
        if !model.isEmpty { return model }
        switch provider {
        case "openai": return "gpt-4o-mini"
        case "gemini": return "gemini-2.0-flash"
        case "ollama": return "llama3.2"
        default:       return "claude-sonnet-5"
        }
    }
}

enum AgentBrain {

    struct Fail: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static let system = """
    You control a Mac for the user by planning steps against its accessibility \
    tree. You are given the task and the CURRENT visible controls. Reply with \
    ONLY a JSON object, no prose, no code fences:
    {"steps":[{"intent":"...","action":"...", ...}]}

    Actions:
    - {"action":"launch","app":"Safari","intent":"Open Safari"}
    - {"action":"click","target":"<control name from the list>","role":"AXButton","intent":"..."}
      (also "doubleclick" / "rightclick"; role is optional but helps)
    - {"action":"type","text":"...","intent":"..."}  — types into the focused control; CLICK the field first
    - {"action":"key","keys":"return","intent":"..."} — chords like "cmd+s", "cmd+shift+4", "esc", "tab"
    - {"action":"scroll","amount":3,"intent":"..."}  — positive scrolls down
    - {"action":"wait","seconds":2,"intent":"..."}   — after slow operations

    Rules:
    - Use ONLY control names that appear in the snapshot; the plan is re-checked
      against a fresh snapshot before every step, and clicking a [menu] item
      opens it so its entries appear in the next snapshot.
    - Prefer keyboard shortcuts (cmd+t, cmd+s…) and menu items over hunting.
    - Click a text field before typing into it; end typed input with a "key"
      "return" step when it should submit.
    - Keep plans short and concrete. If the app you need isn't frontmost,
      "launch" it first, then a "wait" of 1–2 s.
    """

    /// Plan a fresh task against the current snapshot.
    static func plan(task: String, snapshot: String, config: AgentBrainConfig) async throws -> AgentPlan {
        let prompt = """
        TASK: \(task)

        CURRENT UI:
        \(snapshot)
        """
        return try await requestPlan(prompt: prompt, config: config)
    }

    /// Patch a plan mid-run: something diverged (missing control, a dialog…).
    static func replan(task: String, snapshot: String, done: [String],
                       problem: String, config: AgentBrainConfig) async throws -> AgentPlan {
        let prompt = """
        TASK: \(task)

        Steps already completed:
        \(done.isEmpty ? "(none)" : done.map { "- \($0)" }.joined(separator: "\n"))

        PROBLEM: \(problem)

        CURRENT UI (fresh):
        \(snapshot)

        Reply with the REMAINING steps only (same JSON shape). If the task is
        already complete, reply {"steps":[],"note":"done"}.
        """
        return try await requestPlan(prompt: prompt, config: config)
    }

    private static func requestPlan(prompt: String, config: AgentBrainConfig) async throws -> AgentPlan {
        let raw = try await complete(system: system, prompt: prompt, config: config)
        guard let plan = parsePlan(raw) else {
            throw Fail("The model didn't return a usable plan. Raw reply: \(raw.prefix(200))")
        }
        return plan
    }

    /// Salvage the JSON object from a reply that may carry fences or prose.
    static func parsePlan(_ raw: String) -> AgentPlan? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(raw[start...end])
        return try? JSONDecoder().decode(AgentPlan.self, from: Data(json.utf8))
    }

    // MARK: Providers (same wire shapes FlowEngine uses)

    static func complete(system: String, prompt: String, config: AgentBrainConfig) async throws -> String {
        switch config.provider {
        case "openai": return try await openai(system: system, prompt: prompt, config: config)
        case "gemini": return try await gemini(system: system, prompt: prompt, config: config)
        case "ollama": return try await ollama(system: system, prompt: prompt, config: config)
        default:       return try await anthropic(system: system, prompt: prompt, config: config)
        }
    }

    private static func cloudKey(_ config: AgentBrainConfig, label: String) throws -> String {
        guard let key = config.key, !key.isEmpty else {
            throw Fail("No \(label) API key — add one in the agent panel on the companion.")
        }
        return key
    }

    private static func anthropic(system: String, prompt: String, config: AgentBrainConfig) async throws -> String {
        let key = try cloudKey(config, label: "Claude")
        struct Msg: Encodable { let role: String; let content: String }
        struct Req: Encodable { let model: String; let maxTokens: Int; let system: String; let messages: [Msg] }
        struct Resp: Decodable {
            struct Block: Decodable { let text: String? }
            struct Err: Decodable { let message: String? }
            let content: [Block]?
            let error: Err?
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try encoder.encode(Req(model: config.resolvedModel, maxTokens: 2048,
                                              system: system, messages: [Msg(role: "user", content: prompt)]))
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        if let message = resp.error?.message { throw Fail("Claude: \(message)") }
        return resp.content?.compactMap(\.text).joined() ?? ""
    }

    private static func openai(system: String, prompt: String, config: AgentBrainConfig) async throws -> String {
        let key = try cloudKey(config, label: "OpenAI")
        struct Msg: Codable { let role: String; let content: String }
        struct Req: Encodable { let model: String; let messages: [Msg] }
        struct Resp: Decodable {
            struct Choice: Decodable { let message: Msg? }
            struct Err: Decodable { let message: String? }
            let choices: [Choice]?
            let error: Err?
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(model: config.resolvedModel, messages: [
            Msg(role: "system", content: system), Msg(role: "user", content: prompt)]))
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        if let message = resp.error?.message { throw Fail("OpenAI: \(message)") }
        return resp.choices?.first?.message?.content ?? ""
    }

    private static func gemini(system: String, prompt: String, config: AgentBrainConfig) async throws -> String {
        let key = try cloudKey(config, label: "Gemini")
        struct Part: Codable { let text: String }
        struct Content: Codable { var role: String?; let parts: [Part] }
        struct Req: Encodable { let contents: [Content]; let systemInstruction: Content? }
        struct Resp: Decodable {
            struct Candidate: Decodable { let content: Content? }
            struct Err: Decodable { let message: String? }
            let candidates: [Candidate]?
            let error: Err?
        }
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(config.resolvedModel):generateContent?key=\(key)")
        else { throw Fail("Bad Gemini model name") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(
            contents: [Content(role: "user", parts: [Part(text: prompt)])],
            systemInstruction: Content(role: nil, parts: [Part(text: system)])))
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        if let message = resp.error?.message { throw Fail("Gemini: \(message)") }
        return resp.candidates?.first?.content?.parts.map(\.text).joined() ?? ""
    }

    private static func ollama(system: String, prompt: String, config: AgentBrainConfig) async throws -> String {
        struct Msg: Encodable { let role: String; let content: String }
        struct Req: Encodable { let model: String; let messages: [Msg]; let stream: Bool }
        struct Resp: Decodable {
            struct M: Decodable { let content: String }
            let message: M?
            let error: String?
        }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(model: config.resolvedModel, messages: [
            Msg(role: "system", content: system), Msg(role: "user", content: prompt)], stream: false))
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        if let error = resp.error { throw Fail("Ollama: \(error)") }
        return resp.message?.content ?? ""
    }
}
