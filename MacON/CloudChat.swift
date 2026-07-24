//
//  CloudChat.swift
//  MacON
//
//  Multi-turn cloud completions run on the Mac, using the keys stored here
//  (Settings → AI Providers). Keys never leave the Mac, so a paired device's
//  cloud chat (the assistant, the code assistant, voice) routes through
//  /ai/chat and the call is made here. STREAMING: each provider is read as an
//  SSE stream and `onDelta` fires per token, so /ai/chat relays tokens as they
//  arrive (just like local Ollama). Servers that ignore `stream` fall back to
//  a single whole-reply delta. Returns the full accumulated text too.
//

import Foundation

enum CloudChat {
    struct Msg { let role: String; let content: String }   // role: user | assistant

    struct Fail: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// True for a cloud provider this handles: a built-in or a known custom one.
    static func isCloud(_ provider: String) -> Bool {
        ["anthropic", "openai", "gemini"].contains(provider)
            || CustomProviders.provider(id: provider) != nil
    }

    /// Stream a completion. `onDelta` fires with each text chunk; the whole
    /// reply is also returned.
    @discardableResult
    static func complete(provider: String, model: String, system: String, messages: [Msg],
                         onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        switch provider {
        case "openai":
            return try await openAICompat(base: "https://api.openai.com/v1/chat/completions",
                                          key: CloudAI.openaiKey, label: "OpenAI",
                                          model: model.isEmpty ? "gpt-5.1" : model,
                                          system: system, messages: messages, onDelta: onDelta)
        case "gemini":
            return try await gemini(key: CloudAI.geminiKey,
                                    model: model.isEmpty ? "gemini-2.5-flash" : model,
                                    system: system, messages: messages, onDelta: onDelta)
        case "anthropic":
            return try await anthropic(key: CloudAI.claudeKey,
                                       model: model.isEmpty ? "claude-sonnet-5" : model,
                                       system: system, messages: messages, onDelta: onDelta)
        default:
            guard let custom = CustomProviders.provider(id: provider) else {
                throw Fail("Unknown AI provider '\(provider)'.")
            }
            return try await openAICompat(base: custom.baseURL,
                                          key: CustomProviders.key(for: provider), label: custom.name,
                                          model: model.isEmpty ? (custom.models.first ?? "") : model,
                                          system: system, messages: messages, onDelta: onDelta)
        }
    }

    private static func requireKey(_ key: String, _ label: String) throws -> String {
        guard !key.isEmpty else {
            throw Fail("No \(label) API key on the Mac — add one in Settings → AI Providers.")
        }
        return key
    }

