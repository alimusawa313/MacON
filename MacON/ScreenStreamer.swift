//
//  ScreenStreamer.swift
//  MacON
//
//  Captures the main display with ScreenCaptureKit and hardware-encodes it to
//  H.264 with VideoToolbox, then publishes each encoded packet to the companion
//  broadcaster. H.264's inter-frame compression keeps 60–120 fps within LAN
//  bandwidth (vs. sending whole JPEGs).
//
//  Wire packet (big-endian lengths):
//    [1] flags            bit0 = keyframe
//    if keyframe:
//      [1] paramSetCount (=2)
//      [2] spsLen [sps] [2] ppsLen [pps]
//    [4] sampleLen [AVCC sample data]
//
//  Needs Screen Recording permission — macOS prompts on first capture.
//

import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreVideo
import MaconKit

final class ScreenStreamer: NSObject, SCStreamOutput, @unchecked Sendable {
    private let publish: @Sendable (Data) -> Void
    private let sampleQueue = DispatchQueue(label: "macon.screencap")
    private var stream: SCStream?
    private var session: VTCompressionSession?

    private var maxWidth: Int                   // cap on the captured native-pixel width
    private var fps: Int                        // target frame rate (30 / 60 / 120)
    private var config: SCStreamConfiguration?  // kept so fps can be changed live
    private var windowID: CGWindowID?           // CompactOS: capture one window, not the display

    // Adaptive bitrate: start mid-ladder, ramp toward max on a clean link,
    // back off fast when the server reports drops.
    private var bitrate = 25_000_000
    private let minBitrate = 4_000_000
    private let maxBitrate = 45_000_000
    private var cleanWindows = 0
    private var throttled = false      // fps temporarily halved under heavy congestion

    private let keyframeLock = NSLock()
    private var pendingKeyframe = true         // first frame is always a keyframe

    private let exclLock = NSLock()
    private var excludedIDs: [CGWindowID] = []  // windows kept OUT of the capture (e.g. privacy curtain)
    private var display: SCDisplay?             // remembered so the filter can be rebuilt live

    init(fps: Int = 60, maxWidth: Int = 2560, windowID: CGWindowID? = nil,
         publish: @escaping @Sendable (Data) -> Void) {
        self.fps = fps
        self.maxWidth = maxWidth
        self.windowID = windowID
        self.publish = publish
    }

    /// Change the capture + encoder frame rate on the fly (user preference).
    func setFrameRate(_ newFPS: Int) {
        fps = newFPS
        throttled = false
        applyFrameRate(newFPS)
    }

