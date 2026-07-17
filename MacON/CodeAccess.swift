//
//  CodeAccess.swift
//  MacON
//
//  File access behind the companion's native Code editor: browse folders,
//  read and write text files, and hand a path to VS Code on this Mac. The
//  device edits through our API with no video stream in the loop; VS Code
//  watches the filesystem, so both sides stay in sync.
//
//  Confined to the user's home directory — every path is expanded,
//  standardized, and symlink-resolved before it's touched.
//

import Foundation
import AppKit
import MaconKit

enum CodeAccess {

    /// Files above this aren't sent to the phone (it's an editor, not scp).
    private static let maxFileBytes = 1_500_000

    // MARK: Paths

    /// Expand `~`, standardize, resolve symlinks, and require the result to
    /// stay inside the home directory. Nil = refused.
    private static func sanitize(_ raw: String) -> URL? {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path == home || url.path.hasPrefix(home + "/") else { return nil }
        return url
    }

    /// Home-relative display path ("~/Projects/App") for stable client paths.
    private static func tilde(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    // MARK: Ops

    /// Directory listing: folders first, then files, alphabetical; hidden
    /// entries skipped.
    static func list(_ raw: String) -> CompanionCodeListDTO? {
        guard let dir = sanitize(raw) else { return nil }
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }

        let entries = names.compactMap { url -> CompanionCodeEntryDTO? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = values?.isDirectory ?? false
            return CompanionCodeEntryDTO(name: url.lastPathComponent,
                                         path: tilde(url),
                                         dir: isDir,
                                         size: Int64(values?.fileSize ?? 0))
        }
        .sorted {
            if $0.dir != $1.dir { return $0.dir }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return CompanionCodeListDTO(path: tilde(dir), entries: entries)
    }

    /// Read a UTF-8 text file. Nil = missing, too big, or not text (→ 415).
    static func read(_ raw: String) -> CompanionCodeFileDTO? {
        guard let url = sanitize(raw),
              let data = try? Data(contentsOf: url),
              data.count <= maxFileBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return CompanionCodeFileDTO(path: tilde(url), content: text)
    }

    /// Write a text file back (atomic). Only overwrites existing files —
    /// the editor edits, it doesn't create.
    static func write(_ raw: String, content: String) -> Bool {
        guard let url = sanitize(raw),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: Xcode

    /// Xcode projects/workspaces under home, via Spotlight (fast, no walk).
    /// Workspaces first, then projects; DerivedData and package checkouts
    /// filtered out.
    static func xcodeProjects() async -> CompanionCodeListDTO {
        let query = "kMDItemFSName == '*.xcodeproj' || kMDItemFSName == '*.xcworkspace'"
        let output = await runTool("/usr/bin/mdfind", [query], timeout: 10) ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let paths: [String] = output.split(separator: "\n").map(String.init)
        let kept: [String] = paths.filter { path in
            guard path.hasPrefix(home + "/") else { return false }
            if path.contains("/DerivedData/") { return false }
            if path.contains("/checkouts/") { return false }
            if path.contains("/.build/") { return false }
            if path.contains("/Carthage/") { return false }
            if path.contains(".xcodeproj/") { return false }   // project.xcworkspace inside a project
            return true
        }
        // Spotlight can be off or unindexed — fall back to a shallow walk.
        let found = kept.isEmpty ? scanForProjects(home: home) : Array(kept.prefix(50))

        var entries: [CompanionCodeEntryDTO] = []
        for path in found.prefix(50) {
            let name = (path as NSString).lastPathComponent
            let tilde = "~" + String(path.dropFirst(home.count))
            let isWorkspace = (path as NSString).pathExtension == "xcworkspace"
            entries.append(CompanionCodeEntryDTO(name: name, path: tilde,
                                                 dir: isWorkspace,   // dir ⇒ workspace
                                                 size: 0))
        }
        entries.sort {
            if $0.dir != $1.dir { return $0.dir }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return CompanionCodeListDTO(path: "~", entries: entries)
    }

    /// Breadth-first search for project bundles when Spotlight has nothing:
    /// depth- and breadth-capped, skipping hidden and known-heavy folders.
    private static func scanForProjects(home: String) -> [String] {
        let skip: Set<String> = ["Library", "Music", "Movies", "Pictures", "Applications",
                                 "node_modules", "Pods", "DerivedData", "Carthage",
                                 ".build", "build", ".git", ".Trash"]
        var queue: [(path: String, depth: Int)] = [(home, 0)]
        var results: [String] = []
        var visited = 0
        let fm = FileManager.default

        while !queue.isEmpty, results.count < 50, visited < 1500 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where !name.hasPrefix(".") {
                let full = dir + "/" + name
                let ext = (name as NSString).pathExtension
                if ext == "xcodeproj" || ext == "xcworkspace" {
                    if !full.contains(".xcodeproj/") { results.append(full) }
                    continue
                }
                if depth < 4, !skip.contains(name),
                   (try? fm.attributesOfItem(atPath: full)[.type] as? FileAttributeType) == .typeDirectory {
                    queue.append((full, depth + 1))
                }
            }
        }
        return results
    }

    /// The schemes of a project/workspace, via `xcodebuild -list -json`.
    static func xcodeSchemes(_ raw: String) async -> CompanionListDTO? {
        guard let url = sanitize(raw) else { return nil }
        let flag = url.pathExtension == "xcworkspace" ? "-workspace" : "-project"
        guard let output = await runTool("/usr/bin/xcodebuild",
                                         ["-list", "-json", flag, url.path],
                                         timeout: 30),
              let data = output.data(using: .utf8) else { return nil }

        struct Listing: Decodable {
            struct Box: Decodable { let schemes: [String]? }
            let project: Box?
            let workspace: Box?
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return nil }
        return CompanionListDTO(values: listing.project?.schemes ?? listing.workspace?.schemes ?? [])
    }

    /// Run a CLI tool and capture stdout (nil on failure/timeout).
    private static func runTool(_ path: String, _ args: [String],
                                timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            let done = NSLock()
            var finished = false
            func finish(_ value: String?) {
                done.lock(); defer { done.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }

            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                finish(String(data: data, encoding: .utf8))
            }
            do { try process.run() } catch { finish(nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
                finish(nil)
            }
        }
    }

    /// Open the path in VS Code on this Mac (falls back to the default app).
    static func openInEditor(_ raw: String) -> Bool {
        guard let url = sanitize(raw) else { return false }
        let vscode = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        if FileManager.default.fileExists(atPath: vscode.path) {
            NSWorkspace.shared.open([url], withApplicationAt: vscode,
                                    configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return NSWorkspace.shared.open(url)
    }
}
