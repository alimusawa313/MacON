//
//  WorldScene.swift
//  MacON
//
//  The companion's clay 3D world, on the Mac: a puffy extruded title you can
//  grab and spin, and a floating clay machine that reflects real build state
//  — the count of watched pipelines with the CI gear over its shoulder and a
//  ✓/! seal — re-modeled per world skin (monsters, cosmos, blocks, balloon,
//  dessert). Also renders the one-frame previews for the world picker.
//

import SwiftUI
import SceneKit
import AppKit

// MARK: - Live stage (welcome pane)

/// The 3D stage: title + state-reactive machine, painted with the active
/// world. The title zone claims mouse drags for spinning; everywhere else
/// stays inert.
struct WorldStage: NSViewRepresentable {
    enum Mood: String { case calm, busy, alert }

    let title: String
    let figure: String
    let mood: Mood
    let dark: Bool
    let theme: WorldTheme

    private var cacheKey: String { "\(title)|\(figure)|\(mood.rawValue)|\(dark)|\(theme.rawValue)" }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var key = ""
        weak var view: SCNView?
        private var baseYaw: CGFloat = 0

        private var titleNode: SCNNode? {
            view?.scene?.rootNode.childNode(withName: "title", recursively: true)
        }
        private var tiltNode: SCNNode? {
            view?.scene?.rootNode.childNode(withName: "titleTilt", recursively: true)
        }

        @objc func pan(_ gesture: NSPanGestureRecognizer) {
            guard let view, let title = titleNode else { return }
            switch gesture.state {
            case .began:
                title.removeAction(forKey: "spin")
                baseYaw = title.eulerAngles.y
            case .changed:
                let t = gesture.translation(in: view)
                title.eulerAngles.y = baseYaw + t.x * 0.02
                // AppKit's y grows upward — invert so dragging down tips it back.
                tiltNode?.eulerAngles.x = max(-0.5, min(0.5, 0.03 - t.y * 0.008))
            case .ended, .cancelled:
                let velocity = gesture.velocity(in: view)
                let spin = SCNAction.rotateBy(x: 0, y: velocity.x * 0.0035, z: 0, duration: 1.4)
                spin.timingMode = .easeOut
                let home = SCNAction.rotateTo(x: 0, y: -0.14, z: 0,
                                              duration: 0.7, usesShortestUnitArc: true)
                home.timingMode = .easeInEaseOut
                title.runAction(.sequence([spin, home]), forKey: "spin")
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.5
                tiltNode?.eulerAngles.x = 0.03
                SCNTransaction.commit()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gesture: NSGestureRecognizer) -> Bool {
            guard let view else { return false }
            // Title lives at the top; AppKit's origin is bottom-left.
            return gesture.location(in: view).y > view.bounds.height * 0.68
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.scene = WorldScene.build(title: title, figure: figure,
                                      mood: mood, dark: dark, theme: theme)
        context.coordinator.key = cacheKey
        context.coordinator.view = view

        let pan = NSPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard context.coordinator.key != cacheKey else { return }
        context.coordinator.key = cacheKey
        view.scene = WorldScene.build(title: title, figure: figure,
                                      mood: mood, dark: dark, theme: theme)
    }
}

// MARK: - Fleet stage (fleet teaser)

/// The Fleet teaser's 3D stage: the "Fleet" title over a rack of Macs, fully
/// interactive — a drag anywhere spins the rack, a drag in the title zone
/// spins the title. Same clay world as the welcome stage.
struct FleetStage: NSViewRepresentable {
    let dark: Bool
    let theme: WorldTheme

    private var cacheKey: String { "\(dark)|\(theme.rawValue)" }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        weak var view: SCNView?
        private var baseYaw: CGFloat = 0
        private var basePitch: CGFloat = 0
        private weak var target: SCNNode?     // what this drag is spinning
        private weak var pitchNode: SCNNode?  // where the tilt lives
        private var restYaw: CGFloat = 0
        private var restPitch: CGFloat = 0

        private func node(_ name: String) -> SCNNode? {
            view?.scene?.rootNode.childNode(withName: name, recursively: true)
        }

        @objc func pan(_ gesture: NSPanGestureRecognizer) {
            guard let view else { return }
            switch gesture.state {
            case .began:
                // AppKit's origin is bottom-left; the title sits at the top.
                let inTitle = gesture.location(in: view).y > view.bounds.height * 0.68
                if inTitle, let title = node("title") {
                    target = title; pitchNode = node("titleTilt")
                    restYaw = -0.14; restPitch = 0.03
                } else if let hero = node("hero") {
                    target = hero; pitchNode = hero
                    restYaw = 0; restPitch = 0
                } else {
                    target = nil; return
                }
                // Cancel only a previous fling — never the idle float/sway.
                target?.removeAction(forKey: "userSpin")
                baseYaw = target?.eulerAngles.y ?? 0
                basePitch = pitchNode?.eulerAngles.x ?? 0
            case .changed:
                guard let target else { return }
                let t = gesture.translation(in: view)
                target.eulerAngles.y = baseYaw + t.x * 0.02
                // AppKit's y grows upward — invert so dragging down tips it back.
                pitchNode?.eulerAngles.x = max(-0.6, min(0.6, basePitch - t.y * 0.008))
            case .ended, .cancelled:
                guard let target else { return }
                let velocity = gesture.velocity(in: view)
                let spin = SCNAction.rotateBy(x: 0, y: velocity.x * 0.0035, z: 0, duration: 1.4)
                spin.timingMode = .easeOut
                let home = SCNAction.rotateTo(x: 0, y: restYaw, z: 0,
                                              duration: 0.7, usesShortestUnitArc: true)
                home.timingMode = .easeInEaseOut
                target.runAction(.sequence([spin, home]), forKey: "userSpin")
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.5
                pitchNode?.eulerAngles.x = restPitch
                SCNTransaction.commit()
                self.target = nil
            default:
                break
            }
        }

        // The whole stage is grabbable.
        func gestureRecognizerShouldBegin(_ gesture: NSGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.scene = WorldScene.buildFleet(dark: dark, theme: theme)
        context.coordinator.view = view

        let pan = NSPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let key = cacheKey
        guard view.accessibilityLabel() != key else { return }
        view.setAccessibilityLabel(key)
        view.scene = WorldScene.buildFleet(dark: dark, theme: theme)
    }
}

// MARK: - Sprite (privacy curtain)

/// One floating clay piece — the world's signature model (gear, blob, brick
/// tower, balloon, donut, planet), tightly framed and gesture-free — the
/// privacy curtain sends it wandering around the screen.
struct WorldSprite: NSViewRepresentable {
    let dark: Bool
    let theme: WorldTheme

    private var cacheKey: String { "\(dark)|\(theme.rawValue)" }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.scene = WorldScene.buildSprite(dark: dark, theme: theme)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let key = cacheKey
        guard view.accessibilityLabel() != key else { return }
        view.setAccessibilityLabel(key)
        view.scene = WorldScene.buildSprite(dark: dark, theme: theme)
    }
}

// MARK: - Theme previews

/// One-frame snapshots of each world, rendered off-screen with SCNRenderer
/// and cached — the picker shows the real 3D, not a color chip.
enum WorldPreview {
    private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(for theme: WorldTheme, dark: Bool) -> NSImage {
        let key = "\(theme.rawValue)|\(dark)"
        if let cached = cache[key] { return cached }
        let scene = WorldScene.build(title: theme.label, figure: "7",
                                     mood: .calm, dark: dark, theme: theme)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
        let image = renderer.snapshot(atTime: 0,
                                      with: CGSize(width: 360, height: 580),
                                      antialiasingMode: .multisampling4X)
        cache[key] = image
        return image
    }
}