    /// Open a streaming POST and return its line iterator, or throw with the
    /// server's error body on a non-2xx status.
    private static func openStream(_ req: URLRequest, label: String)
        async throws -> URLSession.AsyncBytes {
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 800 { break } }
            let detail = extractError(body) ?? "HTTP \(http.statusCode)"
            throw Fail("\(label): \(detail)")
        }
        return bytes
    }

    /// Pull a "message"/"error" out of a JSON error body (best effort).
    private static func extractError(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m }
        if let m = obj["error"] as? String { return m }
        return nil
    }

    // MARK: Anthropic (SSE)

    private static func anthropic(key: String, model: String, system: String, messages: [Msg],
                                  onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        let key = try requireKey(key, "Claude")
        struct M: Encodable { let role: String; let content: String }
        struct Req: Encodable { let model: String; let maxTokens: Int; let system: String
                                let messages: [M]; let stream: Bool }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"; req.timeoutInterval = 180
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let enc = JSONEncoder(); enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(Req(model: model, maxTokens: 4096, system: system,
                                          messages: messages.map { M(role: $0.role, content: $0.content) },
                                          stream: true))

        struct Event: Decodable {
            struct Delta: Decodable { let text: String? }
            struct Err: Decodable { let message: String? }
            let type: String?
            let delta: Delta?
            let error: Err?
        }
        var full = ""
        for try await line in try await openStream(req, label: "Claude").lines {
            guard let payload = sseData(line), payload != "[DONE]",
                  let d = payload.data(using: .utf8),
                  let ev = try? JSONDecoder().decode(Event.self, from: d) else { continue }
            if let m = ev.error?.message { throw Fail("Claude: \(m)") }
            if ev.type == "content_block_delta", let t = ev.delta?.text, !t.isEmpty {
                full += t; onDelta(t)
            }
        }
        return full
    }

    // MARK: OpenAI-compatible (SSE) — OpenAI + custom gateways (DevOps etc.)

    private static func openAICompat(base: String, key: String, label: String, model: String,
                                     system: String, messages: [Msg],
                                     onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        let key = try requireKey(key, label)
        struct M: Encodable { let role: String; let content: String }
        struct Req: Encodable { let model: String; let messages: [M]; let stream: Bool }
        var msgs: [M] = []
        if !system.isEmpty { msgs.append(M(role: "system", content: system)) }
        msgs += messages.map { M(role: $0.role, content: $0.content) }
        var req = URLRequest(url: URL(string: base)!)
        req.httpMethod = "POST"; req.timeoutInterval = 180
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(model: model, messages: msgs, stream: true))

        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                struct Msg: Decodable { let content: String? }
                let delta: Delta?
                let message: Msg?           // non-stream fallback shape
            }
            struct Err: Decodable { let message: String? }
            let choices: [Choice]?
            let error: Err?
        }
        var full = ""
        var raw = ""                        // for the non-SSE fallback
        for try await line in try await openStream(req, label: label).lines {
            guard let payload = sseData(line) else { raw += line; continue }
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(Chunk.self, from: d) else { continue }
            if let m = chunk.error?.message { throw Fail("\(label): \(m)") }
            if let t = chunk.choices?.first?.delta?.content, !t.isEmpty { full += t; onDelta(t) }
        }
        // Server ignored `stream` and returned one JSON object: parse it whole.
        if full.isEmpty, !raw.isEmpty, let d = raw.data(using: .utf8),
           let chunk = try? JSONDecoder().decode(Chunk.self, from: d) {
            if let m = chunk.error?.message { throw Fail("\(label): \(m)") }
            if let t = chunk.choices?.first?.message?.content, !t.isEmpty { full = t; onDelta(t) }
        }
        return full
    }

    // MARK: Gemini (SSE)

    private static func gemini(key: String, model: String, system: String, messages: [Msg],
                               onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        let key = try requireKey(key, "Gemini")
        struct Part: Codable { let text: String }
        struct Content: Codable { var role: String?; let parts: [Part] }
        struct Req: Encodable { let contents: [Content]; let systemInstruction: Content? }
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(key)")
        else { throw Fail("Bad Gemini model name") }
        let contents = messages.map { Content(role: $0.role == "assistant" ? "model" : "user",
                                              parts: [Part(text: $0.content)]) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(
            contents: contents,
            systemInstruction: system.isEmpty ? nil : Content(role: nil, parts: [Part(text: system)])))

        struct Resp: Decodable {
            struct Candidate: Decodable { let content: Content? }
            struct Err: Decodable { let message: String? }
            let candidates: [Candidate]?
            let error: Err?
        }
        var full = ""
        for try await line in try await openStream(req, label: "Gemini").lines {
            guard let payload = sseData(line), let d = payload.data(using: .utf8),
                  let resp = try? JSONDecoder().decode(Resp.self, from: d) else { continue }
            if let m = resp.error?.message { throw Fail("Gemini: \(m)") }
            if let t = resp.candidates?.first?.content?.parts.map(\.text).joined(), !t.isEmpty {
                full += t; onDelta(t)
            }
        }
        return full
    }

    /// The payload of an SSE `data:` line (nil for other lines — comments,
    /// `event:`, blanks).
    private static func sseData(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }
}
