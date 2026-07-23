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
    /// Last authorized request per device (token prefix → time) — the fleet
    /// map's liveness. In memory only; resets with the app.
    @Published private(set) var deviceActivity: [String: Date] = [:]
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

    /// Let paired devices build & run Flows (visual automations that execute
    /// on this Mac). Off by default — flows can run shell commands and
    /// scripts, so it's the same trust level as Code.
    @Published var allowFlows: Bool {
        didSet { defaults.set(allowFlows, forKey: flowsKey) }
    }

    /// The tunnel process/state (UI observes through this manager).
    let tunnel = TunnelManager()

    private var service: CompanionService?
    private let store = PairingStore()
    private let broadcaster = ScreenBroadcaster()
    private var streamer: ScreenStreamer?
    /// A private-API virtual display, stood up on demand so a lid-closed Mac
    /// (no external monitor) still has a capturable desktop to stream + unlock.
    private let virtualDisplay = VirtualDisplayHost()
    /// Whether a device is currently viewing the screen.
    private var viewing = false
    /// The display we're capturing, so a display-arrangement change only
    /// restarts capture when the target actually moved (internal ↔ virtual).
    private var capturingDisplayID: CGDirectDisplayID = 0
    private let remote = RemoteControl()
    /// The dictate-to-drive agent. Lazily built so it captures `self` for the
    /// control gate. A task is remote control, so it rides the same toggle.
    private lazy var agent = AgentRunner(remote: remote, allowControl: { [weak self] in
        self?.allowControl ?? false
    })
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
    private let flowsKey = "companion.allowFlows"
    private static let unlockAccount = "companion.unlockPassword"
    private let ollama = OllamaService()
    private let terminal = TerminalBridge()
    /// Exposed so the Mac's own Flows editor drives the same store + engine
    /// the companion reaches over the network — one source of truth.
    let flowStore = FlowStore()
    let flowEngine: FlowEngine
    private let flowScheduler = FlowScheduler()
    /// Build-event push notifications to paired devices (exposed for Settings).
    let push = PushManager()
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
        allowFlows = defaults.bool(forKey: flowsKey)       // default off (runs commands)
        flowEngine = FlowEngine(store: flowStore)
        devices = store.deviceList()

        // Surface CloudLink's published state through this manager.
        cloudSink = cloud.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        // A wake/unlock command arriving over iCloud runs the same paths as HTTP.
        cloud.onCommand = { [weak self] kind in
            guard let self else { return }
            switch kind {
            case "wake":    if self.allowWake { self.power.wake(); Task { await self.power.forceDisplayOn() } }
            case "unlock":  if self.allowUnlock { _ = self.power.unlock(password: self.unlockPassword) }
            case "lock":    self.power.lock()
            case "privacy": if self.allowUnlock, !PrivacyCurtain.shared.isUp { PrivacyCurtain.shared.raise() }
            case "tunnel":  // device can't reach us — force a fresh tunnel URL
                if self.remoteEnabled { self.tunnel.refreshNow(); self.publishBeacon() }
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

        // Sleep drops the Cloudflare tunnel (and its edge connections); on wake
        // the old URL is usually dead. Relaunch a fresh tunnel and republish
        // the beacon so a paired device re-points itself over iCloud — no
        // manual "Change Address" dance.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverAfterWake() }
        }

        // React to the lid opening/closing (or a monitor coming/going) while a
        // device is viewing: create or drop the virtual display as needed and
        // re-target capture at whatever the main display now is.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDisplayChange() }
        }
    }

    /// Bring the tunnel back after the Mac wakes and re-announce over iCloud.
    private func recoverAfterWake() {
        guard isRunning else { return }
        if remoteEnabled { tunnel.refreshNow() }
        if iCloudEnabled { cloud.start() }
        // Publish now, and again shortly once the fresh tunnel URL has landed
        // (the tunnelSink also republishes the moment the URL changes).
        publishBeacon()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            self.publishBeacon()
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

    func start(runnerName: String, runners: @escaping () -> [PipelineRunner],
               pool: PipelinePool? = nil) {
        guard service == nil else { return }
        runnersProvider = runners
        defaults.set(port, forKey: portKey)
        defaults.set(true, forKey: enabledKey)
        // Every pipeline lifecycle moment becomes a push to paired devices.
        pool?.onBuildEvent = { [weak self] event in self?.push.fire(event) }
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
                    Task { await self.power.forceDisplayOn() }   // keep at it until the panel lights
                }
            },
            unlock: { [weak self] in
                await MainActor.run {
                    guard let self, self.allowUnlock else { return false }
                    return self.power.unlock(password: self.unlockPassword)
                }
            },
            privacy: { on in
                // Universal screen blocker — a paired, authed device can raise
                // or lower the curtain over the Mac's screen. Returns the state.
                await MainActor.run {
                    if on { if !PrivacyCurtain.shared.isUp { PrivacyCurtain.shared.raise() } }
                    else  { if PrivacyCurtain.shared.isUp { PrivacyCurtain.shared.lower() } }
                    return PrivacyCurtain.shared.isUp
                }
            },
            lock: { [weak self] in
                await MainActor.run { self?.power.lock() ?? false }
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
                },
                xcodeDestinations: { [weak self] in
                    guard await MainActor.run(body: { self?.allowCode ?? false }) else { return nil }
                    return await CodeAccess.xcodeDestinations()
                }),
            termOps: CompanionServer.TermOps(
                start: { [weak self] id, cwd, emit in
                    guard let self, await MainActor.run(body: { self.allowCode }) else { return false }
                    return self.terminal.start(id: id, cwd: cwd, emit: emit)
                },
                input: { [weak self] id, bytes in self?.terminal.input(id: id, bytes) },
                resize: { [weak self] id, cols, rows in self?.terminal.resize(id: id, cols: cols, rows: rows) },
                close: { [weak self] id in self?.terminal.close(id: id) }),
            flowOps: CompanionServer.FlowOps(
                list: { [weak self] in
                    guard let self, await MainActor.run(body: { self.allowFlows }) else { return nil }
                    return try? CompanionJSON.encoder.encode(FlowsListDTO(flows: self.flowStore.flows))
                },
                save: { [weak self] body in
                    guard let self, await MainActor.run(body: { self.allowFlows }),
                          let flow = try? CompanionJSON.decoder.decode(Flow.self, from: body)
                    else { return false }
                    self.flowStore.upsert(flow)
                    return true
                },
                remove: { [weak self] id in
                    guard let self, await MainActor.run(body: { self.allowFlows }) else { return false }
                    return self.flowStore.remove(id: id)
                },
                run: { [weak self] id, body in
                    guard let self, await MainActor.run(body: { self.allowFlows }),
                          let flow = self.flowStore.flow(id: id) else { return nil }
                    let req = (try? CompanionJSON.decoder.decode(FlowRunRequest.self, from: body))
                        ?? FlowRunRequest(payload: nil, key: nil, keys: nil)
                    let runId = await self.flowEngine.start(flow: flow, trigger: "manual",
                                                            payload: req.payload, keys: req.allKeys)
                    return try? CompanionJSON.encoder.encode(FlowRunStartDTO(runId: runId))
                },
                runs: { [weak self] id in
                    guard let self, await MainActor.run(body: { self.allowFlows }) else { return nil }
                    return try? CompanionJSON.encoder.encode(FlowRunsDTO(runs: self.flowStore.runs(flowId: id)))
                },
                runDetail: { [weak self] id in
                    guard let self, let run = await self.flowEngine.runDetail(id: id) else { return nil }
                    return try? CompanionJSON.encoder.encode(run)
                },
                cancel: { [weak self] id in
                    guard let self else { return false }
                    return await self.flowEngine.cancel(id: id)
                }),
            devices: { [weak self] in
                await MainActor.run {
                    guard let self else { return nil }
                    return try? CompanionJSON.encoder.encode(self.fleetSnapshot())
                }
            },
            apnsRegister: { [weak self] bearer, body in
                await MainActor.run { self?.push.register(bearer: bearer, body: body) ?? false }
            },
            agentOps: CompanionServer.AgentOps(
                start: { [weak self] req in
                    await MainActor.run { self?.agent.start(req) }
                },
                eventsSince: { [weak self] id, after in
                    await MainActor.run { self?.agent.eventsSince(id, after: after) ?? [] }
                },
                stop: { [weak self] id in
                    await MainActor.run { self?.agent.stop(id) ?? false }
                },
                decision: { [weak self] id, seq, approve in
                    await MainActor.run { self?.agent.decision(id, seq: seq, approve: approve) ?? false }
                }),
            onAuthorize: { [weak self] token in
                Task { @MainActor in self?.noteSeen(token) }
            },
            onLog: { _ in })
        svc.start()
        service = svc
        isRunning = true
        power.setKeepAwake(keepAwake)
        refreshDevices()
        if store.deviceCount == 0 { newCode() }
        syncTunnel()
        if iCloudEnabled { cloud.start(); publishBeacon() }
        // Time- and folder-based flow triggers tick while the server runs;
        // the gate re-checks the toggle so flipping it applies immediately.
        flowScheduler.start(store: flowStore, engine: flowEngine) { [weak self] in
            (self?.allowFlows ?? false) && (self?.isRunning ?? false)
        }
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
            broadcast: net.broadcast,
            privacyUp: PrivacyCurtain.shared.isUp)
    }

    private static let powerUnavailable = CompanionPowerDTO(
        locked: false, displayAsleep: false, keepAwake: false,
        canWake: false, canUnlock: false, mac: nil, broadcast: nil)

    func stop() {
        tunnel.stop()
        flowScheduler.stop()
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
        NSLog("MacOn: setScreenCapture(\(active)) shareScreen=\(shareScreen)")
        viewing = active && shareScreen
        if viewing {
            guard streamer == nil else { return }
            // If the lid's shut with no external monitor there's no display to
            // capture — stand up the virtual one first, and give macOS a beat to
            // bring it online before the streamer enumerates displays.
            let createdVirtual = ensureCaptureSurface()
            if createdVirtual {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    self.beginStreamer()
                }
            } else {
                beginStreamer()
            }
        } else {
            statsTimer?.invalidate(); statsTimer = nil
            streamer?.stop()
            streamer = nil
            capturingDisplayID = 0
            virtualDisplay.stop()
            // Last viewer left mid-compact-session (e.g. closed the app view).
            if streamWindowID != nil { compactSessionMaybeEnded() }
        }
    }

    /// Build + start the streamer against the current main display.
    private func beginStreamer() {
        guard viewing, streamer == nil else { return }
        logDisplayState("beginStreamer")
        let s = ScreenStreamer(fps: streamFPS, maxWidth: streamMaxWidth,
                               windowID: streamWindowID,
                               publish: { [broadcaster] packet in broadcaster.publish(packet) })
        s.setExcludedWindows(PrivacyCurtain.shared.excludedWindowNumbers)
        s.start()
        streamer = s
        capturingDisplayID = CGMainDisplayID()
        startAdaptation()
    }

    /// Is there a real, *drawable* display (not our virtual one, and not a
    /// lid-shut/asleep panel) we could capture? A lid-closed internal panel can
    /// linger in the display lists in an un-drawable state, so we check each
    /// online display's active + asleep flags rather than trusting the count —
    /// that stale panel is exactly when we need the virtual display instead.
    private func hasDrawablePhysicalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        let virtual = virtualDisplay.displayID
        return ids.prefix(Int(count)).contains {
            $0 != virtual && CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0
        }
    }

    /// Ensure there's *something* to capture while viewing: if the lid's shut
    /// with no external monitor (no drawable physical display), spin up the
    /// virtual display; tear it down once a real display returns. Returns true
    /// if it just created the virtual display (so the caller can let it settle).
    @discardableResult
    private func ensureCaptureSurface() -> Bool {
        guard viewing else { virtualDisplay.stop(); return false }
        let drawable = hasDrawablePhysicalDisplay()
        NSLog("MacOn: ensureCaptureSurface drawablePhysical=\(drawable) virtualActive=\(virtualDisplay.isActive)")
        if drawable {
            if virtualDisplay.isActive { virtualDisplay.stop() }
            return false
        }
        guard !virtualDisplay.isActive else { return false }
        let id = virtualDisplay.start()
        NSLog("MacOn: virtual display start → \(id.map(String.init) ?? "FAILED")")
        return id != nil
    }

    /// One-line dump of the current display arrangement + lock state — the
    /// ground truth for diagnosing why lid-closed capture produces no frames.
    private func logDisplayState(_ tag: String) {
        var n: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetOnlineDisplayList(n, &ids, &n)
        let desc = ids.prefix(Int(n)).map { id in
            "\(id)[active=\(CGDisplayIsActive(id) != 0) asleep=\(CGDisplayIsAsleep(id) != 0)"
            + (id == virtualDisplay.displayID ? " VIRTUAL]" : "]")
        }.joined(separator: ", ")
        NSLog("MacOn[\(tag)]: main=\(CGMainDisplayID()) locked=\(power.isLocked) displayAsleep=\(power.isDisplayAsleep) online=[\(desc)]")
    }

    /// The display arrangement changed (lid opened/closed, monitor plugged).
    /// Re-decide the capture surface and, if the main display actually moved,
    /// restart capture so it follows onto the new one.
    private func handleDisplayChange() {
        guard viewing else { return }
        ensureCaptureSurface()
        if CGMainDisplayID() != capturingDisplayID {
            capturingDisplayID = CGMainDisplayID()
            streamer?.recapture()
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

    // MARK: Fleet (device map)

    /// A device just made an authorized request. Throttled — the screen
    /// stream and poll loops would otherwise publish every few hundred ms.
    private func noteSeen(_ token: String) {
        let short = String(token.prefix(8))
        let last = deviceActivity[short] ?? .distantPast
        guard Date().timeIntervalSince(last) > 2 else { return }
        deviceActivity[short] = Date()
    }

    /// This Mac + every paired device with its liveness — the fleet map's
    /// data, served over /devices and read directly by the Mac's FleetView.
    func fleetSnapshot() -> FleetDevicesDTO {
        let now = Date()
        let list = store.deviceList().map { device -> FleetDeviceDTO in
            let seen = deviceActivity[device.tokenShort]
            let seconds = seen.map { Int(now.timeIntervalSince($0)) }
            return FleetDeviceDTO(
                name: device.name,
                kind: device.name.lowercased().contains("ipad") ? "ipad" : "iphone",
                seconds: seconds,
                live: (seconds ?? .max) < 15,
                short: device.tokenShort,
                pairedAt: device.pairedAt)
        }
        return FleetDevicesDTO(mac: host, devices: list)
    }

    /// Revoke by the fleet map's stable id (the token prefix).
    func revoke(short: String) {
        store.revoke(prefix: short)
        push.unregister(short: short)
        refreshDevices()
    }

    func revoke(_ device: PairingStore.Device) {
        store.revoke(prefix: device.token)
        push.unregister(short: device.tokenShort)
        refreshDevices()
    }
}
