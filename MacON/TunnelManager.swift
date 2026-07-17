//
//  TunnelManager.swift
//  MacON
//
//  Exposes the companion server to the internet via a Cloudflare quick tunnel
//  (`cloudflared tunnel --url …`) — free, no account needed. The tunnel prints
//  a public https://<random>.trycloudflare.com URL; websockets (screen/control)
//  ride through it as wss. Security model is unchanged: /pair still needs a
//  one-time code and everything else a device token — the URL alone grants
//  nothing.
//
//  Note: quick-tunnel URLs rotate on every start. The paired device's token
//  stays valid — it just needs the new address (Change Address on the iPhone).
//

import Foundation
import AppKit
import Combine

@MainActor
final class TunnelManager: ObservableObject {
    enum Status: Equatable {
        case off
        case notInstalled            // cloudflared binary missing
        case starting
        case running(String)         // public https URL
        case failed(String)
    }

    @Published private(set) var status: Status = .off

    private var process: Process?
    private var stopRequested = false
    private var desiredPort: Int?

    var publicURL: String? {
        if case .running(let url) = status { return url }
        return nil
    }

    init() {
        // Child processes outlive the app unless we kill them on quit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    static var isInstalled: Bool { binaryPath() != nil }

    private static func binaryPath() -> String? {
        ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Lifecycle

    func start(port: Int) {
        desiredPort = port
        stopRequested = false
        guard process == nil else { return }
        launch(port: port)
    }

    private func launch(port: Int) {
        guard let bin = Self.binaryPath() else { status = .notInstalled; return }
        status = .starting

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["tunnel", "--url", "http://127.0.0.1:\(port)", "--no-autoupdate"]

        // The quick-tunnel banner (with the public URL) is written to stderr.
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if let range = text.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#,
                                      options: .regularExpression) {
                let url = String(text[range])
                Task { @MainActor [weak self] in
                    guard let self, self.process === p else { return }
                    if case .running = self.status {} else { self.status = .running(url) }
                }
            }
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self, self.process === p else { return }   // ignore a superseded process
                pipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                if self.stopRequested {
                    self.status = .off
                } else {
                    // Unexpected exit (usually the Mac slept). Note it, but let
                    // the wake handler bring a fresh tunnel back on its own.
                    self.status = .failed("Tunnel dropped — reconnecting on wake.")
                }
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Force a fresh tunnel (a new public URL). Used after the Mac wakes: the
    /// old cloudflared may be dead or its edge connection stale, so we tear it
    /// down and relaunch. The old process's termination is ignored via the
    /// `process === p` guard, so it can't clobber the new run's status.
    func refreshNow() {
        guard let port = desiredPort, !stopRequested else { return }
        let old = process
        process = nil
        old?.terminate()
        launch(port: port)
    }

    func stop() {
        stopRequested = true
        desiredPort = nil
        process?.terminate()
        process = nil
        status = .off
    }
}
