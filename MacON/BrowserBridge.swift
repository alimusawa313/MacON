//
//  BrowserBridge.swift
//  MacON
//
//  A long-lived Node + Playwright subprocess that drives a REAL, visible
//  Chromium window on this Mac — so the agent can act inside web pages with
//  proper selectors, waits and structured snapshots instead of guessing at the
//  browser through the accessibility tree. Commands go over stdin, one JSON
//  line each; replies come back over stdout the same way (bridge.js speaks the
//  other end). Optional: only used when Playwright is installed (see
//  PlaywrightInstaller); otherwise the agent stays on the AX/CGEvent path.
//

import Foundation

final class BrowserBridge: @unchecked Sendable {
    static let shared = BrowserBridge()

    struct Fail: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// One interactive element from a page snapshot. `ref` is a short handle
    /// (e1, e2…) the agent uses to click/type; the page tags the DOM node with
    /// it so the action lands on exactly that element.
    struct Element: Decodable { let ref: String; let role: String; let name: String }
    struct PageSnapshot: Decodable {
        let url: String
        let title: String
        let elements: [Element]
        let text: String
    }

    private var process: Process?
    private var stdin: FileHandle?
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    /// Installed (Playwright present) AND a Node to run it with.
    static var isInstalled: Bool { PlaywrightInstaller.isInstalled }

    // MARK: Lifecycle

    /// Boot the subprocess if it isn't already up. Throws if Playwright/Node
    /// aren't installed, so callers can fall back to the AX path.
    func ensureStarted() throws {
        lock.lock(); let running = process?.isRunning == true; lock.unlock()
        if running { return }

        guard let node = PlaywrightInstaller.nodePath() else {
            throw Fail("Node.js isn't installed — install Playwright from Settings → Browser control.")
        }
        let dir = PlaywrightInstaller.installDir
        let script = dir.appendingPathComponent("bridge.js")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw Fail("Browser control isn't installed — enable it in Settings.")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [script.path]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["NODE_PATH"] = dir.appendingPathComponent("node_modules").path
        env["MACON_PROFILE"] = dir.appendingPathComponent("profile").path
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipe()          // swallow Playwright's chatter
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.ingest(data)
        }
        p.terminationHandler = { [weak self] _ in self?.failAllPending() }

        do { try p.run() } catch {
            throw Fail("Couldn't launch the browser helper: \(error.localizedDescription)")
        }
        lock.lock()
        process = p
        stdin = inPipe.fileHandleForWriting
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let p = process; process = nil; stdin = nil
        buffer.removeAll()
        lock.unlock()
        failAllPending()
        p?.terminate()
    }

    // MARK: High-level commands

    @discardableResult
    func goto(_ url: String) async throws -> PageSnapshot {
        try await snapshotResult(["cmd": "goto", "url": normalize(url)])
    }
    @discardableResult
    func click(ref: String?, text: String?) async throws -> PageSnapshot {
        var cmd: [String: Any] = ["cmd": "click"]
        if let ref, !ref.isEmpty { cmd["ref"] = ref }
        if let text, !text.isEmpty { cmd["text"] = text }
        return try await snapshotResult(cmd)
    }
    @discardableResult
    func type(ref: String?, text: String, submit: Bool) async throws -> PageSnapshot {
        var cmd: [String: Any] = ["cmd": "type", "text": text, "submit": submit]
        if let ref, !ref.isEmpty { cmd["ref"] = ref }
        return try await snapshotResult(cmd)
    }
    @discardableResult
    func press(_ key: String) async throws -> PageSnapshot {
        try await snapshotResult(["cmd": "press", "key": key])
    }
    @discardableResult
    func scroll(_ amount: Double) async throws -> PageSnapshot {
        try await snapshotResult(["cmd": "scroll", "dy": amount * 400])
    }
    @discardableResult
    func back() async throws -> PageSnapshot {
        try await snapshotResult(["cmd": "back"])
    }
    /// Re-read the current page (used to feed the planner between steps).
    func snapshot() async throws -> PageSnapshot {
        try await snapshotResult(["cmd": "snapshot"])
    }

    private func snapshotResult(_ cmd: [String: Any]) async throws -> PageSnapshot {
        let reply = try await send(cmd)
        if let err = reply["error"] as? String { throw Fail(err) }
        guard let result = reply["result"],
              let data = try? JSONSerialization.data(withJSONObject: result),
              let snap = try? JSONDecoder().decode(PageSnapshot.self, from: data) else {
            throw Fail("The browser helper returned an unexpected reply.")
        }
        return snap
    }

    private func normalize(_ url: String) -> String {
        let t = url.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return t }
        return "https://" + t
    }

    // MARK: Wire

    private func send(_ cmd: [String: Any]) async throws -> [String: Any] {
        try ensureStarted()
        lock.lock()
        nextID += 1
        let id = nextID
        var payload = cmd
        payload["id"] = id
        let handle = stdin
        lock.unlock()

        guard let handle,
              var line = try? JSONSerialization.data(withJSONObject: payload) else {
            throw Fail("Browser control isn't ready.")
        }
        line.append(0x0A)

        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { cont in
                    guard let self else { cont.resume(throwing: Fail("gone")); return }
                    self.lock.lock(); self.pending[id] = cont; self.lock.unlock()
                    handle.write(line)
                }
            }
            group.addTask {
                // A hung page shouldn't wedge the agent forever.
                try await Task.sleep(nanoseconds: 45 * 1_000_000_000)
                throw Fail("The browser timed out.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Fail("no reply") }
            return first
        }
    }

    /// Accumulate stdout and resolve each complete JSON line to its waiter.
    private func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        var toResume: [(CheckedContinuation<[String: Any], Error>, [String: Any])] = []
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) else { continue }
            toResume.append((cont, obj))
        }
        lock.unlock()
        for (cont, obj) in toResume { cont.resume(returning: obj) }
    }

    private func failAllPending() {
        lock.lock()
        let waiters = pending.values
        pending.removeAll()
        lock.unlock()
        for cont in waiters { cont.resume(throwing: Fail("The browser helper stopped.")) }
    }
}
