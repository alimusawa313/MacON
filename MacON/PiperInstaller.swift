//
//  PiperInstaller.swift
//  MacON
//
//  One-click Piper setup for voice mode — no terminal. Downloads the official
//  Piper release for this Mac's CPU (github.com/rhasspy/piper) and an English
//  voice from the official voice repo (huggingface.co/rhasspy/piper-voices)
//  into ~/Library/Application Support/MacON/piper, unpacks, clears quarantine,
//  points PiperTTS at the result, and proves it speaks with a test synthesis.
//

import Foundation
import Observation

@MainActor
@Observable
final class PiperInstaller {

    enum Stage: Equatable {
        case idle
        case downloadingPiper      // the engine (~18 MB)
        case installing            // untar + permissions
        case downloadingVoice      // the .onnx voice (~63 MB)
        case testing               // prove a synthesis works
        case done
        case failed(String)
    }

    private(set) var stage: Stage = .idle
    /// 0…1 within the current download stage.
    private(set) var progress: Double = 0

    var busy: Bool {
        switch stage {
        case .downloadingPiper, .installing, .downloadingVoice, .testing: return true
        default: return false
        }
    }

    struct Fail: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Sources

    static let installDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacON/piper", isDirectory: true)

    #if arch(arm64)
    private static let archive = "piper_macos_aarch64.tar.gz"
    #else
    private static let archive = "piper_macos_x64.tar.gz"
    #endif
    private static let engineURL =
        URL(string: "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/\(archive)")!
    static let voiceName = "en_US-lessac-medium"
    private static let voiceBase =
        "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/lessac/medium/"

    // MARK: Install

    func install() {
        guard !busy else { return }
        Task { await run() }
    }

    private func run() async {
        do {
            let dir = Self.installDir
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // 1. The engine bundle: piper binary + espeak-ng data + dylibs,
            //    which all live side by side in the tarball's piper/ folder.
            stage = .downloadingPiper; progress = 0
            let tar = try await download(Self.engineURL)
            stage = .installing
            try await shell("/usr/bin/tar", "-xzf", tar.path, "-C", dir.path)
            try? FileManager.default.removeItem(at: tar)

            let binary = dir.appendingPathComponent("piper/piper")
            guard FileManager.default.fileExists(atPath: binary.path) else {
                throw Fail("The download didn't contain the piper binary.")
            }
            // tar preserves both from the archive, but belt-and-braces: the
            // exec bit must be set and a quarantined binary won't launch.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: binary.path)
            try? await shell("/usr/bin/xattr", "-dr", "com.apple.quarantine", dir.path)

            // 2. The voice: model + its .json config, side by side as piper expects.
            stage = .downloadingVoice; progress = 0
            let onnx = try await download(URL(string: Self.voiceBase + "\(Self.voiceName).onnx")!)
            let voice = dir.appendingPathComponent("\(Self.voiceName).onnx")
            try? FileManager.default.removeItem(at: voice)
            try FileManager.default.moveItem(at: onnx, to: voice)
            let json = try await download(URL(string: Self.voiceBase + "\(Self.voiceName).onnx.json")!)
            let config = dir.appendingPathComponent("\(Self.voiceName).onnx.json")
            try? FileManager.default.removeItem(at: config)
            try FileManager.default.moveItem(at: json, to: config)

            // 3. Point the TTS at it and prove it speaks.
            UserDefaults.standard.set(binary.path, forKey: PiperTTS.binaryKey)
            UserDefaults.standard.set(voice.path, forKey: PiperTTS.voiceKey)
            stage = .testing
            guard await PiperTTS.synthesize("Voice mode is ready.") != nil else {
                throw Fail("Piper installed but the test synthesis failed — try reinstalling.")
            }
            stage = .done
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    // MARK: Pieces

    /// Download with live progress; returns a temp file the caller moves.
    private func download(_ url: URL) async throws -> URL {
        let watch = ProgressWatch { [weak self] fraction in
            Task { @MainActor in self?.progress = fraction }
        }
        let (file, response) = try await URLSession.shared.download(from: url, delegate: watch)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Fail("Download failed (HTTP \(http.statusCode)) — \(url.lastPathComponent).")
        }
        // The async API's temp file can be reclaimed — claim it immediately.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("macon-dl-\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: file, to: kept)
        progress = 1
        return kept
    }

    private func shell(_ launch: String, _ args: String...) async throws {
        let arguments = args
        try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launch)
            p.arguments = arguments
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw Fail("\((launch as NSString).lastPathComponent) failed (status \(p.terminationStatus)).")
            }
        }.value
    }
}

/// Streams a download task's byte counts into a progress fraction. The async
/// download API handles the data itself; this only listens.
private final class ProgressWatch: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // Required by the protocol; the async download(from:) call owns the file.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {}
}