// MARK: - Scene assembly

enum WorldScene {

    static func build(title: String, figure: String, mood: WorldStage.Mood,
                      dark: Bool, theme: WorldTheme) -> SCNScene {
        let box = theme.palette
        let skin = theme.skin
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        // Camera — mild perspective, field of view locked to the horizontal
        // axis, so a fixed-aspect host frames the same composition everywhere.
        let camera = SCNCamera()
        camera.projectionDirection = .horizontal
        camera.fieldOfView = 34
        let camNode = SCNNode()
        camNode.name = "camera"
        camNode.camera = camera
        camNode.position = SCNVector3(0, 0.3, 17)
        scene.rootNode.addChildNode(camNode)

        // Soft studio light: high ambient, gentle key, faint rim.
        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 450
        key.eulerAngles = SCNVector3(-0.6, -0.45, 0)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light!.type = .directional
        rim.light!.intensity = 140
        rim.eulerAngles = SCNVector3(0.5, 2.4, 0)
        scene.rootNode.addChildNode(rim)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = dark ? 560 : 680
        scene.rootNode.addChildNode(ambient)

        // Title — spinnable: yaw on "title", drag tilt on its "titleTilt"
        // parent, so fling momentum and the tilt spring-back never fight.
        let titleNode = styledTextNode(title, fontSize: 2.6, extrusion: 0.9,
                                       face: box.titleFace(dark: dark),
                                       side: box.titleSide(dark: dark),
                                       box: box, skin: skin)
        fit(titleNode, maxWidth: 8.4)
        titleNode.name = "title"
        titleNode.eulerAngles = SCNVector3(0, -0.14, 0)
        let tiltNode = SCNNode()
        tiltNode.name = "titleTilt"
        tiltNode.position = SCNVector3(0, 7.4, 0)
        tiltNode.eulerAngles = SCNVector3(0.03, 0, 0)
        tiltNode.addChildNode(titleNode)
        scene.rootNode.addChildNode(tiltNode)

        // Hero — the floating clay machine (or creature), dead center.
        let heroNode = counterNode(figure, mood: mood, box: box, skin: skin)
        heroNode.position = SCNVector3(0, -1.6, 0)
        scene.rootNode.addChildNode(heroNode)

        // Deep-background set dressing, per world.
        switch skin {
        case .cosmos: scene.rootNode.addChildNode(starField(box: box))
        case .googly: scene.rootNode.addChildNode(eyeField(box: box))
        case .holo:   scene.rootNode.addChildNode(chromeDrift())
        case .puffy:  scene.rootNode.addChildNode(cloudDrift(box: box))
        default: break
        }

        // Gentle shadow puddle beneath it.
        let shadow = SCNPlane(width: 10, height: 3.4)
        shadow.firstMaterial?.diffuse.contents = softShadowImage
        shadow.firstMaterial?.lightingModel = .constant
        shadow.firstMaterial?.isDoubleSided = true
        shadow.firstMaterial?.blendMode = .alpha
        shadow.firstMaterial?.writesToDepthBuffer = false
        let shadowNode = SCNNode(geometry: shadow)
        shadowNode.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        shadowNode.position = SCNVector3(0, -6.6, 0)
        shadowNode.opacity = dark ? 0.5 : 0.3
        scene.rootNode.addChildNode(shadowNode)

        heroNode.runAction(.repeatForever(.sequence([
            .moveBy(x: 0, y: 0.28, z: 0, duration: 2.6),
            .moveBy(x: 0, y: -0.28, z: 0, duration: 2.6),
        ]).eased()))

        return scene
    }

