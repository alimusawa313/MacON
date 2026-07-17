//
//  TerminalBridge.swift
//  MacON
//
//  Real shell sessions for the companion's Code terminal: each WebSocket gets
//  its own PTY running the user's login shell (zsh -il), so the phone types
//  into an actual terminal on this Mac — prompt, colors, history and all.
//  Output bytes stream back through the session's emit sink.
//

import Foundation
import Darwin
import MaconKit

final class TerminalBridge: @unchecked Sendable {

    private struct Session {
        let process: Process
        let master: FileHandle
        let masterFD: Int32
    }

    private var sessions: [String: Session] = [:]
    private let lock = NSLock()

    /// Spawn a login shell on a fresh PTY, rooted at `cwd` (home-confined;
    /// falls back to home). Output bytes flow to `emit` as they appear.
    func start(id: String, cwd: String?, emit: @escaping @Sendable (Data) -> Void) -> Bool {
        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else { return false }

        let master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-il"]                      // interactive login shell
        shell.standardInput = slave
        shell.standardOutput = slave
        shell.standardError = slave
        shell.currentDirectoryURL = Self.workingDirectory(cwd)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        shell.environment = env

        // PTY output → the WebSocket, as it arrives.
        master.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            emit(data)
        }

        shell.terminationHandler = { [weak self] _ in
            emit(Data("\r\n[session ended]\r\n".utf8))
            self?.close(id: id)
        }

        do { try shell.run() } catch {
            master.readabilityHandler = nil
            return false
        }
        // The child owns the slave now; keeping it open would hold the PTY
        // alive past the shell's exit.
        try? slave.close()

        lock.lock()
        sessions[id] = Session(process: shell, master: master, masterFD: masterFD)
        lock.unlock()
        return true
    }

    func input(id: String, _ bytes: Data) {
        lock.lock(); let session = sessions[id]; lock.unlock()
        session?.master.write(bytes)
    }

    func resize(id: String, cols: Int, rows: Int) {
        lock.lock(); let session = sessions[id]; lock.unlock()
        guard let session else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols),
                           ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(session.masterFD, TIOCSWINSZ, &size)
    }

    func close(id: String) {
        lock.lock()
        let session = sessions.removeValue(forKey: id)
        lock.unlock()
        guard let session else { return }
        session.master.readabilityHandler = nil
        if session.process.isRunning { session.process.terminate() }
    }

    /// Sanitize the requested working directory the same way CodeAccess does:
    /// expand, standardize, resolve, and require it to stay under home.
    private static func workingDirectory(_ raw: String?) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let raw, !raw.isEmpty else { return home }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path == homePath || url.path.hasPrefix(homePath + "/"),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { return home }
        return url
    }
}
