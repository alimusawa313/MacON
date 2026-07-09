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

    private let maxWidth = 1920
    private let targetFPS: Int32 = 60          // encoder hint; capture allows up to 120

    private let keyframeLock = NSLock()
    private var pendingKeyframe = true         // first frame is always a keyframe

    init(publish: @escaping @Sendable (Data) -> Void) { self.publish = publish }

    func start() { Task { await begin() } }

    func forceKeyframe() {
        keyframeLock.lock(); pendingKeyframe = true; keyframeLock.unlock()
    }

    private func takeKeyframeRequest() -> Bool {
        keyframeLock.lock(); defer { pendingKeyframe = false; keyframeLock.unlock() }
        return pendingKeyframe
    }

    // MARK: Capture

    private func begin() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }
            let scale = min(1.0, Double(maxWidth) / Double(display.width))
            let w = Int(Double(display.width) * scale), h = Int(Double(display.height) * scale)

            setupEncoder(width: Int32(w), height: Int32(h))

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = w
            config.height = h
            config.minimumFrameInterval = CMTime(value: 1, timescale: 120)   // allow up to 120 fps
            config.queueDepth = 6
            config.showsCursor = true
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let s = SCStream(filter: filter, configuration: config, delegate: nil)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await s.startCapture()
            stream = s
        } catch {
            NSLog("MacOn: screen capture couldn't start — \(error.localizedDescription)")
        }
    }

    func stop() {
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        forceKeyframe()                     // next start begins with an IDR
    }

    // MARK: Encoder

    private func setupEncoder(width: Int32, height: Int32) {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        guard status == noErr, let session = s else { return }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: targetFPS as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 20_000_000 as CFNumber)
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