    /// One clay piece for the privacy curtain: the world's signature model,
    /// floating over its shadow (plus stars for cosmos). Deliberately sparse
    /// — a single wandering object, not the whole station.
    static func buildSprite(dark: Bool, theme: WorldTheme) -> SCNScene {
        let box = theme.palette
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        let camera = SCNCamera()
        camera.projectionDirection = .horizontal
        camera.fieldOfView = 40
        let camNode = SCNNode()
        camNode.name = "camera"
        camNode.camera = camera
        camNode.position = SCNVector3(0, 0, 13)
        scene.rootNode.addChildNode(camNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 450
        key.eulerAngles = SCNVector3(-0.6, -0.45, 0)
        scene.rootNode.addChildNode(key)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = dark ? 560 : 680
        scene.rootNode.addChildNode(ambient)

        // The one model each world is known by.
        let piece: SCNNode
        switch theme.skin {
        case .machines: piece = gearNode(color: box.warm, deep: box.warmDeep, spin: 24)
        case .monsters: piece = blobNode(box: box)
        case .cosmos:   piece = planetNode(box: box)
        case .blocks:   piece = brickTowerNode(box: box)
        case .balloon:  piece = balloonNode(color: box.primary, scale: 1.6)
        case .dessert:  piece = donutNode(box: box)
        case .holo:     piece = chromeCloudNode()
        case .puffy:    piece = puffCloudNode(box: box)
        case .pop:      piece = popSunNode(box: box)
        case .googly:   piece = googlyClusterNode(box: box)
        }
        piece.position = SCNVector3(0, theme.skin == .balloon ? 2.2 : 0.4, 0)
        scene.rootNode.addChildNode(piece)

        if theme.skin == .cosmos {
            scene.rootNode.addChildNode(starField(box: box))
        }

        let shadow = SCNPlane(width: 9, height: 3.0)
        shadow.firstMaterial?.diffuse.contents = softShadowImage
        shadow.firstMaterial?.lightingModel = .constant
        shadow.firstMaterial?.isDoubleSided = true
        shadow.firstMaterial?.blendMode = .alpha
        shadow.firstMaterial?.writesToDepthBuffer = false
        let shadowNode = SCNNode(geometry: shadow)
        shadowNode.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        shadowNode.position = SCNVector3(0, -4.6, 0)
        shadowNode.opacity = dark ? 0.5 : 0.3
        scene.rootNode.addChildNode(shadowNode)

        piece.runAction(.repeatForever(.sequence([
            .moveBy(x: 0, y: 0.28, z: 0, duration: 2.6),
            .moveBy(x: 0, y: -0.28, z: 0, duration: 2.6),
        ]).eased()))

        return scene
    }

    /// The Fleet teaser scene: the "Fleet" title over a little rack of clay
    /// Macs, wrapped in a "hero" pivot so an interactive drag spins the rack
    /// in place. Same camera, lights and dressing as the welcome stage.
    static func buildFleet(dark: Bool, theme: WorldTheme) -> SCNScene {
        let box = theme.palette
        let skin = theme.skin
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        let camera = SCNCamera()
        camera.projectionDirection = .horizontal
        camera.fieldOfView = 34
        let camNode = SCNNode()
        camNode.name = "camera"
        camNode.camera = camera
        camNode.position = SCNVector3(0, 0.3, 17)
        scene.rootNode.addChildNode(camNode)

        let key = SCNNode()
        key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 450
        key.eulerAngles = SCNVector3(-0.6, -0.45, 0)
        scene.rootNode.addChildNode(key)
        let rim = SCNNode()
        rim.light = SCNLight(); rim.light!.type = .directional; rim.light!.intensity = 140
        rim.eulerAngles = SCNVector3(0.5, 2.4, 0)
        scene.rootNode.addChildNode(rim)
        let ambient = SCNNode()
        ambient.light = SCNLight(); ambient.light!.type = .ambient
        ambient.light!.intensity = dark ? 560 : 680
        scene.rootNode.addChildNode(ambient)

        let titleNode = styledTextNode("Fleet", fontSize: 2.6, extrusion: 0.9,
                                       face: box.titleFace(dark: dark),
                                       side: box.titleSide(dark: dark),
                                       box: box, skin: skin)
        fit(titleNode, maxWidth: 8.4)
        titleNode.name = "title"
        titleNode.eulerAngles = SCNVector3(0, -0.14, 0)
        let tiltNode = SCNNode()
        tiltNode.name = "titleTilt"
        tiltNode.position = SCNVector3(0, 7.4, 0)
        tiltNode.eulerAngles = SCNVector3(0.03, 0, 0)
        tiltNode.addChildNode(titleNode)
        scene.rootNode.addChildNode(tiltNode)

        let heroBody = fleetRackNode(box: box, skin: skin)
        let heroPivot = SCNNode()
        heroPivot.name = "hero"
        heroPivot.position = SCNVector3(0, -1.6, 0)
        heroPivot.addChildNode(heroBody)
        scene.rootNode.addChildNode(heroPivot)

        switch skin {
        case .cosmos: scene.rootNode.addChildNode(starField(box: box))
        case .googly: scene.rootNode.addChildNode(eyeField(box: box))
        case .holo:   scene.rootNode.addChildNode(chromeDrift())
        case .puffy:  scene.rootNode.addChildNode(cloudDrift(box: box))
        default: break
        }

        let shadow = SCNPlane(width: 10, height: 3.4)
        shadow.firstMaterial?.diffuse.contents = softShadowImage
        shadow.firstMaterial?.lightingModel = .constant
        shadow.firstMaterial?.isDoubleSided = true
        shadow.firstMaterial?.blendMode = .alpha
        shadow.firstMaterial?.writesToDepthBuffer = false
        let shadowNode = SCNNode(geometry: shadow)
        shadowNode.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        shadowNode.position = SCNVector3(0, -6.6, 0)
        shadowNode.opacity = dark ? 0.5 : 0.3
        scene.rootNode.addChildNode(shadowNode)

        heroPivot.runAction(.repeatForever(.sequence([
            .moveBy(x: 0, y: 0.28, z: 0, duration: 2.6),
            .moveBy(x: 0, y: -0.28, z: 0, duration: 2.6),
        ]).eased()))

        return scene
    }

    /// A little rack of Macs — a primary up front, two set back to the sides —
    /// each a compact clay screen bobbing on its own beat, with a per-world
    /// signature accent hovering above.
    private static func fleetRackNode(box: WorldPalette, skin: WorldSkin) -> SCNNode {
        let parent = SCNNode()
        let specs: [(pos: SCNVector3, scale: CGFloat, yaw: CGFloat, lamp: NSColor)] = [
            (SCNVector3(0, -0.4, 1.8), 1.0, 0, box.good),
            (SCNVector3(-3.4, 1.2, -1.6), 0.7, 0.34, box.warm),
            (SCNVector3(3.4, 1.1, -1.8), 0.7, -0.34, box.good),
        ]
        for (i, spec) in specs.enumerated() {
            let mac = miniMacNode(box: box, lamp: spec.lamp)
            mac.position = spec.pos
            mac.scale = SCNVector3(spec.scale, spec.scale, spec.scale)
            mac.eulerAngles = SCNVector3(0, spec.yaw, 0)
            let beat = 2.2 + Double(i) * 0.6                 // each floats out of sync
            mac.runAction(.repeatForever(.sequence([
                .moveBy(x: 0, y: 0.22, z: 0, duration: beat),
                .moveBy(x: 0, y: -0.22, z: 0, duration: beat),
            ]).eased()))
            parent.addChildNode(mac)
        }
        if let accent = accentNode(skin: skin, box: box) {
            accent.position = SCNVector3(0, 4.6, -2.4)
            accent.scale = SCNVector3(0.5, 0.5, 0.5)
            parent.addChildNode(accent)
        }
        sway(parent, angle: 0.12, duration: 5)
        return parent
    }

    /// A compact clay Mac: rounded body, a lit face with traffic dots and a
    /// content bar, a breathing status lamp, and a little stand.
    private static func miniMacNode(box: WorldPalette, lamp: NSColor) -> SCNNode {
        let node = SCNNode()

        let body = SCNBox(width: 3.4, height: 2.3, length: 0.5, chamferRadius: 0.3)
        body.materials = [clay(box.soft)]
        node.addChildNode(SCNNode(geometry: body))

        let face = SCNBox(width: 2.9, height: 1.8, length: 0.12, chamferRadius: 0.16)
        let lit = SCNMaterial()
        lit.lightingModel = .constant
        lit.diffuse.contents = box.cloud
        face.materials = [lit]
        let faceNode = SCNNode(geometry: face)
        faceNode.position = SCNVector3(0, 0, 0.28)
        node.addChildNode(faceNode)

        for (i, color) in [box.bad, box.warm, box.good].enumerated() {
            let dot = SCNSphere(radius: 0.09)
            dot.materials = [clay(color)]
            let d = SCNNode(geometry: dot)
            d.position = SCNVector3(-1.1 + CGFloat(i) * 0.28, 0.6, 0.36)
            node.addChildNode(d)
        }

        let bar = SCNBox(width: 1.7, height: 0.28, length: 0.16, chamferRadius: 0.08)
        bar.materials = [clay(box.primary)]
        let barNode = SCNNode(geometry: bar)
        barNode.position = SCNVector3(-0.2, -0.15, 0.36)
        node.addChildNode(barNode)

        // Status lamp on the bezel, breathing.
        let lampGeom = SCNSphere(radius: 0.13)
        lampGeom.materials = [clay(lamp)]
        let lampNode = SCNNode(geometry: lampGeom)
        lampNode.position = SCNVector3(1.15, 0.6, 0.36)
        lampNode.runAction(.repeatForever(.sequence([
            .scale(to: 1.4, duration: 0.9),
            .scale(to: 1.0, duration: 0.9),
        ]).eased()))
        node.addChildNode(lampNode)

        let neck = SCNBox(width: 0.5, height: 0.6, length: 0.3, chamferRadius: 0.12)
        neck.materials = [clay(box.primary)]
        let neckNode = SCNNode(geometry: neck)
        neckNode.position = SCNVector3(0, -1.5, -0.05)
        node.addChildNode(neckNode)

        let base = SCNBox(width: 1.5, height: 0.22, length: 0.9, chamferRadius: 0.12)
        base.materials = [clay(box.primary)]
        let baseNode = SCNNode(geometry: base)
        baseNode.position = SCNVector3(0, -1.85, -0.05)
        node.addChildNode(baseNode)

        return node
    }

    /// The running count front and center, the CI gear turning behind its
    /// shoulder — idling slowly, spinning up while builds run — and a
    /// starburst seal: ✓ when everything's green, ! after a failure.
    private static func counterNode(_ figure: String, mood: WorldStage.Mood,
                                    box: WorldPalette, skin: WorldSkin) -> SCNNode {
        let parent = SCNNode()

        // Over the count's shoulder: each world puts its own thing there.
        switch skin {
        case .cosmos:
            let planet = planetNode(box: box)
            planet.position = SCNVector3(3.0, 2.6, -2.6)
            planet.scale = SCNVector3(0.85, 0.85, 0.85)
            parent.addChildNode(planet)
        case .monsters:
            let blob = blobNode(box: box)
            blob.position = SCNVector3(3.0, 2.8, -2.4)
            blob.scale = SCNVector3(0.9, 0.9, 0.9)
            parent.addChildNode(blob)
        case .blocks:
            let tower = brickTowerNode(box: box)
            tower.position = SCNVector3(3.1, 2.7, -2.6)
            tower.scale = SCNVector3(0.8, 0.8, 0.8)
            parent.addChildNode(tower)
        case .balloon:
            let one = balloonNode(color: box.primary, scale: 1.0)
            one.position = SCNVector3(-1.8, 5.2, 0.6)
            parent.addChildNode(one)
            let two = balloonNode(color: box.warm, scale: 0.75)
            two.position = SCNVector3(2.2, 5.8, -0.6)
            parent.addChildNode(two)
        case .dessert:
            let donut = donutNode(box: box)
            donut.position = SCNVector3(3.0, 2.7, -2.6)
            donut.scale = SCNVector3(0.8, 0.8, 0.8)
            parent.addChildNode(donut)
        case .holo, .puffy, .pop, .googly:
            if let accent = accentNode(skin: skin, box: box) {
                accent.position = SCNVector3(3.0, 2.8, -2.6)
                accent.scale = SCNVector3(0.9, 0.9, 0.9)
                parent.addChildNode(accent)
            }
        case .machines:
            let gear = gearNode(color: box.warm, deep: box.warmDeep,
                                spin: mood == .busy ? 7 : 24)
            gear.position = SCNVector3(3.0, 2.6, -2.6)
            gear.scale = SCNVector3(0.85, 0.85, 0.85)
            parent.addChildNode(gear)
        }

        let face: NSColor, side: NSColor
        switch mood {
        case .calm:  face = box.primary; side = box.primaryDeep
        case .busy:  face = box.warm;    side = box.warmDeep
        case .alert: face = box.bad;     side = box.badDeep
        }
        let fig = styledTextNode(figure, fontSize: 7.2, extrusion: 2.4,
                                 face: face, side: side, box: box, skin: skin)
        fit(fig, maxWidth: 7.6)
        fig.position = SCNVector3(0, -0.6, 1.0)
        fig.eulerAngles = SCNVector3(0.04, -0.28, 0)
        sway(fig, angle: 0.2, duration: 3.4)
        parent.addChildNode(fig)

        // Monster: the count itself is alive — mismatched blinking eyes and
        // wobbly antennae. Asymmetry is the whole charm.
        if skin == .monsters {
            let (mn, mx) = fig.boundingBox
            let midX = (mn.x + mx.x) / 2
            let width = mx.x - mn.x

            let eyeL = eyeNode(radius: 0.62, cloud: box.cloud)
            eyeL.position = SCNVector3(midX - width * 0.2, mx.y + 0.32, mx.z + 0.15)
            blink(eyeL)
            fig.addChildNode(eyeL)

            let eyeR = eyeNode(radius: 0.42, cloud: box.cloud)
            eyeR.position = SCNVector3(midX + width * 0.24, mx.y + 0.5, mx.z + 0.15)
            blink(eyeR)
            fig.addChildNode(eyeR)

            let antL = antennaNode(height: 1.15, color: box.warm, tip: box.bad)
            antL.position = SCNVector3(midX - width * 0.38, mx.y + 0.2, (mn.z + mx.z) / 2)
            antL.eulerAngles = SCNVector3(0, 0, 0.3)
            fig.addChildNode(antL)

            let antR = antennaNode(height: 0.8, color: box.warm, tip: box.good)
            antR.position = SCNVector3(midX + width * 0.4, mx.y + 0.25, (mn.z + mx.z) / 2)
            antR.eulerAngles = SCNVector3(0, 0, -0.35)
            fig.addChildNode(antR)
        }

        // The verification seal, stamped by the state of the last runs.
        if mood != .busy {
            let seal = sealNode(color: mood == .alert ? box.bad : box.good,
                                deep: mood == .alert ? box.badDeep : box.goodDeep,
                                glyph: mood == .alert ? "!" : "✓",
                                cloud: box.cloud)
            seal.position = SCNVector3(-2.9, -3.1, 1.8)
            seal.scale = SCNVector3(0.85, 0.85, 0.85)
            parent.addChildNode(seal)
        }
        return parent
    }

    /// A starburst badge with an extruded glyph on its face.
    private static func sealNode(color: NSColor, deep: NSColor, glyph: String,
                                 cloud: NSColor) -> SCNNode {
        let parent = SCNNode()

        let burst = SCNNode()
        let disc = SCNCylinder(radius: 1.6, height: 0.55)
        disc.radialSegmentCount = 48
        disc.materials = [clay(color)]
        burst.addChildNode(SCNNode(geometry: disc))
        for i in 0..<14 {
            let spike = SCNBox(width: 0.62, height: 0.55, length: 0.62, chamferRadius: 0.14)
            spike.materials = [clay(color)]
            let node = SCNNode(geometry: spike)
            let angle = CGFloat(i) / 14 * 2 * CGFloat.pi
            node.position = SCNVector3(cos(angle) * 1.62, 0, sin(angle) * 1.62)
            node.eulerAngles = SCNVector3(0, -angle + .pi / 4, 0)   // point outward
            burst.addChildNode(node)
        }
        burst.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)        // face the camera
        parent.addChildNode(burst)

        let mark = textNode(glyph, fontSize: 2.0, extrusion: 0.5,
                            face: cloud, side: deep)
        mark.position = SCNVector3(0, 0, 0.6)
        parent.addChildNode(mark)

        // The whole seal — glyph included — turns like a slow coin.
        parent.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 9)))
        return parent
    }

    /// A puffy clay gear: disc + teeth + hub, facing the camera, spinning.
    private static func gearNode(color: NSColor, deep: NSColor, spin: Double) -> SCNNode {
        let gear = SCNNode()
        let disc = SCNCylinder(radius: 3.0, height: 0.8)
        disc.radialSegmentCount = 48
        disc.materials = [clay(color)]
        gear.addChildNode(SCNNode(geometry: disc))

        for i in 0..<10 {
            let tooth = SCNBox(width: 1.05, height: 0.8, length: 0.95, chamferRadius: 0.22)
            tooth.materials = [clay(color)]
            let node = SCNNode(geometry: tooth)
            let angle = CGFloat(i) / 10 * 2 * CGFloat.pi
            node.position = SCNVector3(cos(angle) * 3.25, 0, sin(angle) * 3.25)
            node.eulerAngles = SCNVector3(0, -angle, 0)
            gear.addChildNode(node)
        }

        let hub = SCNCylinder(radius: 0.95, height: 0.9)
        hub.materials = [clay(deep)]
        gear.addChildNode(SCNNode(geometry: hub))

        gear.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)   // flat side to the camera
        gear.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: spin)))
        return gear
    }

    // MARK: Skin pieces

    /// A googly eye: white clay ball with a dark pupil that wanders around.
    private static func eyeNode(radius: CGFloat, cloud: NSColor) -> SCNNode {
        let ball = SCNSphere(radius: radius)
        ball.materials = [clay(cloud)]
        let eye = SCNNode(geometry: ball)

        let pupilGeom = SCNSphere(radius: radius * 0.45)
        pupilGeom.materials = [clay(NSColor(srgbRed: 0.13, green: 0.13, blue: 0.16, alpha: 1))]
        let pupil = SCNNode(geometry: pupilGeom)
        pupil.position = SCNVector3(0, 0, radius * 0.72)
        eye.addChildNode(pupil)

        let drift = radius * 0.3
        pupil.runAction(.repeatForever(.sequence([
            .wait(duration: 1.6),
            .moveBy(x: drift, y: 0, z: 0, duration: 0.25),
            .wait(duration: 1.1),
            .moveBy(x: -drift * 2, y: 0, z: 0, duration: 0.3),
            .wait(duration: 0.9),
            .moveBy(x: drift, y: 0, z: 0, duration: 0.25),
        ]).eased()))
        return eye
    }

    /// Occasional slow blink — squashes the whole eye shut and back.
    private static func blink(_ eye: SCNNode) {
        let close = SCNAction.customAction(duration: 0.22) { node, elapsed in
            let progress = elapsed / 0.22
            let squeeze = 1 - sin(.pi * progress) * 0.85
            node.scale = SCNVector3(1, squeeze, 1)
        }
        eye.runAction(.repeatForever(.sequence([
            .wait(duration: 2.3), close,
            .wait(duration: 1.5), close,
        ])))
    }

    /// A wobbly antenna: stalk + ball tip, waving side to side.
    private static func antennaNode(height: CGFloat, color: NSColor, tip: NSColor) -> SCNNode {
        let node = SCNNode()
        let stalkGeom = SCNCylinder(radius: 0.09, height: height)
        stalkGeom.materials = [clay(color)]
        let stalk = SCNNode(geometry: stalkGeom)
        stalk.position = SCNVector3(0, height / 2, 0)
        node.addChildNode(stalk)

        let ballGeom = SCNSphere(radius: 0.26)
        ballGeom.materials = [clay(tip)]
        let ball = SCNNode(geometry: ballGeom)
        ball.position = SCNVector3(0, height, 0)
        node.addChildNode(ball)

        node.runAction(.repeatForever(.sequence([
            .rotateBy(x: 0, y: 0, z: 0.16, duration: 1.3),
            .rotateBy(x: 0, y: 0, z: -0.16, duration: 1.3),
        ]).eased()))
        return node
    }

    /// The monster world's mascot: a jelly blob with mismatched blinking
    /// eyes, a toothy grin, and antennae — squashing and stretching in place.
    private static func blobNode(box: WorldPalette) -> SCNNode {
        let parent = SCNNode()

        let bodyGeom = SCNSphere(radius: 2.0)
        bodyGeom.materials = [clay(box.warm)]
        let body = SCNNode(geometry: bodyGeom)
        body.scale = SCNVector3(1.1, 0.9, 1)
        parent.addChildNode(body)
        // Jelly idle: squash & stretch, forever.
        body.runAction(.repeatForever(.customAction(duration: 2.6) { node, elapsed in
            let phase = elapsed / 2.6 * 2 * CGFloat.pi
            node.scale = SCNVector3(1.1 + sin(phase) * 0.05,
                                    0.9 - sin(phase) * 0.07, 1)
        }))

        let eyeL = eyeNode(radius: 0.6, cloud: box.cloud)
        eyeL.position = SCNVector3(-0.65, 0.75, 1.5)
        blink(eyeL)
        parent.addChildNode(eyeL)
        let eyeR = eyeNode(radius: 0.38, cloud: box.cloud)
        eyeR.position = SCNVector3(0.75, 0.9, 1.55)
        blink(eyeR)
        parent.addChildNode(eyeR)

        // A wide grin with two teeth poking out of it.
        let mouthGeom = SCNCapsule(capRadius: 0.26, height: 2.0)
        mouthGeom.materials = [clay(NSColor(srgbRed: 0.16, green: 0.12, blue: 0.20, alpha: 1))]
        let mouth = SCNNode(geometry: mouthGeom)
        mouth.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
        mouth.position = SCNVector3(0.05, -0.55, 1.72)
        parent.addChildNode(mouth)
        for x in [CGFloat(-0.45), 0.2] {
            let tooth = SCNBox(width: 0.34, height: 0.42, length: 0.2, chamferRadius: 0.08)
            tooth.materials = [clay(box.cloud)]
            let node = SCNNode(geometry: tooth)
            node.position = SCNVector3(x, -0.38, 1.82)
            parent.addChildNode(node)
        }

        let antL = antennaNode(height: 1.1, color: box.primary, tip: box.bad)
        antL.position = SCNVector3(-0.7, 1.55, 0)
        antL.eulerAngles = SCNVector3(0, 0, 0.3)
        parent.addChildNode(antL)
        let antR = antennaNode(height: 0.75, color: box.primary, tip: box.good)
        antR.position = SCNVector3(0.65, 1.6, 0)
        antR.eulerAngles = SCNVector3(0, 0, -0.35)
        parent.addChildNode(antR)

        return parent
    }

    /// A studded toy brick.
    private static func brickNode(width: CGFloat, height: CGFloat, length: CGFloat,
                                  color: NSColor, studs: Int) -> SCNNode {
        let brickGeom = SCNBox(width: width, height: height, length: length, chamferRadius: 0.08)
        brickGeom.materials = [clay(color)]
        let brick = SCNNode(geometry: brickGeom)
        for i in 0..<studs {
            let stud = SCNCylinder(radius: width / CGFloat(studs) * 0.28, height: 0.24)
            stud.materials = [clay(color)]
            let node = SCNNode(geometry: stud)
            let x = (CGFloat(i) + 0.5) / CGFloat(studs) * width - width / 2
            node.position = SCNVector3(x, height / 2 + 0.12, 0)
            brick.addChildNode(node)
        }
        return brick
    }

    /// A slowly turning tower of criss-crossed bricks.
    private static func brickTowerNode(box: WorldPalette) -> SCNNode {
        let tower = SCNNode()
        let colors = [box.primary, box.warm, box.good]
        for (i, color) in colors.enumerated() {
            let brick = brickNode(width: 3.4, height: 1.15, length: 1.8, color: color, studs: 3)
            brick.position = SCNVector3(0, CGFloat(i) * 1.45 - 1.45, 0)
            brick.eulerAngles = SCNVector3(0, CGFloat(i) * 0.5 - 0.5, 0)
            tower.addChildNode(brick)
        }
        tower.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 30)))
        return tower
    }

    /// A shiny balloon on a string, drifting.
    private static func balloonNode(color: NSColor, scale: CGFloat) -> SCNNode {
        let node = SCNNode()

        let ballGeom = SCNSphere(radius: 1.1 * scale)
        let shine = clay(color)
        shine.specular.contents = NSColor.white
        shine.shininess = 0.9
        ballGeom.materials = [shine]
        let ball = SCNNode(geometry: ballGeom)
        ball.scale = SCNVector3(1, 1.15, 1)
        node.addChildNode(ball)

        let knotGeom = SCNCone(topRadius: 0.05, bottomRadius: 0.18 * scale, height: 0.3)
        knotGeom.materials = [clay(color)]
        let knot = SCNNode(geometry: knotGeom)
        knot.position = SCNVector3(0, -1.4 * scale, 0)
        knot.eulerAngles = SCNVector3(CGFloat.pi, 0, 0)
        node.addChildNode(knot)

        let stringGeom = SCNCylinder(radius: 0.03, height: 2.6 * scale)
        stringGeom.materials = [clay(NSColor(white: 0.75, alpha: 1))]
        let string = SCNNode(geometry: stringGeom)
        string.position = SCNVector3(0, -2.7 * scale, 0)
        node.addChildNode(string)

        node.runAction(.repeatForever(.sequence([
            .rotateBy(x: 0, y: 0, z: 0.1, duration: 1.9),
            .rotateBy(x: 0, y: 0, z: -0.1, duration: 1.9),
        ]).eased()))
        return node
    }

    /// A frosted, sprinkled donut, spinning like a record.
    private static func donutNode(box: WorldPalette) -> SCNNode {
        let parent = SCNNode()

        let doughGeom = SCNTorus(ringRadius: 2.2, pipeRadius: 0.95)
        doughGeom.materials = [clay(box.warm)]
        parent.addChildNode(SCNNode(geometry: doughGeom))

        let glazeGeom = SCNTorus(ringRadius: 2.2, pipeRadius: 0.8)
        glazeGeom.materials = [clay(box.primary)]
        let glaze = SCNNode(geometry: glazeGeom)
        glaze.position = SCNVector3(0, 0.28, 0)
        parent.addChildNode(glaze)

        let sprinkleColors = [box.good, box.cloud, box.bad, box.warmDeep]
        for i in 0..<10 {
            let angle = CGFloat(i) / 10 * 2 * CGFloat.pi
            let sprinkleGeom = SCNCapsule(capRadius: 0.07, height: 0.44)
            sprinkleGeom.materials = [clay(sprinkleColors[i % sprinkleColors.count])]
            let sprinkle = SCNNode(geometry: sprinkleGeom)
            sprinkle.position = SCNVector3(cos(angle) * 2.2, 0.85, sin(angle) * 2.2)
            sprinkle.eulerAngles = SCNVector3(CGFloat.pi / 2 * 0.9, angle + 0.6, 0)
            parent.addChildNode(sprinkle)
        }

        parent.eulerAngles = SCNVector3(0.9, 0, -0.15)   // tilted at the camera
        parent.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 26)))
        return parent
    }

    /// A ringed clay planet — the cosmos skin's stand-in for the gear.
    private static func planetNode(box: WorldPalette) -> SCNNode {
        let parent = SCNNode()

        let globe = SCNSphere(radius: 2.1)
        globe.materials = [clay(box.primary)]
        parent.addChildNode(SCNNode(geometry: globe))

        let ringGeom = SCNTorus(ringRadius: 3.1, pipeRadius: 0.28)
        ringGeom.materials = [clay(box.warm)]
        let ring = SCNNode(geometry: ringGeom)
        ring.scale = SCNVector3(1, 0.35, 1)
        parent.addChildNode(ring)

        parent.eulerAngles = SCNVector3(0.35, 0, -0.25)
        parent.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 22)))
        return parent
    }

    /// A handful of twinkling stars, hung deep behind the station.
    private static func starField(box: WorldPalette) -> SCNNode {
        let field = SCNNode()
        let spots: [(x: CGFloat, y: CGFloat, z: CGFloat, r: CGFloat)] = [
            (-4.6, 8.6, -5, 0.14), (3.9, 9.4, -6, 0.10), (-2.2, 5.6, -7, 0.09),
            (4.8, 4.4, -5, 0.13), (-5.2, 1.8, -6, 0.10), (5.4, -0.8, -7, 0.09),
            (-4.0, -3.2, -5, 0.12), (2.6, -4.8, -6, 0.10), (-1.4, -7.6, -5, 0.11),
            (4.4, -8.4, -6, 0.13), (0.8, 10.8, -6, 0.11), (-5.6, -9.0, -6, 0.10),
        ]
        for (i, spot) in spots.enumerated() {
            let star = SCNSphere(radius: spot.r)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = i % 3 == 0 ? box.warm : box.cloud
            star.materials = [m]
            let node = SCNNode(geometry: star)
            node.position = SCNVector3(spot.x, spot.y, spot.z)
            let beat = 0.7 + Double(i % 5) * 0.22
            node.runAction(.repeatForever(.sequence([
                .fadeOpacity(to: 0.3, duration: beat),
                .fadeOpacity(to: 1.0, duration: beat),
            ]).eased()))
            field.addChildNode(node)
        }
        return field
    }

    // MARK: New-world pieces

    /// The signature piece each new world hangs its identity on.
    private static func accentNode(skin: WorldSkin, box: WorldPalette) -> SCNNode? {
        switch skin {
        case .holo:   return chromeCloudNode()
        case .puffy:  return puffCloudNode(box: box)
        case .pop:    return popSunNode(box: box)
        case .googly: return googlyClusterNode(box: box)
        default:      return nil
        }
    }

    /// An iridescent chrome cloud — lobes of mirror-candy.
    private static func chromeCloudNode() -> SCNNode {
        let cloud = SCNNode()
        let lobes: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
            (0, 0, 1.5), (-1.6, -0.25, 1.0), (1.6, -0.2, 1.05),
            (0.9, 0.75, 0.9), (-0.9, 0.7, 0.85),
        ]
        for lobe in lobes {
            let ball = SCNSphere(radius: lobe.r)
            ball.materials = [chrome()]
            let node = SCNNode(geometry: ball)
            node.position = SCNVector3(lobe.x, lobe.y, 0)
            cloud.addChildNode(node)
        }
        let drop = SCNSphere(radius: 0.3)
        drop.materials = [chrome()]
        let dropNode = SCNNode(geometry: drop)
        dropNode.position = SCNVector3(2.8, 0.6, 0.3)
        cloud.addChildNode(dropNode)
        sway(cloud, angle: 0.25, duration: 4.0)
        return cloud
    }

    /// A puffy teal cloud with the sun peeking out behind it.
    private static func puffCloudNode(box: WorldPalette) -> SCNNode {
        let parent = SCNNode()
        let sun = SCNSphere(radius: 1.35)
        sun.materials = [clay(box.cloud)]
        let sunNode = SCNNode(geometry: sun)
        sunNode.position = SCNVector3(0.7, 1.0, -0.9)
        parent.addChildNode(sunNode)
        let lobes: [(x: CGFloat, y: CGFloat, z: CGFloat, r: CGFloat)] = [
            (0, 0, 0, 1.35), (-1.5, -0.2, 0.2, 0.95), (1.5, -0.15, 0.15, 1.0),
            (0.4, 0.55, 0.4, 0.8), (-2.5, -0.4, 0, 0.55),
        ]
        for lobe in lobes {
            let ball = SCNSphere(radius: lobe.r)
            ball.materials = [clay(box.soft)]
            let node = SCNNode(geometry: ball)
            node.position = SCNVector3(lobe.x, lobe.y, lobe.z)
            node.scale = SCNVector3(1, 0.82, 1)
            parent.addChildNode(node)
        }
        sway(parent, angle: 0.15, duration: 4.5)
        return parent
    }

    /// Pop's sun nested in a ring of hot-pink cloud lobes.
    private static func popSunNode(box: WorldPalette) -> SCNNode {
        let parent = SCNNode()
        let sun = SCNSphere(radius: 1.5)
        sun.materials = [clay(box.cloud)]
        let sunNode = SCNNode(geometry: sun)
        sunNode.position = SCNVector3(0, 0.5, -0.6)
        parent.addChildNode(sunNode)
        let lobes: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
            (-1.5, -0.4, 0.85), (-0.5, -0.7, 0.95), (0.7, -0.6, 0.9), (1.7, -0.3, 0.7),
        ]
        for lobe in lobes {
            let ball = SCNSphere(radius: lobe.r)
            ball.materials = [clay(box.primary)]
            let node = SCNNode(geometry: ball)
            node.position = SCNVector3(lobe.x, lobe.y, 0.2)
            parent.addChildNode(node)
        }
        sway(parent, angle: 0.18, duration: 4.2)
        return parent
    }

    /// One free-floating googly eyeball.
    private static func googlyBall(radius: CGFloat, color: NSColor) -> SCNNode {
        let ball = SCNSphere(radius: radius)
        ball.materials = [clay(color)]
        let node = SCNNode(geometry: ball)
        let pupil = SCNSphere(radius: radius * 0.34)
        pupil.materials = [clay(NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1))]
        let pupilNode = SCNNode(geometry: pupil)
        pupilNode.position = SCNVector3(0, 0, radius * 0.78)
        node.addChildNode(pupilNode)
        blink(node)
        return node
    }

    /// A pair of googly eyeballs drifting together.
    private static func googlyClusterNode(box: WorldPalette) -> SCNNode {
        let parent = SCNNode()
        let big = googlyBall(radius: 1.35, color: box.cloud)
        big.position = SCNVector3(-0.5, 0.2, 0)
        parent.addChildNode(big)
        let small = googlyBall(radius: 0.85, color: box.primary)
        small.position = SCNVector3(1.35, -0.35, 0.4)
        parent.addChildNode(small)
        sway(parent, angle: 0.2, duration: 3.6)
        return parent
    }

    /// Googly: a ball pit of eyeballs hung deep behind the station.
    private static func eyeField(box: WorldPalette) -> SCNNode {
        let field = SCNNode()
        let spots: [(x: CGFloat, y: CGFloat, z: CGFloat, r: CGFloat)] = [
            (-4.8, 8.4, -6, 0.55), (4.6, 9.2, -7, 0.45), (-3.4, 3.2, -7, 0.4),
            (5.2, 1.0, -6, 0.5), (-5.0, -2.6, -6, 0.45), (4.6, -5.8, -7, 0.5),
            (-2.6, -8.2, -6, 0.4), (2.0, 11.0, -7, 0.45),
        ]
        for (i, spot) in spots.enumerated() {
            let ball = googlyBall(radius: spot.r, color: i % 3 == 0 ? box.primary : box.cloud)
            ball.position = SCNVector3(spot.x, spot.y, spot.z)
            let beat = 2.2 + Double(i % 4) * 0.5
            ball.runAction(.repeatForever(.sequence([
                .moveBy(x: 0, y: 0.3, z: 0, duration: beat),
                .moveBy(x: 0, y: -0.3, z: 0, duration: beat),
            ]).eased()))
            field.addChildNode(ball)
        }
        return field
    }

    /// Holo: little chrome cloudlets drifting deep behind.
    private static func chromeDrift() -> SCNNode {
        let field = SCNNode()
        let spots: [(x: CGFloat, y: CGFloat, s: CGFloat)] = [(-4.6, 7.6, 0.5), (4.8, 2.4, 0.4), (-4.2, -5.4, 0.45)]
        for (i, spot) in spots.enumerated() {
            let cloudlet = chromeCloudNode()
            cloudlet.position = SCNVector3(spot.x, spot.y, -6)
            cloudlet.scale = SCNVector3(spot.s, spot.s, spot.s)
            let beat = 3.4 + Double(i) * 0.7
            cloudlet.runAction(.repeatForever(.sequence([
                .moveBy(x: 0.8, y: 0, z: 0, duration: beat),
                .moveBy(x: -0.8, y: 0, z: 0, duration: beat),
            ]).eased()))
            field.addChildNode(cloudlet)
        }
        return field
    }

    /// Puffy: soft cloudlets drifting deep behind.
    private static func cloudDrift(box: WorldPalette) -> SCNNode {
        let field = SCNNode()
        let spots: [(x: CGFloat, y: CGFloat, s: CGFloat)] = [(-4.8, 8.0, 0.5), (5.0, 4.2, 0.4), (-4.4, -6.0, 0.45)]
        for (i, spot) in spots.enumerated() {
            let cloudlet = SCNNode()
            let lobes: [(x: CGFloat, r: CGFloat)] = [(0, 1.2), (-1.3, 0.8), (1.3, 0.85)]
            for (j, lobe) in lobes.enumerated() {
                let ball = SCNSphere(radius: lobe.r)
                ball.materials = [clay(box.soft)]
                let node = SCNNode(geometry: ball)
                node.position = SCNVector3(lobe.x, j == 0 ? 0.2 : 0, 0)
                node.scale = SCNVector3(1, 0.8, 1)
                cloudlet.addChildNode(node)
            }
            cloudlet.position = SCNVector3(spot.x, spot.y, -6)
            cloudlet.scale = SCNVector3(spot.s, spot.s, spot.s)
            let beat = 4.0 + Double(i) * 0.8
            cloudlet.runAction(.repeatForever(.sequence([
                .moveBy(x: 0.9, y: 0, z: 0, duration: beat),
                .moveBy(x: -0.9, y: 0, z: 0, duration: beat),
            ]).eased()))
            field.addChildNode(cloudlet)
        }
        return field
    }

    // MARK: World text styles

    /// Extruded text in the world's own voice: clay for most, iridescent
    /// chrome for holo, chunky monochrome prism bevels for pop, and per-glyph
    /// candy colors for puffy (sleepy lids) and googly (googly eyes).
    private static func styledTextNode(_ string: String, fontSize: CGFloat, extrusion: CGFloat,
                                       face: NSColor, side: NSColor,
                                       box: WorldPalette, skin: WorldSkin) -> SCNNode {
        switch skin {
        case .holo:
            let m = chrome()
            return wrappedText(string, fontSize: fontSize, extrusion: extrusion,
                               materials: [m, m, m, m, m])
        case .pop:
            let faceM = clay(box.primary)
            let sideM = clay(box.primaryDeep)
            let bevel = clay(box.bad)
            return wrappedText(string, fontSize: fontSize, extrusion: extrusion * 1.25,
                               materials: [faceM, faceM, sideM, bevel, bevel],
                               chamferFactor: 0.07)
        case .puffy:
            return candyTextNode(string, fontSize: fontSize, extrusion: extrusion,
                                 box: box, googly: false)
        case .googly:
            return candyTextNode(string, fontSize: fontSize, extrusion: extrusion,
                                 box: box, googly: true)
        default:
            return textNode(string, fontSize: fontSize, extrusion: extrusion,
                            face: face, side: side)
        }
    }

    /// Each glyph gets its own candy color — and its own face: sleepy closed
    /// lids for puffy, wandering googly eyes for googly.
    private static func candyTextNode(_ string: String, fontSize: CGFloat, extrusion: CGFloat,
                                      box: WorldPalette, googly: Bool) -> SCNNode {
        let faces = [box.primary, box.warm, box.good, box.bad, box.soft]
        let sides = [box.primaryDeep, box.warmDeep, box.goodDeep, box.badDeep, box.softShade]
        let container = SCNNode()
        var cursor: CGFloat = 0
        var index = 0
        var minY: CGFloat = 0, maxY: CGFloat = 0, maxZ: CGFloat = 0
        for ch in string {
            if ch == " " { cursor += fontSize * 0.34; continue }
            let glyph = textNode(String(ch), fontSize: fontSize, extrusion: extrusion,
                                 face: faces[index % faces.count],
                                 side: sides[index % sides.count])
            let (mn, mx) = glyph.boundingBox
            let w = mx.x - mn.x
            glyph.position = SCNVector3(cursor + w / 2, 0, 0)
            container.addChildNode(glyph)
            if googly {
                let eye = eyeNode(radius: fontSize * 0.085, cloud: box.cloud)
                eye.position = SCNVector3(0, mx.y * 0.30, mx.z + fontSize * 0.05)
                blink(eye)
                glyph.addChildNode(eye)
            } else if index % 2 == 0 {
                let lid = sleepyLidNode(width: fontSize * 0.17)
                lid.position = SCNVector3(0, mx.y * 0.35, mx.z + fontSize * 0.02)
                glyph.addChildNode(lid)
            }
            cursor += w + fontSize * 0.06
            index += 1
            minY = min(minY, mn.y); maxY = max(maxY, mx.y); maxZ = max(maxZ, mx.z)
        }
        let total = max(cursor - fontSize * 0.06, 0.001)
        for child in container.childNodes { child.position.x -= total / 2 }
        container.boundingBox = (SCNVector3(-total / 2, minY, -maxZ),
                                 SCNVector3(total / 2, maxY, maxZ))
        return container
    }

    /// A closed sleepy eyelid — one soft dark line.
    private static func sleepyLidNode(width: CGFloat) -> SCNNode {
        let lid = SCNCapsule(capRadius: width * 0.16, height: width)
        lid.materials = [clay(NSColor(srgbRed: 0.12, green: 0.12, blue: 0.15, alpha: 1))]
        let node = SCNNode(geometry: lid)
        node.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
        return node
    }

    /// Iridescent mirror-candy: a pink→violet→cyan sheen with a hot highlight.
    private static func chrome() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = iridescentImage
        m.specular.contents = NSColor.white
        m.shininess = 0.95
        m.emission.contents = iridescentImage
        m.emission.intensity = 0.35
        return m
    }

    private static let iridescentImage: NSImage = {
        let size = NSSize(width: 128, height: 256)
        return NSImage(size: size, flipped: false) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            let colors = [
                NSColor(srgbRed: 0.45, green: 0.92, blue: 1.00, alpha: 1).cgColor,
                NSColor(srgbRed: 0.70, green: 0.52, blue: 1.00, alpha: 1).cgColor,
                NSColor(srgbRed: 1.00, green: 0.42, blue: 0.82, alpha: 1).cgColor,
            ]
            guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: [0, 0.5, 1]) else { return false }
            c.drawLinearGradient(g, start: .zero,
                                 end: CGPoint(x: size.width, y: size.height), options: [])
            return true
        }
    }()

    /// Gentle side-to-side idle, like the object is drifting in place.
    private static func sway(_ node: SCNNode, angle: CGFloat, duration: Double) {
        node.runAction(.repeatForever(.sequence([
            .rotateBy(x: 0, y: angle, z: 0, duration: duration),
            .rotateBy(x: 0, y: -angle, z: 0, duration: duration),
        ]).eased()))
    }

    /// Puffy extruded 3D text, centered on its own pivot, with a deeper side
    /// color so the depth reads without harsh shading.
    ///
    /// The glyphs are authored 10× large and scaled back down: SceneKit's
    /// text triangulator degenerates (spike artifacts on tight joins) when a
    /// small font is paired with fine flatness, but is robust at large
    /// coordinates — and the fine tessellation keeps curves smooth even when
    /// a glyph fills the screen.
    private static func textNode(_ string: String, fontSize: CGFloat,
                                 extrusion: CGFloat,
                                 face faceColor: NSColor, side sideColor: NSColor) -> SCNNode {
        let face = clay(faceColor)
        let side = clay(sideColor)
        // front, back, extrusion, front chamfer, back chamfer
        return wrappedText(string, fontSize: fontSize, extrusion: extrusion,
                           materials: [face, face, side, face, face])
    }

    private static func wrappedText(_ string: String, fontSize: CGFloat, extrusion: CGFloat,
                                    materials: [SCNMaterial],
                                    chamferFactor: CGFloat = 0.04) -> SCNNode {
        let authoring: CGFloat = 10
        let text = SCNText(string: string, extrusionDepth: extrusion * authoring)
        text.font = roundedHeavy(fontSize * authoring)
        text.flatness = fontSize * authoring * 0.0025
        text.chamferRadius = fontSize * authoring * chamferFactor
        text.materials = materials

        let glyphs = SCNNode(geometry: text)
        center(glyphs)
        let inverse: CGFloat = 1 / authoring
        glyphs.scale = SCNVector3(inverse, inverse, inverse)

        // Wrap, so callers see a node at the normal 1× scale. A plain node's
        // boundingBox ignores its children, so set it explicitly to the
        // scaled, centered glyph bounds — fit() and the skins' decoration
        // placement both read it.
        let node = SCNNode()
        node.addChildNode(glyphs)
        let (bmin, bmax) = glyphs.boundingBox
        let cx = (bmin.x + bmax.x) / 2, cy = (bmin.y + bmax.y) / 2, cz = (bmin.z + bmax.z) / 2
        node.boundingBox = (
            SCNVector3((bmin.x - cx) * inverse, (bmin.y - cy) * inverse, (bmin.z - cz) * inverse),
            SCNVector3((bmax.x - cx) * inverse, (bmax.y - cy) * inverse, (bmax.z - cz) * inverse))
        return node
    }

    /// Smooth matte clay — soft highlight, no texture.
    private static func clay(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = color
        m.specular.contents = NSColor(white: 0.85, alpha: 1)
        m.shininess = 0.4
        return m
    }

    // MARK: Helpers

    private static func center(_ node: SCNNode) {
        let (min, max) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((min.x + max.x) / 2,
                                               (min.y + max.y) / 2,
                                               (min.z + max.z) / 2)
    }

    private static func fit(_ node: SCNNode, maxWidth: CGFloat) {
        let (min, max) = node.boundingBox
        let width = max.x - min.x
        guard width > maxWidth else { return }
        let s = maxWidth / width
        node.scale = SCNVector3(s, s, s)
    }

    private static func roundedHeavy(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size) else { return base }
        return rounded
    }

    /// Radial soft-slate→clear ellipse for the shadow puddle.
    private static let softShadowImage: NSImage = {
        let size = NSSize(width: 256, height: 100)
        return NSImage(size: size, flipped: false) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            let shadowColor = NSColor(srgbRed: 0.25, green: 0.26, blue: 0.38, alpha: 0.55)
            guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [shadowColor.cgColor, NSColor.clear.cgColor] as CFArray,
                                     locations: [0, 1]) else { return false }
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.scaleBy(x: 1, y: size.height / size.width)
            c.drawRadialGradient(g, startCenter: .zero, startRadius: 0,
                                 endCenter: .zero, endRadius: size.width / 2, options: [])
            return true
        }
    }()
}

private extension SCNAction {
    func eased() -> SCNAction {
        timingMode = .easeInEaseOut
        return self
    }
}
