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
