//
//  AppCatalog.swift
//  MacON
//
//  Installed-app list *with icons* for the companion's shortcut deck. Icons
//  need AppKit (NSWorkspace), which MaconKit avoids — so this lives in the app
//  and is handed to the companion server as its app provider.
//

import AppKit
import MaconKit

enum AppCatalog {
    /// Enumerate apps and render each icon to a small base64 PNG. Called off the
    /// main thread by the server; these AppKit calls are safe there.
    static func list() -> CompanionAppsDTO {
        let base = InstalledApps.list()   // Foundation enumeration (name + path)
        let apps = base.map { app in
            CompanionAppDTO(name: app.name, path: app.path, icon: iconBase64(app.path))
        }
        return CompanionAppsDTO(apps: apps)
    }

    private static func iconBase64(_ path: String, px: CGFloat = 128) -> String? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        let size = NSSize(width: px, height: px)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])?.base64EncodedString()
    }
}
