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
import AppKit
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
    /// Keep the Mac awake (never idle-sleep) while the companion is running, so
    /// a paired device can always reach it.
    @Published var keepAwake: Bool {
        didSet {
            defaults.set(keepAwake, forKey: awakeKey)
            power.setKeepAwake(keepAwake && isRunning)
        }
    }
    /// Let paired devices wake this Mac's display remotely.
    @Published var allowWake: Bool {
        didSet { defaults.set(allowWake, forKey: wakeKey) }
    }
    /// Let paired devices unlock this Mac by typing the stored login password.
    @Published var allowUnlock: Bool {
        didSet {
            defaults.set(allowUnlock, forKey: unlockKey)
            if allowUnlock { power.requestPermission() }
        }
    }
    /// The login password used for remote unlock (Keychain-backed, never on disk).
    var unlockPassword: String {
        get { Keychain.get(account: Self.unlockAccount) }
        set { Keychain.set(newValue, account: Self.unlockAccount) }
    }
    var hasUnlockPassword: Bool { !unlockPassword.isEmpty }

    /// Whether the app is trusted for Accessibility — required to post the
    /// keystrokes/clicks that control and unlock rely on.
    var accessibilityTrusted: Bool { power.isTrusted }

    /// Register the app for Accessibility (shows the system prompt, which adds
    /// it to the list) and open the settings pane so it can be switched on.
    func requestAccessibility() {
        power.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Probe the local Ollama for the settings status line (model count, or nil
    /// if it isn't running).
    func probeOllama() async -> Int? { await ollama.probe() }

    /// Publish reachability + status to iCloud so a paired device re-points
    /// itself automatically (e.g. when the tunnel URL rotates), and can wake/
    /// unlock over iCloud. Off by default; dormant unless iCloud is provisioned.
    @Published var iCloudEnabled: Bool {
        didSet {
            defaults.set(iCloudEnabled, forKey: iCloudKey)
            if iCloudEnabled && isRunning { cloud.start(); publishBeacon() }
            else { cloud.stop() }
        }
    }
    var iCloudAvailable: Bool { cloud.available }
    var iCloudActive: Bool { cloud.active }
    var lastCloudPublish: Date? { cloud.lastPublish }

    /// Let paired devices chat with this Mac's local Ollama. Off by default:
    /// it exposes local models (and any files sent to them) to paired devices.
    @Published var allowAI: Bool {
        didSet { defaults.set(allowAI, forKey: aiKey) }
    }

    /// Let paired devices browse and edit files in the home folder (the
    /// companion's native Code editor). Off by default — it's file access.
    @Published var allowCode: Bool {
        didSet { defaults.set(allowCode, forKey: codeKey) }
    }

    /// The tunnel process/state (UI observes through this manager).
    let tunnel = TunnelManager()

    private var service: CompanionService?
    private let store = PairingStore()
    private let broadcaster = ScreenBroadcaster()
    private var streamer: ScreenStreamer?
    private let remote = RemoteControl()
    private let power = PowerManager()
    private let cloud = CloudLink()
    private var runnersProvider: (() -> [PipelineRunner])?
    private var cloudSink: AnyCancellable?
    private let defaults = UserDefaults.standard
    private let enabledKey = "companion.enabled"
    private let portKey = "companion.port"
    private let screenKey = "companion.shareScreen"
    private let controlKey = "companion.allowControl"
    private let remoteKey = "companion.remote"
    private let awakeKey = "companion.keepAwake"
    private let wakeKey = "companion.allowWake"
    private let unlockKey = "companion.allowUnlock"
    private let iCloudKey = "companion.iCloud"
    private let aiKey = "companion.allowAI"
    private let codeKey = "companion.allowCode"
    private static let unlockAccount = "companion.unlockPassword"
    private let ollama = OllamaService()
    private let terminal = TerminalBridge()
    private var tunnelSink: AnyCancellable?

    init() {
        port = defaults.object(forKey: portKey) as? Int ?? 8899
        shareScreen = defaults.object(forKey: screenKey) as? Bool ?? true
        allowControl = defaults.bool(forKey: controlKey)   // default off (sensitive)
        remoteEnabled = defaults.bool(forKey: remoteKey)
        keepAwake = defaults.object(forKey: awakeKey) as? Bool ?? true
        allowWake = defaults.object(forKey: wakeKey) as? Bool ?? true
        allowUnlock = defaults.bool(forKey: unlockKey)     // default off (sensitive)
        iCloudEnabled = defaults.bool(forKey: iCloudKey)   // default off
        allowAI = defaults.bool(forKey: aiKey)             // default off
        allowCode = defaults.bool(forKey: codeKey)         // default off (file access)
        devices = store.deviceList()

        // Surface CloudLink's published state through this manager.
        cloudSink = cloud.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        // A wake/unlock command arriving over iCloud runs the same paths as HTTP.
        cloud.onCommand = { [weak self] kind in
            guard let self else { return }
            switch kind {
            case "wake":    if self.allowWake { self.power.wake() }
            case "unlock":  if self.allowUnlock { _ = self.power.unlock(password: self.unlockPassword) }
            case "privacy": if self.allowUnlock, !PrivacyCurtain.shared.isUp { PrivacyCurtain.shared.raise() }
            default: break
            }
        }

        // Surface tunnel state changes through this manager's own publisher —
        // and re-publish the iCloud beacon so the device follows a new URL.
        tunnelSink = tunnel.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            Task { @MainActor in self?.publishBeacon() }
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
        runnersProvider = runners
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
            power: { [weak self] in
                await MainActor.run { self?.powerInfo() ?? Self.powerUnavailable }
            },
            wake: { [weak self] in
                await MainActor.run {
                    guard let self, self.allowWake else { return }
                    self.power.wake()
                }
            },
            unlock: { [weak self] in
                await MainActor.run {
                    guard let self, self.allowUnlock else { return false }
                    return self.power.unlock(password: self.unlockPassword)
                }
            },
            privacy: { [weak self] in
                await MainActor.run {
                    guard let self, self.allowUnlock else { return }
                    if !PrivacyCurtain.shared.isUp { PrivacyCurtain.shared.raise() }
                }
            },
            aiModels: { [weak self] in
                guard let self, await MainActor.run(body: { self.allowAI }) else { return nil }
                return await self.ollama.modelsData()
            },
            aiChat: { [weak self] body, emit in
                guard let self, await MainActor.run(body: { self.allowAI }) else {
                    var line = Data(#"{"error":"AI is turned off on the Mac."}"#.utf8)
                    line.append(0x0A); emit(line); return
                }
                await self.ollama.chat(body: body, emit: emit)
            },
            codeOps: CompanionServer.CodeOps(
                list: { [weak self] path in
                    guard await MainActor.run(body: { self?.allowCode ?? false }) else { return nil }
                    return CodeAccess.list(path)
                },
                read: { [weak self] path in
                    guard await MainActor.run(body: { self?.allowCode ?? false }) else { return nil }
                    return CodeAccess.read(path)
                },
                write: { [weak self] path, content in
                    guard await MainActor.run(body: { self?.allowCode ?? false }) else { return false }
                    return CodeAccess.write(path, content: content)
                },
                open: { [weak self] path in
                    guard await MainActor.run(body: { self?.allowCode ?? false }) else { return false }
                    return await MainActor.run { CodeAccess.openInEditor(path) }
                },
                xcodeProjects: { [weak self] in
                    guard await MainActor.run(body: { self?.allowCode ?? false }) else { return nil }
                    return await CodeAccess.xcodeProjects()
                },
                xcodeSchemes: { [weak self] path in
                    guard await MainActor.run(body: { self?.allowCode ?? false }) else { return nil }
                    return await CodeAccess.xcodeSchemes(path)
                }),
            termOps: CompanionServer.TermOps(
                start: { [weak self] id, cwd, emit in
                    guard let self, await MainActor.run(body: { self.allowCode }) else { return false }
                    return self.terminal.start(id: id, cwd: cwd, emit: emit)
                },
                input: { [weak self] id, bytes in self?.terminal.input(id: id, bytes) },
                resize: { [weak self] id, cols, rows in self?.terminal.resize(id: id, cols: cols, rows: rows) },
                close: { [weak self] id in self?.terminal.close(id: id) }),
            onLog: { _ in })
        svc.start()
        service = svc
        isRunning = true
        power.setKeepAwake(keepAwake)
        refreshDevices()
        if store.deviceCount == 0 { newCode() }
        syncTunnel()
        if iCloudEnabled { cloud.start(); publishBeacon() }
    }

    /// Snapshot the current address + status into the iCloud beacon, so a
    /// paired device auto-follows a rotated tunnel URL and can see us when the
    /// tunnel is down. Cheap and idempotent — safe to call on any change.
    func publishBeacon() {
        guard iCloudEnabled, isRunning else { return }
        let p = powerInfo()
        let pipelines = runnersProvider?() ?? []
        let running = pipelines.filter { $0.isBuilding }.count
        let failed = pipelines.filter { if case .failed = $0.buildState { return true }; return false }.count
        cloud.publish(CloudSchema.Beacon(
            name: host,
            tunnelURL: tunnel.publicURL,
            lanHost: address,
            secure: tunnel.publicURL != nil,
            locked: p.locked,
            displayAsleep: p.displayAsleep,
            keepAwake: p.keepAwake,
            running: running,
            failed: failed,
            mac: p.mac,
            broadcast: p.broadcast))
    }

    /// Snapshot of this Mac's power/reachability state for `GET /power`.
    private func powerInfo() -> CompanionPowerDTO {
        let net = PowerManager.networkIdentity()
        return CompanionPowerDTO(
            locked: power.isLocked,
            displayAsleep: power.isDisplayAsleep,
            keepAwake: power.keepAwake,
            canWake: allowWake,
            canUnlock: allowUnlock && hasUnlockPassword,
            mac: net.mac,
            broadcast: net.broadcast)
    }

    private static let powerUnavailable = CompanionPowerDTO(
        locked: false, displayAsleep: false, keepAwake: false,
        canWake: false, canUnlock: false, mac: nil, broadcast: nil)

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
        power.setKeepAwake(false)
        cloud.stop()
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
