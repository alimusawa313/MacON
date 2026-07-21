//
//  PushManager.swift
//  MacON
//
//  Build-event push notifications to paired devices. The Mac is its own APNs
//  provider (MaconKit.APNsSender): companions register their APNs token via
//  /apns/register, and every pipeline lifecycle moment fans out as an alert.
//  The .p8 auth key lives in the Keychain; Key ID / Team ID / topic in
//  defaults. Registered device tokens persist to Application Support so a
//  restart doesn't lose them.
//

import Foundation
import Combine
import MaconKit

@MainActor
final class PushManager: ObservableObject {
    /// On/off. Pushes only fire when this is on and the key is configured.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: enabledKey) } }
    @Published var keyID: String { didSet { defaults.set(keyID, forKey: keyIDKey); sync() } }
    @Published var teamID: String { didSet { defaults.set(teamID, forKey: teamIDKey); sync() } }
    /// Which build moments to push (all on by default).
    @Published var onStart: Bool { didSet { defaults.set(onStart, forKey: startKey) } }

    /// The companion's bundle id — the APNs topic. Fixed to our companion.
    let topic = "com.karar.MacON-Companion"

    var keyP8: String {
        get { Keychain.get(account: keyAccount) }
        set { Keychain.set(newValue, account: keyAccount); sync() }
    }
    var hasKey: Bool { !keyP8.isEmpty }
    var isConfigured: Bool { hasKey && keyID.count == 10 && teamID.count == 10 }

    /// Registered devices: bearer-token prefix → (apns token, sandbox?).
    private struct Reg: Codable { var apns: String; var sandbox: Bool }
    private var registry: [String: Reg] = [:]

    private let sender = APNsSender()
    private let defaults = UserDefaults.standard
    private let enabledKey = "push.enabled"
    private let keyIDKey = "push.keyID"
    private let teamIDKey = "push.teamID"
    private let startKey = "push.onStart"
    private let keyAccount = "push.authKeyP8"
    private let regURL: URL

    init() {
        enabled = defaults.bool(forKey: enabledKey)
        keyID = defaults.string(forKey: keyIDKey) ?? ""
        teamID = defaults.string(forKey: teamIDKey) ?? ""
        onStart = defaults.object(forKey: startKey) as? Bool ?? true
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MacON", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        regURL = dir.appendingPathComponent("push-tokens.json")
        if let data = try? Data(contentsOf: regURL),
           let saved = try? JSONDecoder().decode([String: Reg].self, from: data) {
            registry = saved
        }
        sync()
    }

    /// Push the current credentials into the sender (off the main actor).
    private func sync() {
        let cfg = APNsSender.Config(keyP8: keyP8, keyID: keyID, teamID: teamID, topic: topic)
        Task { await sender.setConfig(cfg.isComplete ? cfg : nil) }
    }

    var registeredCount: Int { registry.count }

    // MARK: Registration (called from the /apns/register route)

    /// Store a device's APNs token, keyed by its bearer-token prefix so a
    /// re-register replaces cleanly. Body: {"apns": "...", "sandbox": bool}.
    func register(bearer: String, body: Data) -> Bool {
        struct Body: Decodable { var apns: String; var sandbox: Bool? }
        guard let b = try? JSONDecoder().decode(Body.self, from: body),
              !b.apns.isEmpty else { return false }
        registry[String(bearer.prefix(8))] = Reg(apns: b.apns, sandbox: b.sandbox ?? true)
        persist()
        return true
    }

    /// Drop a device's push token when it's unpaired.
    func unregister(short: String) {
        guard registry[short] != nil else { return }
        registry[short] = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(registry) { try? data.write(to: regURL) }
    }

    // MARK: Fan-out

    /// Send a build event to every registered device (best effort). A device
    /// APNs reports gone (410) is dropped from the registry.
    func fire(_ event: BuildEvent) {
        guard enabled, isConfigured else { return }
        if event.phase == .started && !onStart { return }
        let alert = event.alert
        let payload = ["build": event.pipelineID]   // companion opens this build on tap
        let targets = registry
        Task {
            for (short, reg) in targets {
                let error = await sender.send(deviceToken: reg.apns, sandbox: reg.sandbox,
                                              title: alert.title, body: alert.body,
                                              payload: payload)
                if let error, error.contains("410") {
                    await MainActor.run { self.unregister(short: short) }
                }
            }
        }
    }
}
