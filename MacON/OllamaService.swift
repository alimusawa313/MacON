//
//  OllamaService.swift
//  MacON
//
//  Proxies a locally-running Ollama (default 127.0.0.1:11434) for the
//  companion. The phone never talks to Ollama directly — the Mac forwards
//  every request, so the model, the prompts, and any attached files never
//  leave this machine. The wire shapes here (AIModel*/AIChat*) are the ones
//  the companion decodes; Ollama's own shapes stay private to this file.
//

import Foundation
import AppKit

struct OllamaService {
    var base = URL(string: "http://127.0.0.1:11434")!

    // MARK: Wire shapes (shared with the companion by JSON key)

    struct AIModelDTO: Codable { let name: String; let size: Int64; let vision: Bool }
    struct AIModelsDTO: Codable { let models: [AIModelDTO] }
    struct AIChatMessageDTO: Codable {
        let role: String
        let content: String
        let images: [String]?      // base64-encoded, for vision models
    }
    struct AIChatRequestDTO: Codable { let model: String; let messages: [AIChatMessageDTO] }

    // MARK: Models

    /// Encoded `AIModelsDTO` of installed models (each with a resolved vision
    /// flag), or nil when Ollama isn't reachable. Starts Ollama first if it
    /// isn't already running — so opening the Assistant on the phone wakes it.
    func modelsData() async -> Data? {
        guard await ensureRunning() else { return nil }
        guard let tags = try? await tags() else { return nil }
        var out: [AIModelDTO] = []
        await withTaskGroup(of: AIModelDTO?.self) { group in
            for tag in tags {
                group.addTask {
                    let caps = (try? await self.capabilities(tag.name)) ?? []
                    return AIModelDTO(name: tag.name, size: tag.size,
                                      vision: caps.contains("vision"))
                }
            }
            for await model in group { if let model { out.append(model) } }
        }
        out.sort { $0.name < $1.name }
        return try? JSONEncoder().encode(AIModelsDTO(models: out))
    }

    /// Number of installed models, or nil if Ollama isn't reachable — for the
    /// settings status line. Starts Ollama if it isn't running.
    func probe() async -> Int? {
        guard await ensureRunning() else { return nil }
        return (try? await tags())?.count
    }

    /// Ensure the local Ollama server is up: if a quick ping fails, launch it
    /// (the menu-bar app, or the `ollama serve` CLI) and poll until it answers
    /// or we give up.
    func ensureRunning() async -> Bool {
        if await ping() { return true }
        launch()
        for _ in 0..<16 {                         // ~8s: a cold server start
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await ping() { return true }
        }
        return false
    }

    /// A fast "is it there?" — the tags endpoint with a short timeout.
    private func ping() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("api/tags"))
        req.timeoutInterval = 1.5
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse).map { (200..<500).contains($0.statusCode) } ?? false
    }

    /// Best-effort start: open the Ollama menu-bar app (its background server
    /// binds :11434), and also try the CLI `ollama serve` for Homebrew-only
    /// installs. No-ops harmlessly when neither is present.
    private func launch() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-ga", "Ollama"]        // -g: don't steal focus
        try? open.run()

        let candidates = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return }
        let serve = Process()
        serve.executableURL = URL(fileURLWithPath: path)
        serve.arguments = ["serve"]
        try? serve.run()
    }

    // MARK: Chat (streaming)

    /// Forward a chat request to Ollama and relay each NDJSON line to `emit`
    /// the instant it arrives. On any failure, emits a single error line so the
    /// companion can surface it in the conversation.
    func chat(body: Data, emit: @escaping @Sendable (Data) -> Void) async {
        guard let req = try? JSONDecoder().decode(AIChatRequestDTO.self, from: body) else {
            emit(Self.errorLine("Malformed chat request.")); return
        }
        guard await ensureRunning() else {
            emit(Self.errorLine("Couldn't reach Ollama on this Mac — is it running? "
                                + "Install it from ollama.com and run `ollama serve`."))
            return
        }
        var urlReq = URLRequest(url: base.appendingPathComponent("api/chat"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let ollama = OllamaChatBody(
            model: req.model,
            messages: req.messages.map {
                OllamaMessage(role: $0.role, content: $0.content, images: $0.images)
            },
            stream: true)
        urlReq.httpBody = try? JSONEncoder().encode(ollama)

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: urlReq)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                emit(Self.errorLine("Ollama returned HTTP \(http.statusCode).")); return
            }
            // Ollama already streams one JSON object per line — relay verbatim,
            // re-adding the newline the line splitter strips.
            for try await line in bytes.lines {
                guard !line.isEmpty else { continue }
                var data = Data(line.utf8)
                data.append(0x0A)
                emit(data)
            }
        } catch {
            emit(Self.errorLine("Couldn't reach Ollama on this Mac — is it running? "
                                + "Install it from ollama.com and run `ollama serve`."))
        }
    }

    private static func errorLine(_ message: String) -> Data {
        var data = (try? JSONEncoder().encode(["error": message]))
            ?? Data(#"{"error":"error"}"#.utf8)
        data.append(0x0A)
        return data
    }

    // MARK: Ollama endpoints

    private struct Tag: Decodable { let name: String; let size: Int64 }
    private struct TagsResponse: Decodable { let models: [Tag] }

    private func tags() async throws -> [Tag] {
        var req = URLRequest(url: base.appendingPathComponent("api/tags"))
        req.timeoutInterval = 4
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(TagsResponse.self, from: data).models
    }

    private struct ShowResponse: Decodable { let capabilities: [String]? }

    /// A model's capabilities (e.g. "completion", "vision", "tools"). Empty on
    /// older Ollama builds that don't report them.
    private func capabilities(_ model: String) async throws -> [String] {
        var req = URLRequest(url: base.appendingPathComponent("api/show"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["model": model])
        req.timeoutInterval = 4
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONDecoder().decode(ShowResponse.self, from: data).capabilities) ?? []
    }

    private struct OllamaChatBody: Encodable {
        let model: String; let messages: [OllamaMessage]; let stream: Bool
    }
    private struct OllamaMessage: Encodable {
        let role: String; let content: String; let images: [String]?
    }
}
