//
//  ScreenStreamer.swift
//  MacON
//
//  Captures the main display with ScreenCaptureKit, downscales + JPEG-encodes
//  each frame, and drops it into a ScreenFrameBox for the companion server to
//  push to viewers. Capture only runs while someone is watching.
//
//  Needs the Screen Recording permission — macOS prompts on first capture.
//

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage
import MaconKit

final class ScreenStreamer: NSObject, SCStreamOutput, @unchecked Sendable {
    private let box: ScreenFrameBox
    private let sampleQueue = DispatchQueue(label: "macon.screencap")
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private var stream: SCStream?

    // Tuning: cap resolution, frame rate, and JPEG size for a smooth LAN feed.
    private let maxWidth = 1280
    private let jpegQuality: CGFloat = 0.5
    private let minInterval: TimeInterval = 0.1        // ~10 fps encode ceiling
    private var lastEmit = Date.distantPast

    init(box: ScreenFrameBox) { self.box = box }

    func start() { Task { await begin() } }

    private func begin() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingWindows: [])

            let config = SCStreamConfiguration()
            let scale = min(1.0, Double(maxWidth) / Double(display.width))
            config.width = Int(Double(display.width) * scale)
            config.height = Int(Double(display.height) * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 10)   // source-side 10 fps cap
            config.queueDepth = 3
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
        let s = stream
        stream = nil
        box.clear()
        Task { try? await s?.stopCapture() }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

        // Only push complete frames (ScreenCaptureKit also emits idle/blank ones).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= minInterval,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastEmit = now

        let image = CIImage(cvImageBuffer: pixels)
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): jpegQuality
        ]
        if let data = ci.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: options) {
            box.set(data)
        }
    }
}
