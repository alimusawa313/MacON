//
//  CompanionManager.swift
//  MacON
//
//  App-side controller for the companion server (MaconKit's CompanionService).
//  The app's pipelines feed it live, so a paired iPhone/iPad sees the same runs
//  as the desktop. Pairing state is shared on disk with the CLI, so a device
//  paired either way works with both.
//

import Foundation
import Combine
import MaconKit

@MainActor
final class CompanionManager: ObservableObject {
    @Published var port: Int
    @Published private(set) var isRunning = false
    @Published private(set) var pairingCode: String?
    @Published private(set) var devices: [PairingStore.Device] = []
    /// Whether paired devices may view this Mac's screen.
    @Published var shareScreen: Bool {
        didSet {
            defaults.set(shareScreen, forKey: screenKey)
            if !shareScreen { setScreenCapture(false) }
        }
    }

    private var service: CompanionService?
    private let store = PairingStore()
    private let screenBox = ScreenFrameBox()
    private var streamer: ScreenStreamer?
    private let defaults = UserDefaults.standard
    private let enabledKey = "companion.enabled"
    private let portKey = "companion.port"
    private let screenKey = "companion.shareScreen"

    init() {
        port = defaults.object(forKey: portKey) as? Int ?? 8899
        shareScreen = defaults.object(forKey: screenKey) as? Bool ?? true
        devices = store.deviceList()
    }

    /// Should the server come up automatically at launch?
    var startsAtLaunch: Bool { defaults.bool(forKey: enabledKey) }

    var host: String { ProcessInfo.processInfo.hostName }
    var address: String { "\(host):\(port)" }

    /// Payload encoded into the pairing QR (for a future in-app scanner).
    var pairingURL: String? {
        pairingCode.map { "macon://pair?host=\(host)&port=\(port)&code=\($0)" }
    }

    // MARK: Lifecycle

    func start(runnerName: String, runners: @escaping () -> [PipelineRunner]) {
        guard service == nil else { return }
        defaults.set(port, forKey: portKey)
        defaults.set(true, forKey: enabledKey)
        let svc = CompanionService(
            runners: runners, runnerName: runnerName,
            port: UInt16(clamping: port), store: store,
            screenFrames: screenBox,
            screenControl: { [weak self] active in
                Task { @MainActor in self?.setScreenCapture(active) }
            },
            onLog: { _ in })
        svc.start()
        service = svc
        isRunning = true
        refreshDevices()
        if store.deviceCount == 0 { newCode() }
    }

    func stop() {
        setScreenCapture(false)
        service?.stop()
        service = nil
        isRunning = false
        pairingCode = nil
        defaults.set(false, forKey: enabledKey)
    }

    /// Start/stop screen capture on demand — driven by whether anyone is viewing.
    func setScreenCapture(_ active: Bool) {
        if active && shareScreen {
            guard streamer == nil else { return }
            let s = ScreenStreamer(box: screenBox)
            s.start()
            streamer = s
        } else {
            streamer?.stop()
            streamer = nil
        }
    }

    // MARK: Pairing

    func newCode(minutes: Int = 15) {
        pairingCode = store.mintCode(ttl: TimeInterval(minutes * 60))
    }

    func clearCode() { pairingCode = nil }

    func refreshDevices() { devices = store.deviceList() }

    func revoke(_ device: PairingStore.Device) {
        store.revoke(prefix: device.token)
        refreshDevices()
    }
}
