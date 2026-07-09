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
    /// Whether paired devices may control this Mac (cursor + keyboard).
    @Published var allowControl: Bool {
        didSet {
            defaults.set(allowControl, forKey: controlKey)
            if allowControl { remote.requestPermission() }
        }
    }

    private var service: CompanionService?
    private let store = PairingStore()
    private let broadcaster = ScreenBroadcaster()
    private var streamer: ScreenStreamer?
    private let remote = RemoteControl()
    private let defaults = UserDefaults.standard
    private let enabledKey = "companion.enabled"
    private let portKey = "companion.port"
    private let screenKey = "companion.shareScreen"
    private let controlKey = "companion.allowControl"

    init() {
        port = defaults.object(forKey: portKey) as? Int ?? 8899
        shareScreen = defaults.object(forKey: screenKey) as? Bool ?? true
        allowControl = defaults.bool(forKey: controlKey)   // default off (sensitive)
        devices = store.deviceList()

        // Demand-driven capture: run only while a device is viewing.
        broadcaster.onActive = { [weak self] active in
            Task { @MainActor in self?.setScreenCapture(active) }
        }
        broadcaster.onNeedKeyframe = { [weak self] in
            Task { @MainActor in self?.streamer?.forceKeyframe() }
        }
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
            screen: broadcaster,
            control: { [weak self] event in
                Task { @MainActor in
                    guard let self, self.allowControl else { return }
                    self.remote.handle(event)
                }
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
            let s = ScreenStreamer(publish: { [broadcaster] packet in broadcaster.publish(packet) })
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
