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
        guard process == nil else { return }
        guard let bin = Self.binaryPath() else { status = .notInstalled; return }
        stopRequested = false
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
                    guard let self, self.process != nil else { return }
                    if case .running = self.status {} else { self.status = .running(url) }
                }
            }
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                if self.stopRequested {
                    self.status = .off
                } else {
                    self.status = .failed("Tunnel exited (code \(proc.terminationStatus)). Try again.")
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

    func stop() {
        stopRequested = true
        process?.terminate()
        process = nil
        status = .off
    }
}
