//
//  RunnerPool.swift
//  MacON
//
//  Manages the set of runners and shared machine-cache cleanup.
//

import Foundation
import Combine

@MainActor
final class RunnerPool: ObservableObject {

    @Published private(set) var agents: [RunnerAgent] = []
    @Published var cleanupSettings: CleanupSettings {
        didSet {
            persistSettings()
            for agent in agents { agent.cleanupSettings = cleanupSettings }
        }
    }
    @Published var isCleaningCaches = false
    @Published var lastCacheReport: CleanReport?
    @Published var reclaimableBytes: Int64 = 0

    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()
    private enum Keys {
        static let instances = "pool.instances"
        static let settings = "pool.cleanupSettings"
    }

    init() {
        cleanupSettings = Self.loadSettings()
        for instance in Self.loadInstances() {
            let agent = RunnerAgent(instance: instance, cleanupSettings: cleanupSettings)
            observe(agent)
            agents.append(agent)
        }
    }

    /// Forward a child's changes so views observing only the pool (e.g. the menu
    /// bar) refresh when a runner's state changes.
    private func observe(_ agent: RunnerAgent) {
        agent.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Derived

    var activeCount: Int { agents.filter { $0.state.isActive }.count }
    var anyActive: Bool { activeCount > 0 }

    // MARK: - Mutating the pool

    @discardableResult
    func addRunner() -> RunnerAgent {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var instance = RunnerInstance()
        instance.name = "Runner \(agents.count + 1)"
        instance.workingDirectory = "\(home)/bitbucket-runners/\(instance.id.uuidString.prefix(8))"
        let agent = RunnerAgent(instance: instance, cleanupSettings: cleanupSettings)
        observe(agent)
        agents.append(agent)
        persistInstances()
        return agent
    }

    func remove(_ agent: RunnerAgent) {
        if agent.state.isActive { agent.stop() }
        agents.removeAll { $0.id == agent.id }
        persistInstances()
    }

    /// Persist after editing a runner's fields via the binding in the edit sheet.
    func commitEdits() { persistInstances() }

    func startAll() { for a in agents { a.start() } }
    func stopAll()  { for a in agents where a.state.isActive { a.stop() } }

    // MARK: - Shared cache cleanup

    /// Refuses to run while any runner is active — wiping shared DerivedData
    /// mid-build would corrupt whichever runner is building.
    func cleanCaches() {
        guard !isCleaningCaches else { return }
        guard !anyActive else { return }
        isCleaningCaches = true
        let plan = cleanupSettings.cachePlan
        Task { @MainActor in
            let report = await Cleaner.clean(plan)
            self.lastCacheReport = report
            self.isCleaningCaches = false
            await self.refreshReclaimable()
        }
    }

    func refreshReclaimable() async {
        reclaimableBytes = await Cleaner.estimate(cleanupSettings.cachePlan)
    }

    // MARK: - Persistence

    private func persistInstances() {
        let instances = agents.map(\.instance)
        if let data = try? JSONEncoder().encode(instances) {
            defaults.set(data, forKey: Keys.instances)
        }
    }
    private func persistSettings() {
        if let data = try? JSONEncoder().encode(cleanupSettings) {
            defaults.set(data, forKey: Keys.settings)
        }
    }
    private static func loadInstances() -> [RunnerInstance] {
        guard let data = UserDefaults.standard.data(forKey: Keys.instances),
              let list = try? JSONDecoder().decode([RunnerInstance].self, from: data)
        else { return [] }
        return list
    }
    private static func loadSettings() -> CleanupSettings {
        guard let data = UserDefaults.standard.data(forKey: Keys.settings),
              let s = try? JSONDecoder().decode(CleanupSettings.self, from: data)
        else { return CleanupSettings() }
        return s
    }
}
