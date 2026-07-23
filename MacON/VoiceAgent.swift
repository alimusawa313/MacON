//
//  VoiceAgent.swift
//  MacON
//
//  The live-voice brain. The companion streams the user's speech to text and
//  sends the running conversation; this answers each turn with what to SAY
//  (spoken on the device) and — when the user asked for something to be DONE —
//  a task string the companion hands to the existing dictate-to-drive agent
//  (AgentRunner via POST /agent/task). Same provider registry as the agent:
//  built-ins, Ollama, or any user-added OpenAI-compatible provider.
//

import Foundation
import MaconKit

@MainActor
enum VoiceAgent {

    private static let system = """
    You are the voice of the user's Mac — a live, spoken conversation. You can \
    see the Mac's current screen through its accessibility tree, and you can \
    act on the Mac by delegating a task to its automation agent.

    Reply with ONLY a JSON object, no prose, no code fences:
    {"say":"<what to speak aloud>","task":null}

    Rules:
    - "say" is SPOKEN through text-to-speech: keep it short and conversational
      (1–3 sentences), no markdown, no lists, no code, no URLs spelled out.
    - If the user asks you to DO something on the Mac (open an app, click,
      type, search, arrange windows…), set "task" to a concise, self-contained
      instruction for the automation agent — resolve any pronouns using the
      conversation — and make "say" a short acknowledgement of what you're
      about to do. Otherwise "task" must be null.
    - Questions about what's on screen: answer from the CURRENT UI snapshot.
    - Anything else (questions, chat): just answer in "say".
    """

    /// Answer one conversation turn against the current screen.
    static func turn(_ req: CompanionVoiceTurnRequestDTO) async -> CompanionVoiceTurnResponseDTO? {
        let provider = req.provider ?? "anthropic"
        var model = req.model ?? ""
        var baseURL: String? = nil
        var key = resolvedKey(provider: provider)
        if let custom = CustomProviders.provider(id: provider) {
            baseURL = custom.baseURL
            if (key ?? "").isEmpty { key = nonEmpty(CustomProviders.key(for: provider)) }
            if model.isEmpty { model = custom.models.first ?? "" }
        }
        let config = AgentBrainConfig(provider: provider, model: model, key: key, baseURL: baseURL)

        let snap = AXSnapshotter.snapshot()
        let transcript = req.messages.suffix(24).map {
            "\($0.role == "assistant" ? "ASSISTANT" : "USER"): \($0.content)"
        }.joined(separator: "\n")

        let prompt = """
        CONVERSATION SO FAR (answer the last USER turn):
        \(transcript)

        CURRENT UI:
        \(AXSnapshotter.promptText(app: snap.app, window: snap.window, nodes: snap.nodes))
        """

        do {
            let raw = try await AgentBrain.complete(system: system, prompt: prompt, config: config)
            return parse(raw)
        } catch {
            return CompanionVoiceTurnResponseDTO(say: error.localizedDescription, task: nil)
        }
    }

    /// Salvage {say, task} from a reply that may carry fences or prose; a
    /// model that answered in plain text still gets spoken.
    private static func parse(_ raw: String) -> CompanionVoiceTurnResponseDTO {
        struct Turn: Decodable { let say: String?; let task: String? }
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
           let turn = try? JSONDecoder().decode(Turn.self, from: Data(String(raw[start...end]).utf8)),
           let say = turn.say, !say.isEmpty {
            let task = turn.task?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CompanionVoiceTurnResponseDTO(say: say, task: (task?.isEmpty ?? true) ? nil : task)
        }
        let plain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return CompanionVoiceTurnResponseDTO(say: plain.isEmpty ? "I didn't get a reply from the model." : plain,
                                             task: nil)
    }

    /// The Mac's stored key for a built-in provider (custom providers resolve
    /// their own; Ollama needs none).
    private static func resolvedKey(provider: String) -> String? {
        let stored: String
        switch provider {
        case "openai":    stored = CloudAI.openaiKey
        case "gemini":    stored = CloudAI.geminiKey
        case "anthropic": stored = CloudAI.claudeKey
        default:          return nil
        }
        return stored.isEmpty ? nil : stored
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
}
