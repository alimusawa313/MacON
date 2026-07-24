//
//  PiperTTS.swift
//  MacON
//
//  Text-to-speech for the live voice mode, using Piper — the free, open-source
//  neural TTS (github.com/rhasspy/piper). The binary + a voice model (.onnx)
//  live on the Mac (paths set in Settings → Voice); each reply is synthesized
//  to WAV and streamed to the device, which plays it. When Piper isn't set up,
//  /voice/tts answers 503 and the device speaks with its own system voice.
//

import Foundation

enum PiperTTS {
    static let binaryKey = "voice.piperPath"
    static let voiceKey = "voice.piperVoice"

    /// The piper binary: the configured path, the in-app install, or the
    /// usual manual install spots.
    static func binaryPath() -> String? {
        let configured = UserDefaults.standard.string(forKey: binaryKey) ?? ""
        let candidates = [configured,
                          PiperInstaller.installDir.appendingPathComponent("piper/piper").path,
                          "/opt/homebrew/bin/piper",
                          "/usr/local/bin/piper",
                          NSHomeDirectory() + "/.local/bin/piper",
                          NSHomeDirectory() + "/piper/piper"]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The voice model (.onnx): the configured path, or one found in the
    /// in-app install / next to the binary / in ~/piper (first .onnx wins).
    static func voicePath() -> String? {
        let configured = UserDefaults.standard.string(forKey: voiceKey) ?? ""
        if !configured.isEmpty, FileManager.default.fileExists(atPath: configured) { return configured }
        var dirs = [PiperInstaller.installDir.path, NSHomeDirectory() + "/piper"]
        if let bin = binaryPath() { dirs.insert((bin as NSString).deletingLastPathComponent, at: 0) }
        for dir in dirs {
            if let onnx = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
                .first(where: { $0.hasSuffix(".onnx") }) {
                return dir + "/" + onnx
            }
        }
        return nil
    }

    static var isAvailable: Bool { binaryPath() != nil && voicePath() != nil }

    /// Synthesize `text` → WAV bytes. Runs piper off the main thread; nil on
    /// any failure (missing setup, bad model, crash) so the route answers 503.
    static func synthesize(_ text: String) async -> Data? {
        guard let bin = binaryPath(), let voice = voicePath() else { return nil }
        let spoken = String(text.prefix(1200))          // keep replies speech-sized
        return await Task.detached(priority: .userInitiated) {
            run(binary: bin, voice: voice, text: spoken)
        }.value
    }

    private static func run(binary: String, voice: String, text: String) -> Data? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("macon-tts-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["--model", voice, "--output_file", out.path]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            stdin.fileHandleForWriting.write(Data(text.utf8))
            stdin.fileHandleForWriting.closeFile()
        } catch {
            return nil
        }

        // Piper synthesizes ~10× realtime; give long replies room, then bail.
        let deadline = Date().addingTimeInterval(30)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0,
              let wav = try? Data(contentsOf: out), wav.count > 44 else { return nil }
        return wav
    }
}
