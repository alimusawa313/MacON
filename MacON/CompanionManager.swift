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
import CoreGraphics
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
    /// Expose the server to the internet via a Cloudflare quick tunnel.
    @Published var remoteEnabled: Bool {
        didSet {
            defaults.set(remoteEnabled, forKey: remoteKey)
            syncTunnel()
        }
    }
    /// The tunnel process/state (UI observes through this manager).
    let tunnel = TunnelManager()

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
    private let remoteKey = "companion.remote"
    private var tunnelSink: AnyCancellable?

    init() {
        port = defaults.object(forKey: portKey) as? Int ?? 8899
        shareScreen = defaults.object(forKey: screenKey) as? Bool ?? true
        allowControl = defaults.bool(forKey: controlKey)   // default off (sensitive)
        remoteEnabled = defaults.bool(forKey: remoteKey)
        devices = store.deviceList()

        // Surface tunnel state changes through this manager's own publisher.
        tunnelSink = tunnel.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }

        // Demand-driven capture: run only while a device is viewing.
        broadcaster.onActive = { [weak self] active in
            Task { @MainActor in self?.setScreenCapture(active) }
        }
        broadcaster.onNeedKeyframe = { [weak self] in
            Task { @MainActor in self?.streamer?.forceKeyframe() }
        }
        // Keep the privacy curtain out of the stream: when it's raised/lowered,
        // refresh which windows the capture excludes so the companion always
        // sees the real screen, never the wall.
        PrivacyCurtain.shared.onChange = { [weak self] in self?.applyCurtainExclusion() }
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

    func start(runnerName: String, runners: @escaping () -> [PipelineRunner],
               pool: PipelinePool? = nil) {
        guard service == nil else { return }
        defaults.set(port, forKey: portKey)
        defaults.set(true, forKey: enabledKey)
        let svc = CompanionService(
            runners: runners, runnerName: runnerName,
            port: UInt16(clamping: port), store: store,
            pool: pool,
            screen: broadcaster,
            control: { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    if event.t == "fps" {                       // stream settings — always allowed
                        if let f = event.code { self.setStreamFPS(f) }
                        return
                    }
                    if event.t == "res" {
                        if let w = event.code { self.setStreamMaxWidth(w) }
                        return
                    }
                    guard self.allowControl else { return }
                    self.remote.handle(event)
                }
            },
            apps: { AppCatalog.list() },
            windows: { [weak self] in
                // CompactOS picker — window metadata rides the screen-share toggle.
                guard await MainActor.run(body: { self?.shareScreen ?? false }) else {
                    return CompanionWindowsDTO(windows: [])
                }
                return await WindowManager.list()
            },
            compactOpen: { [weak self] req in
                // Launching/resizing windows is remote control — same gate.
                guard await MainActor.run(body: { self?.allowControl ?? false }) else { return nil }
                guard let result = await WindowManager.openCompact(req) else { return nil }
                await MainActor.run {
                    // A device is now driving this window — wall off the Mac's
                    // physical screen so nobody interferes (or watches).
                    self?.compactSessionStarted()
                    if result.resized {
                        // We just refit the window being streamed — rebuild the
                        // capture at its new size. The viewer keeps its
                        // connection and simply gets a keyframe with the new
                        // dimensions.
                        self?.refreshStreamIfTargeting(result.response.windowId)
                    }
                }
                return result.response
            },
            screenTarget: { [weak self] id in
                Task { @MainActor in self?.setScreenTarget(id) }
            },
            onLog: { _ in })
        svc.start()
        service = svc
        isRunning = true
        refreshDevices()
        if store.deviceCount == 0 { newCode() }
        syncTunnel()
    }

    func stop() {
        tunnel.stop()
        setScreenCapture(false)
        // Server going away ends any compact session — drop the wall now if
        // it's ours.
        curtainLowerTask?.cancel(); curtainLowerTask = nil
        if curtainAutoRaised {
            curtainAutoRaised = false
            if PrivacyCurtain.shared.isUp { PrivacyCurtain.shared.lower() }
        }
        service?.stop()
        service = nil
        isRunning = false
        pairingCode = nil
        defaults.set(false, forKey: enabledKey)
    }

    /// Keep the tunnel in step with the server + the remote toggle.
    private func syncTunnel() {
        if isRunning && remoteEnabled {
            tunnel.start(port: port)
        } else {
            tunnel.stop()
        }
    }

    /// CompactOS: the window the stream should capture (nil = whole display).
    /// Set per /screen connection — a compact viewer names its window; a plain
    /// viewer resets to the display.
    private var streamWindowID: CGWindowID?
    func setScreenTarget(_ id: CGWindowID?) {
        // Curtain bookkeeping runs on every connect: a compact viewer (window
        // target) keeps the wall up, a plain full-screen viewer releases it.
        if id != nil { compactSessionStarted() } else { compactSessionMaybeEnded() }
        guard id != streamWindowID else { return }
        streamWindowID = id
        streamer?.setWindowTarget(id)
    }

    // MARK: CompactOS privacy curtain

    /// Whether WE raised the curtain for a CompactOS session (a curtain the
    /// user raised manually is never auto-lowered).
    private var curtainAutoRaised = false
    private var curtainLowerTask: Task<Void, Never>?

    /// A CompactOS session is live — raise the privacy wall over the Mac's
    /// physical screen (the per-window stream never shows it, and its windows
    /// ignore mouse events, so remote control keeps working).
    private func compactSessionStarted() {
        curtainLowerTask?.cancel(); curtainLowerTask = nil
        if !PrivacyCurtain.shared.isUp {
            PrivacyCurtain.shared.raise()
            curtainAutoRaised = true
        }
    }

    /// The compact viewer went away — but it may just be switching windows
    /// (which reconnects), so wait a beat before dropping the wall.
    private func compactSessionMaybeEnded() {
        guard curtainAutoRaised else { return }
        curtainLowerTask?.cancel()
        curtainLowerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.curtainAutoRaised else { return }
            self.curtainAutoRaised = false
            if PrivacyCurtain.shared.isUp { PrivacyCurtain.shared.lower() }
        }
    }

    /// A compact/open just resized `id` — if that's the window on air, restart
    /// capture so the encoder picks up the new size.
    func refreshStreamIfTargeting(_ id: CGWindowID) {
        guard id == streamWindowID else { return }
        streamer?.refitWindow()
    }

    /// Start/stop screen capture on demand — driven by whether anyone is viewing.
    func setScreenCapture(_ active: Bool) {
        if active && shareScreen {
            guard streamer == nil else { return }
            let s = ScreenStreamer(fps: streamFPS, maxWidth: streamMaxWidth,
                                   windowID: streamWindowID,
                                   publish: { [broadcaster] packet in broadcaster.publish(packet) })
            s.setExcludedWindows(PrivacyCurtain.shared.excludedWindowNumbers)
            s.start()
            streamer = s
            startAdaptation()
        } else {
            statsTimer?.invalidate(); statsTimer = nil
            streamer?.stop()
            streamer = nil
            // Last viewer left mid-compact-session (e.g. closed the app view).
            if streamWindowID != nil { compactSessionMaybeEnded() }
        }
    }

    /// Poll delivery stats every 2s and let the encoder adapt its bitrate to
    /// what the link is actually draining.
    private var statsTimer: Timer?
    private func startAdaptation() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let streamer = self.streamer else { return }
                let stats = self.broadcaster.takeStats()
                streamer.adapt(sent: stats.sent, dropped: stats.dropped)
            }
        }
    }

    /// Push the current curtain window set to the live streamer (if any).
    func applyCurtainExclusion() {
        streamer?.setExcludedWindows(PrivacyCurtain.shared.excludedWindowNumbers)
    }

    /// Requested stream frame rate (persists; applies live if capturing).
    private(set) var streamFPS: Int = 60
    func setStreamFPS(_ fps: Int) {
        let clamped = [30, 60, 120].contains(fps) ? fps : 60
        streamFPS = clamped
        streamer?.setFrameRate(clamped)
    }

    /// Requested capture width cap (persists; applies live if capturing).
    private(set) var streamMaxWidth: Int = 2560
    func setStreamMaxWidth(_ width: Int) {
        streamMaxWidth = max(640, min(4096, width))
        streamer?.setMaxWidth(streamMaxWidth)
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
