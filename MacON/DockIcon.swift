//
//  DockIcon.swift
//  MacON
//
//  The Dock icon in the active world's colors. macOS has no persistent
//  alternate-icon API, so the bundled icon (the original blue) is the face
//  in Finder, and this re-draws the SAME artwork — the original laptop and
//  power glyph from AppIcon.icon, geometry ported 1:1 — over the world's
//  gradient whenever the theme changes.
//

import AppKit

@MainActor
enum DockIcon {
    static func apply(_ theme: WorldTheme) {
        NSApp.applicationIconImage = draw(theme.palette)
    }

    private static func draw(_ box: WorldPalette) -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: true) { _ in
            // Standard macOS icon canvas: the tile floats inside margins
            // with a soft drop shadow.
            let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
            let squircle = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

            NSGraphicsContext.current?.cgContext.setShadow(
                offset: CGSize(width: 0, height: -12), blur: 36,
                color: NSColor.black.withAlphaComponent(0.35).cgColor)
            box.primaryDeep.setFill()
            squircle.fill()
            NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

            squircle.setClip()
            NSGradient(starting: box.primary, ending: box.primaryDeep)?
                .draw(in: squircle, angle: -90)

            // The original artwork lives in a 512 box, art shifted down 40 —
            // map that space onto the tile. (Coordinates below are the
            // original SVG's, +40 on y.)
            let s = tile.width / 512
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: tile.minX + x * s, y: tile.minY + y * s)
            }

            let body = box.cloud.withAlphaComponent(0.85)

            // Screen: the stroked rounded rect.
            let screen = NSBezierPath(
                roundedRect: NSRect(x: pt(62, 100).x, y: pt(62, 100).y,
                                    width: 388 * s, height: 250 * s),
                xRadius: 12 * s, yRadius: 12 * s)
            screen.lineWidth = 16 * s
            screen.lineJoinStyle = .round
            body.setStroke()
            screen.stroke()

            // Base: the solid bar with the trackpad dip.
            let base = NSBezierPath()
            base.move(to: pt(20, 378))
            base.line(to: pt(190, 378))
            base.curve(to: pt(200, 384), controlPoint1: pt(195, 378), controlPoint2: pt(198, 380))
            base.curve(to: pt(212, 390), controlPoint1: pt(202, 388), controlPoint2: pt(206, 390))
            base.line(to: pt(300, 390))
            base.curve(to: pt(312, 384), controlPoint1: pt(306, 390), controlPoint2: pt(310, 388))
            base.curve(to: pt(322, 378), controlPoint1: pt(314, 380), controlPoint2: pt(317, 378))
            base.line(to: pt(492, 378))
            base.curve(to: pt(460, 412), controlPoint1: pt(490, 398), controlPoint2: pt(478, 412))
            base.line(to: pt(52, 412))
            base.curve(to: pt(20, 378), controlPoint1: pt(34, 412), controlPoint2: pt(22, 398))
            base.close()
            base.lineWidth = 16 * s
            base.lineJoinStyle = .round
            body.setFill()
            base.fill()
            base.stroke()

            // Power glyph: IEC-style — ring with a tight top gap, stem
            // dropping through it past the ring's top.
            let glyph = NSBezierPath()
            glyph.lineWidth = 16 * s
            glyph.lineCapStyle = .round
            glyph.appendArc(withCenter: pt(256, 232), radius: 56 * s,
                            startAngle: -118, endAngle: -62, clockwise: true)
            glyph.move(to: pt(256, 156))
            glyph.line(to: pt(256, 238))
            NSColor.white.setStroke()
            glyph.stroke()
            return true
        }
    }
}