    private func applyFrameRate(_ newFPS: Int) {
        if let session {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: newFPS as CFNumber)
        }
        if let config, let stream {
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(newFPS))
            stream.updateConfiguration(config) { _ in }
        }
    }

    /// One adaptation window from the broadcaster's delivery stats. Congested →
    /// cut bitrate 40% immediately (and halve fps if it's severe); clean for 3
    /// consecutive windows → step back up.
    func adapt(sent: Int, dropped: Int) {
        let total = sent + dropped
        guard total > 0 else { return }
        let dropRate = Double(dropped) / Double(total)
        if dropRate > 0.08 {
            cleanWindows = 0
            let next = max(minBitrate, Int(Double(bitrate) * 0.6))
            if next != bitrate {
                bitrate = next
                applyBitrate()
                NSLog("MacOn: link congested (%.0f%% dropped) — bitrate → %d Mbps",
                      dropRate * 100, bitrate / 1_000_000)
            }
            // Severe congestion: fewer, better frames beat a drop/resync storm.
            if dropRate > 0.25, !throttled, fps > 30 {
                throttled = true
                applyFrameRate(30)
            }
        } else if dropRate < 0.02 {
            cleanWindows += 1
            if throttled, cleanWindows >= 2 {
                throttled = false
                applyFrameRate(fps)                       // restore user preference
            }
            if cleanWindows >= 3, bitrate < maxBitrate {
                cleanWindows = 0
                bitrate = min(maxBitrate, Int(Double(bitrate) * 1.3))
                applyBitrate()
            }
        } else {
            cleanWindows = 0
        }
    }

    private func applyBitrate() {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: bitrate as CFNumber)
        // Burst cap: 2× average over 1s. Full-screen motion (Mission Control)
        // legitimately needs short bursts — cap it loosely so quality doesn't
        // crater, while still bounding runaway spikes.
        let limits: [Int] = [Int(Double(bitrate) * 2.0 / 8), 1]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: limits as CFArray)
    }

    /// Change the capture resolution cap — restarts capture at the new size
    /// (the encoder's dimensions are fixed at creation, so it must be rebuilt).
    func setMaxWidth(_ newWidth: Int) {
        guard newWidth != maxWidth else { return }
        maxWidth = newWidth
        restart()
    }

    /// Retarget the capture at a single window (CompactOS) or back to the whole
    /// display (nil) — restarts capture, since the encoder's size changes.
    func setWindowTarget(_ id: CGWindowID?) {
        guard id != windowID else { return }
        windowID = id
        restart()
    }

    /// The targeted window was just resized (device rotated, keyboard opened…):
    /// rebuild capture + encoder at its new size. The viewer's connection stays
    /// up — it simply receives a keyframe with the new dimensions.
    func refitWindow() {
        guard windowID != nil else { return }
        restart()
    }

    /// Tear down the stream + encoder and start over with current settings.
    private func restart() {
        let old = stream
        stream = nil; config = nil
        Task { try? await old?.stopCapture() }
        if let session { VTCompressionSessionInvalidate(session); self.session = nil }
        pendingKeyframe = true
        Task { await begin() }
    }

    /// Set which windows to exclude from the capture. Applies live if running.
    func setExcludedWindows(_ ids: [CGWindowID]) {
        exclLock.lock(); excludedIDs = ids; exclLock.unlock()
        if stream != nil { Task { await refreshFilter() } }
    }

    private func currentExcludedIDs() -> [CGWindowID] {
        exclLock.lock(); defer { exclLock.unlock() }; return excludedIDs
    }

    /// Rebuild the content filter (e.g. after the excluded-window set changed).
    /// Display capture only — a window capture can't show the curtain anyway.
    private func refreshFilter() async {
        guard windowID == nil else { return }
        guard let stream, let display else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let ids = currentExcludedIDs()
            let excluded = content.windows.filter { ids.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            try await stream.updateContentFilter(filter)
            forceKeyframe()
        } catch {
            NSLog("MacOn: couldn't update capture filter — \(error.localizedDescription)")
        }
    }

    func start() { Task { await begin() } }

    /// Re-run capture from scratch — used when the display arrangement changes
    /// (e.g. the lid closed and macOS switched the desktop onto the virtual
    /// display) so we re-target whatever the main display now is.
    func recapture() { restart() }

    func forceKeyframe() {
        keyframeLock.lock(); pendingKeyframe = true; keyframeLock.unlock()
    }

    private func takeKeyframeRequest() -> Bool {
        keyframeLock.lock(); defer { pendingKeyframe = false; keyframeLock.unlock() }
        return pendingKeyframe
    }

    // MARK: Capture

    private func begin() async {
        loggedFirstFrame = false
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            // Capture the *main* display (menu-bar screen), not just the first
            // one enumerated. When the lid is shut and the desktop lives on the
            // MacON virtual display, that virtual display is main — so this
            // targets it automatically, and targets the built-in panel when the
            // lid is open, with no special-casing.
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else {
                NSLog("MacOn: capture found NO displays in SCShareableContent")
                return
            }
            self.display = display
            NSLog("MacOn: capture target display \(display.displayID) (\(content.displays.count) available, main=\(CGMainDisplayID()))")

            // Capture at native (Retina) pixels, not points, so text stays crisp —
            // SCDisplay.width is in points; the real backing store is larger.
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let pxW = mode?.pixelWidth ?? display.width
            let pxH = mode?.pixelHeight ?? display.height

            let filter: SCContentFilter
            var w: Int, h: Int
            if let targetID = windowID,
               let window = content.windows.first(where: { $0.windowID == targetID }) {
                // CompactOS: capture just this window, at the display's Retina
                // scale, so a phone-sized window streams sharp phone-sized text.
                let retina = Double(pxW) / Double(display.width)
                let scale = min(1.0, Double(maxWidth) / (window.frame.width * retina))
                w = Int((window.frame.width * retina * scale).rounded())
                h = Int((window.frame.height * retina * scale).rounded())
                filter = SCContentFilter(desktopIndependentWindow: window)
            } else {
                let scale = min(1.0, Double(maxWidth) / Double(pxW))
                w = Int((Double(pxW) * scale).rounded())
                h = Int((Double(pxH) * scale).rounded())
                let excludedIDs = currentExcludedIDs()
                let excludedWindows = content.windows.filter { excludedIDs.contains($0.windowID) }
                filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            }
            w -= w % 2; h -= h % 2                       // encoders want even dimensions

            setupEncoder(width: Int32(w), height: Int32(h))

            let config = SCStreamConfiguration()
            config.width = w
            config.height = h
            if windowID != nil { config.includeChildWindows = true }   // sheets, popovers
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            // Minimize capture-side buffering: this is a live control stream, so
            // dropping a frame under load is invisible but a queued frame is felt
            // as lag. Each buffered frame adds ~1/fps of latency before the
            // encoder even sees it — at 60fps a depth of 5 baked in ~83ms; 2
            // keeps the encoder fed without the backlog.
            config.queueDepth = 2
            config.showsCursor = true
            // Capture straight into the encoder's native 4:2:0 YUV. With BGRA,
            // VideoToolbox color-converted every frame on the CPU — at 60fps
            // Retina sizes that alone pinned a couple of cores.
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.captureResolution = .best                                 // highest fidelity
            config.colorSpaceName = CGColorSpace.sRGB                        // keep screen colors
            self.config = config

            let s = SCStream(filter: filter, configuration: config, delegate: nil)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await s.startCapture()
            stream = s
            NSLog("MacOn: screen capture started (\(w)×\(h))")
        } catch {
            NSLog("MacOn: screen capture couldn't start — \(error.localizedDescription)")
        }
    }

    /// Log the first frame that actually reaches the encoder after a (re)start —
    /// the signal that capture is truly producing pixels, not just "started".
    private var loggedFirstFrame = false

    func stop() {
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        forceKeyframe()                     // next start begins with an IDR
    }

    // MARK: Encoder

    private func setupEncoder(width: Int32, height: Int32) {
        // Insist on the hardware encoder — a silent software fallback would
        // burn CPU at 60fps. If this Mac somehow has none, retry without the
        // requirement rather than not streaming at all.
        let hardware = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue!] as CFDictionary
        var s: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: hardware, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        if status != noErr {
            status = VTCompressionSessionCreate(
                allocator: nil, width: width, height: height,
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &s)
        }
        guard status == noErr, let session = s else { return }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [Int(Double(bitrate) * 2.0 / 8), 1] as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.85 as CFNumber)

        // Tag the stream BT.709 so the decoder reproduces colors correctly.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer), let session else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if !loggedFirstFrame {
            loggedFirstFrame = true
            NSLog("MacOn: first complete capture frame reached the encoder")
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let props: CFDictionary? = takeKeyframeRequest()
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: kCFBooleanTrue!] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            self?.emit(sample)
        }
    }

    // MARK: Packetize

    private func emit(_ sample: CMSampleBuffer) {
        if let packet = ScreenPacket.encode(from: sample) { publish(packet) }
    }
}
