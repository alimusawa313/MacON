//
//  CloudChat.swift
//  MacON
//
//  Multi-turn cloud completions run on the Mac, using the keys stored here
//  (Settings → AI Providers). Keys never leave the Mac, so a paired device's
//  cloud chat (the code assistant) routes through /ai/chat and the call is made
//  here. Non-streaming — returns the whole reply, which /ai/chat emits as one
//  chunk. Local (Ollama) chat keeps its own streaming path.
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

    static func complete(provider: String, model: String,
                         system: String, messages: [Msg]) async throws -> String {
        switch provider {
        case "openai":
            return try await openAICompat(base: "https://api.openai.com/v1/chat/completions",
                                          key: CloudAI.openaiKey, label: "OpenAI",
                                          model: model.isEmpty ? "gpt-5.1" : model,
                                          system: system, messages: messages)
        case "gemini":
            return try await gemini(key: CloudAI.geminiKey,
                                    model: model.isEmpty ? "gemini-2.5-flash" : model,
                                    system: system, messages: messages)
        case "anthropic":
            return try await anthropic(key: CloudAI.claudeKey,
                                       model: model.isEmpty ? "claude-sonnet-5" : model,
                                       system: system, messages: messages)
        default:
            guard let custom = CustomProviders.provider(id: provider) else {
                throw Fail("Unknown AI provider '\(provider)'.")
            }
            return try await openAICompat(base: custom.baseURL,
                                          key: CustomProviders.key(for: provider), label: custom.name,
                                          model: model.isEmpty ? (custom.models.first ?? "") : model,
                                          system: system, messages: messages)
        }
    }

    private static func requireKey(_ key: String, _ label: String) throws -> String {
        guard !key.isEmpty else {
            throw Fail("No \(label) API key on the Mac — add one in Settings → AI Providers.")
        }
        return key
    }

    private static func anthropic(key: String, model: String,
                                  system: String, messages: [Msg]) async throws -> String {
        let key = try requireKey(key, "Claude")
        struct M: Encodable { let role: String; let content: String }
        struct Req: Encodable { let model: String; let maxTokens: Int; let system: String; let messages: [M] }
        struct Resp: Decodable {
            struct Block: Decodable { let text: String? }
            struct Err: Decodable { let message: String? }
            let content: [Block]?
            let error: Err?
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"; req.timeoutInterval = 120
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let enc = JSONEncoder(); enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(Req(model: model, maxTokens: 4096, system: system,
                                          messages: messages.map { M(role: $0.role, content: $0.content) }))
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        if let m = resp.error?.message { throw Fail("Claude: \(m)") }
        return resp.content?.compactMap(\.text).joined() ?? ""
    }

    private static func openAICompat(base: String, key: String, label: String, model: String,
                                     system: String, messages: [Msg]) async throws -> String {
        let key = try requireKey(key, label)
        struct M: Codable { let role: String; let content: String }
        struct Req: Encodable { let model: String; let messages: [M] }
        struct Resp: Decodable {
            struct Choice: Decodable { let message: M? }
            struct Err: Decodable { let message: String? }
            let choices: [Choice]?
            let error: Err?
        }
        var msgs: [M] = []
        if !system.isEmpty { msgs.append(M(role: "system", content: system)) }
        msgs += messages.map { M(role: $0.role, content: $0.content) }
        var req = URLRequest(url: URL(string: base)!)
        req.httpMethod = "POST"; req.timeoutInterval = 120
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(model: model, messages: msgs))
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        if let m = resp.error?.message { throw Fail("\(label): \(m)") }
        return resp.choices?.first?.message?.content ?? ""
    }

    private static func gemini(key: String, model: String,
                               system: String, messages: [Msg]) async throws -> String {
        let key = try requireKey(key, "Gemini")
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
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)")
        else { throw Fail("Bad Gemini model name") }
        // Gemini calls the assistant role "model".
        let contents = messages.map { Content(role: $0.role == "assistant" ? "model" : "user",
                                               parts: [Part(text: $0.content)]) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Req(
            contents: contents,
            systemInstruction: system.isEmpty ? nil : Content(role: nil, parts: [Part(text: system)])))
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        if let m = resp.error?.message { throw Fail("Gemini: \(m)") }
        return resp.candidates?.first?.content?.parts.map(\.text).joined() ?? ""
    }
}
