//
//  VirtualDisplayHost.swift
//  MacON
//
//  Stands up a private-API virtual display so a lid-closed Mac (no external
//  monitor) still has a real, capturable desktop. In clamshell the internal
//  panel is off at the hardware level and macOS drops it from the display list
//  — nothing in userspace can light it. So rather than fight that, we give
//  macOS a virtual surface to render onto; when it's the only display left it
//  becomes primary, the session (and the login window) relocate onto it, and
//  ScreenCaptureKit captures it exactly like a physical screen.
//
//  See MacON-Bridging-Header.h for the (private, reverse-engineered) API.
//

import Foundation
import CoreGraphics

@MainActor
final class VirtualDisplayHost {
    /// Identifiers we stamp on our virtual display so it can be recognized in
    /// the display list — even a just-torn-down one that still lingers there —
    /// and never mistaken for a real monitor.
    static let vendorID: UInt32 = 0x6D63    // "mc"
    static let productID: UInt32 = 0x4F4E   // "ON"

    /// Retaining the CGVirtualDisplay keeps the display alive; releasing it
    /// (setting nil) removes the display.
    private var display: CGVirtualDisplay?
    private(set) var displayID: CGDirectDisplayID?

    var isActive: Bool { display != nil }

    /// Create the virtual display at the given point size (default 1080p,
    /// HiDPI). No-op if one is already up. Returns its display ID, or nil if
    /// creation failed (e.g. the private API changed under us).
    @discardableResult
    func start(width: Int = 1920, height: Int = 1080, hiDPI: Bool = true) -> CGDirectDisplayID? {
        if let id = displayID { return id }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue(label: "com.karar.MacON.virtualdisplay")
        descriptor.name = "MacON Display"
        // Stable, arbitrary identifiers so macOS treats it as one consistent
        // display across create/destroy cycles.
        descriptor.vendorID = Self.vendorID
        descriptor.productID = Self.productID
        descriptor.serialNum = 0x0001
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        // Physical size at ~110 dpi so on-screen text is a sane size.
        let mmPerInch = 25.4, dpi = 110.0
        descriptor.sizeInMillimeters = CGSize(width: Double(width) / dpi * mmPerInch,
                                              height: Double(height) / dpi * mmPerInch)
        // sRGB primaries + D65 white — keeps captured colors correct.
        descriptor.redPrimary   = CGPoint(x: 0.640, y: 0.330)
        descriptor.greenPrimary = CGPoint(x: 0.300, y: 0.600)
        descriptor.bluePrimary  = CGPoint(x: 0.150, y: 0.060)
        descriptor.whitePoint   = CGPoint(x: 0.3127, y: 0.3290)
        descriptor.terminationHandler = {}

        let display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt32(width),
                                               height: UInt32(height),
                                               refreshRate: 60)]

        guard display.apply(settings) else {
            NSLog("MacOn: virtual display applySettings failed")
            return nil
        }
        self.display = display
        self.displayID = display.displayID
        makeMain(display.displayID)
        NSLog("MacOn: virtual display up — id \(display.displayID) (\(width)×\(height))")
        return display.displayID
    }

    /// Move the virtual display to the global origin (0,0), i.e. make it the
    /// *main* display. Without this, macOS keeps a lid-shut/asleep internal
    /// panel as main and renders the desktop + login window there — so the
    /// virtual display captures only blank/idle frames and the stream never
    /// starts. Making it main puts the actual UI onto the surface we capture.
    private func makeMain(_ id: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            NSLog("MacOn: begin display config failed — virtual display not promoted to main")
            return
        }
        CGConfigureDisplayOrigin(config, id, 0, 0)
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        NSLog("MacOn: promote virtual display to main → \(err == .success ? "ok" : "err \(err.rawValue)")")
    }

    /// Tear the virtual display back down (releasing the object removes it).
    func stop() {
        guard display != nil else { return }
        display = nil
        displayID = nil
        NSLog("MacOn: virtual display torn down")
    }
}
