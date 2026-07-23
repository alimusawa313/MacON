//
//  CustomProviders.swift
//  MacON
//
//  User-managed OpenAI-compatible AI providers (a base URL + key + model list).
//  The built-in providers (Claude/OpenAI/Gemini/Ollama) have their own wire
//  formats and stay fixed; anything else is a "custom" gateway spoken to in the
//  OpenAI chat/completions shape. Definitions live in UserDefaults; keys in the
//  Keychain. DevOps Institute is seeded once as a removable entry.
//

import Foundation
import MaconKit

struct CustomAIProvider: Codable, Identifiable, Hashable {
    var id: String            // slug, e.g. "devops"
    var name: String          // "DevOps Institute"
    var baseURL: String       // full /chat/completions URL
    var models: [String]      // offered model ids
}

enum CustomProviders {
    static let builtinIDs = ["anthropic", "openai", "gemini", "ollama"]
    static func isBuiltin(_ id: String) -> Bool { builtinIDs.contains(id) }

    private static let listKey = "ai.customProviders"
    private static let seededKey = "ai.customProvidersSeeded"

    static var all: [CustomAIProvider] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let list = try? JSONDecoder().decode([CustomAIProvider].self, from: data)
        else { return [] }
        return list
    }

    static func provider(id: String) -> CustomAIProvider? { all.first { $0.id == id } }

    private static func save(_ list: [CustomAIProvider]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: listKey)
        }
    }

    /// Add or replace (matched by id).
    static func upsert(_ p: CustomAIProvider) {
        var list = all
        if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
        save(list)
    }

    static func remove(id: String) {
        save(all.filter { $0.id != id })
        Keychain.set("", account: keyAccount(id))
    }

    // MARK: Keys (Keychain, per provider)

    static func key(for id: String) -> String { Keychain.get(account: keyAccount(id)) }
    static func setKey(_ value: String, for id: String) { Keychain.set(value, account: keyAccount(id)) }
    private static func keyAccount(_ id: String) -> String { "provider.key.\(id)" }

    /// A stable slug from a display name, unique against existing ids.
    static func slug(from name: String) -> String {
        let base = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
            .split(separator: "-").joined(separator: "-")
        var id = base.isEmpty ? "provider" : base
        var n = 2
        let taken = Set(all.map(\.id)).union(builtinIDs)
        while taken.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    /// Seed a removable DevOps Institute entry once, so it's there by default.
    static func seedIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        UserDefaults.standard.set(true, forKey: seededKey)
        if provider(id: "devops") == nil {
            upsert(CustomAIProvider(
                id: "devops", name: "DevOps Institute",
                baseURL: "https://llm.devopsinstitute.id/v1/chat/completions",
                models: ["claude-haiku", "claude-sonnet", "claude-opus"]))
        }
    }
}
