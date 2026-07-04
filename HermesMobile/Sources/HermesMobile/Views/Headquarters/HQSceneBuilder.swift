import SceneKit
import SwiftUI
import UIKit

/// Builds the cinematic HQ floor — the exact world proven on the Mac look-dev
/// rig (same SceneKit engine, renders in `~/BoardroomAssets/renders/world_v13*`):
/// a 60×60 dark-polished floor with emerald light seams, a central command dais
/// ringed by consoles under a holographic globe, a raised gold-rimmed executive
/// penthouse against a real night-skyline window, staffed department pods with
/// status totems, security mechs, and a lounge. Furniture and characters are
/// bundled USDZ assets pulled into the palette by `HQAssetLibrary`; every
/// placement has a primitive fallback so a missing asset degrades, not crashes.
enum HQSceneBuilder {

    // MARK: Palette (proven values from the look-dev rig)

    static let emerald = UIColor(red: 0.13, green: 0.62, blue: 0.42, alpha: 1)
    static let emeraldHot = UIColor(red: 0.16, green: 0.85, blue: 0.55, alpha: 1)
    static let gold = UIColor(red: 0.87, green: 0.67, blue: 0.32, alpha: 1)
    static let steel = UIColor(red: 0.35, green: 0.55, blue: 0.80, alpha: 1)
    static let navyDeep = UIColor(red: 0.016, green: 0.022, blue: 0.04, alpha: 1)
    static let surface = UIColor(red: 0.055, green: 0.07, blue: 0.10, alpha: 1)

    private static let execZ: Float = -11

    /// Fixed floor anchors per zone — the single source of truth `HQLayout`
    /// uses to seat agents so placement and scenery never drift apart.
    static let zoneAnchors: [HQOfficeArchetype: SCNVector3] = [
        .executive:       SCNVector3(1.6, 1.1, -10.2),
        .command:         SCNVector3(0, 0.22, 2.6),
        .researchLab:     SCNVector3(-9.3, 0, 3.5),
        .engineeringDen:  SCNVector3(9.3, 0, 3.5),
        .commandEast:     SCNVector3(3.9, 0.22, 1.9),   // console posts flanking the dais
        .commandWest:     SCNVector3(-3.9, 0.22, 1.9),
        .researchLab2:    SCNVector3(-9.3, 0, 5.9),     // the pods' second desks
        .engineeringDen2: SCNVector3(9.3, 0, 5.9),
        .lounge:          SCNVector3(0, 0, 7.4),        // sofa corner by the mechs
    ]

    /// Facing (yaw) for an agent seated at each zone anchor.
    static let zoneYaw: [HQOfficeArchetype: Float] = [
        .executive:       .pi,          // behind the desk, facing the floor
        .command:         0,            // facing the globe
        .researchLab:     -.pi / 2,     // outboard of the desk, facing center
        .engineeringDen:  .pi / 2,
        .commandEast:     1.117,        // atan2(3.9, 1.9) — facing the globe
        .commandWest:     -1.117,
        .researchLab2:    -.pi / 2,
        .engineeringDen2: .pi / 2,
        .lounge:          .pi,          // facing the lounge table
    ]

    // MARK: Public entry

    static func buildEnvironment(into scene: SCNScene) {
        scene.background.contents = navyDeep
        scene.fogStartDistance = 42
        scene.fogEndDistance = 95
        scene.fogColor = navyDeep

        let root = scene.rootNode
        addFloorAndSeams(to: root)
        addCommandCenter(to: root)
        addExecutiveWing(to: root)
        addPod(to: root, x: -8.2, accent: steel)
        addPod(to: root, x: 8.2, accent: emerald)
        addMechsAndLounge(to: root)
        addPerimeter(to: root)
        addCeiling(to: root)
        addLights(to: root)
        addLiveSurfaces(to: root)
        applyDaylight(root: root, hour: Calendar.current.component(.hour, from: Date()))
    }

    // MARK: Live surfaces — the company's real data, physically in the room

    private static func addLiveSurfaces(to root: SCNNode) {
        // War Board on the east wall: initiatives, stages, progress.
        let warBoard = HQLiveBoards.warBoardNode()
        warBoard.position = SCNVector3(19.68, 2.6, -1.5)
        warBoard.eulerAngles.y = -.pi / 2
        root.addChildNode(warBoard)

        // Kanban on the west wall: the task backlog.
        let kanban = HQLiveBoards.kanbanNode()
        kanban.position = SCNVector3(-19.68, 2.5, -1.5)
        kanban.eulerAngles.y = .pi / 2
        root.addChildNode(kanban)

        // News ticker riding the north wall, above the skyline band.
        let ticker = HQLiveBoards.tickerNode()
        ticker.position = SCNVector3(0, 4.78, -15.22)
        root.addChildNode(ticker)

        // Decision Desk by the executive steps — where gates wait for the owner.
        let desk = HQLiveBoards.gateDeskNode()
        desk.position = SCNVector3(-4.9, 0, -4.7)
        root.addChildNode(desk)
    }

    /// Subtle time-of-day: warmer, brighter ambience through working hours;
    /// the proven cool night rig after dark. Safe to re-apply on every refresh.
    static func applyDaylight(root: SCNNode, hour: Int) {
        let day = (7...18).contains(hour)
        let dusk = (19...21).contains(hour) || (5...6).contains(hour)
        if let ambient = root.childNode(withName: "hq.light.ambient", recursively: false)?.light {
            ambient.intensity = day ? 430 : dusk ? 385 : 340
            ambient.color = day
                ? UIColor(red: 0.28, green: 0.30, blue: 0.36, alpha: 1)
                : UIColor(red: 0.18, green: 0.22, blue: 0.33, alpha: 1)
        }
        if let sun = root.childNode(withName: "hq.light.sun", recursively: false)?.light {
            sun.intensity = day ? 520 : dusk ? 430 : 350
            sun.color = day
                ? UIColor(red: 0.90, green: 0.86, blue: 0.78, alpha: 1)
                : UIColor(red: 0.65, green: 0.75, blue: 0.95, alpha: 1)
        }
    }

    // MARK: Floor + seams

    private static func addFloorAndSeams(to root: SCNNode) {
        let floorGeo = SCNBox(width: 60, height: 0.3, length: 60, chamferRadius: 0)
        let floorMat = SCNMaterial()
        floorMat.lightingModel = .physicallyBased
        floorMat.diffuse.contents = UIColor(red: 0.03, green: 0.038, blue: 0.055, alpha: 1)
        floorMat.metalness.contents = 0.2
        floorMat.roughness.contents = 0.55
        floorGeo.materials = [floorMat]
        let floorNode = SCNNode(geometry: floorGeo)
        floorNode.position = SCNVector3(0, -0.15, 0)
        root.addChildNode(floorNode)

        func seam(_ w: CGFloat, _ l: CGFloat, _ x: Float, _ z: Float) {
            let g = SCNBox(width: w, height: 0.015, length: l, chamferRadius: 0)
            let m = SCNMaterial()
            m.diffuse.contents = UIColor.black
            m.emission.contents = emerald
            g.materials = [m]
            let n = SCNNode(geometry: g)
            n.position = SCNVector3(x, 0.012, z)
            n.opacity = 0.75
            root.addChildNode(n)
        }
        seam(0.09, 34, -6, 0); seam(0.09, 34, 6, 0)
        seam(34, 0.09, 0, -6); seam(34, 0.09, 0, 6)
    }

    // MARK: Central command — dais, console ring, holo globe

    private static func addCommandCenter(to root: SCNNode) {
        let dais = SCNCylinder(radius: 4.6, height: 0.22)
        let daisMat = SCNMaterial()
        daisMat.lightingModel = .physicallyBased
        daisMat.diffuse.contents = surface
        daisMat.metalness.contents = 0.3
        daisMat.roughness.contents = 0.45
        dais.materials = [daisMat]
        let daisNode = SCNNode(geometry: dais)
        daisNode.position = SCNVector3(0, 0.11, 0)
        root.addChildNode(daisNode)

        let ring = SCNTorus(ringRadius: 4.6, pipeRadius: 0.035)
        let rm = SCNMaterial()
        rm.diffuse.contents = UIColor.black
        rm.emission.contents = emeraldHot
        rm.emission.intensity = 1.7
        ring.materials = [rm]
        let ringNode = SCNNode(geometry: ring)
        ringNode.position = SCNVector3(0, 0.22, 0)
        root.addChildNode(ringNode)

        // Console ring facing the globe.
        for i in 0..<6 {
            let a = Float(i) / 6 * 2 * .pi + .pi / 6
            let console = HQAssetLibrary.node(named: "ComputerLarge", height: 1.5, recolorYellowTo: emerald)
                ?? fallbackBox(w: 0.7, h: 1.5, l: 0.5, color: surface)
            place(console, sin(a) * 3.4, cos(a) * 3.4, rotY: a + .pi, in: root)
        }

        // Holographic globe: wireframe shell + translucent nucleus, slow spin.
        let globe = SCNSphere(radius: 1.05)
        let gm = SCNMaterial()
        gm.diffuse.contents = UIColor(red: 0.05, green: 0.3, blue: 0.22, alpha: 1)
        gm.emission.contents = UIColor(red: 0.10, green: 0.55, blue: 0.38, alpha: 1)
        gm.emission.intensity = 1.3
        gm.fillMode = .lines
        gm.isDoubleSided = true
        globe.materials = [gm]
        let globeNode = SCNNode(geometry: globe)
        globeNode.position = SCNVector3(0, 2.3, 0)
        globeNode.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 26)))
        root.addChildNode(globeNode)

        let core = SCNSphere(radius: 0.42)
        let cm = SCNMaterial()
        cm.diffuse.contents = UIColor.black
        cm.emission.contents = emerald
        cm.emission.intensity = 1.2
        cm.transparency = 0.85
        core.materials = [cm]
        let coreNode = SCNNode(geometry: core)
        coreNode.position = SCNVector3(0, 2.3, 0)
        root.addChildNode(coreNode)
    }

    // MARK: Executive wing — raised penthouse against the skyline

    private static func addExecutiveWing(to root: SCNNode) {
        let platform = SCNBox(width: 16, height: 1.1, length: 8.5, chamferRadius: 0.1)
        let pm = SCNMaterial()
        pm.lightingModel = .physicallyBased
        pm.diffuse.contents = UIColor(red: 0.05, green: 0.06, blue: 0.085, alpha: 1)
        pm.metalness.contents = 0.25
        pm.roughness.contents = 0.5
        platform.materials = [pm]
        let platNode = SCNNode(geometry: platform)
        platNode.position = SCNVector3(0, 0.55, execZ)
        root.addChildNode(platNode)

        // Gold rim: four thin emissive edges framing the platform (not a slab).
        let rimMat = SCNMaterial()
        rimMat.diffuse.contents = UIColor.black
        rimMat.emission.contents = gold
        func rim(_ w: CGFloat, _ l: CGFloat, _ x: Float, _ z: Float) {
            let g = SCNBox(width: w, height: 0.05, length: l, chamferRadius: 0.02)
            g.materials = [rimMat]
            let n = SCNNode(geometry: g)
            n.position = SCNVector3(x, 1.12, z)
            root.addChildNode(n)
        }
        rim(16.1, 0.08, 0, execZ + 4.26)
        rim(16.1, 0.08, 0, execZ - 4.26)
        rim(0.08, 8.6, -8.02, execZ)
        rim(0.08, 8.6, 8.02, execZ)

        // Furniture on the platform (y = platform top).
        let execRoot = SCNNode()
        execRoot.position = SCNVector3(0, 1.1, 0)
        root.addChildNode(execRoot)
        placeAsset("Desk", height: 1.05, accent: gold, at: (0, execZ + 0.8), in: execRoot)
        placeAsset("OfficeChair", height: 1.15, accent: gold, at: (0, execZ - 0.6), rotY: .pi, in: execRoot)
        placeAsset("BookcaseBooks", height: 2.1, accent: nil, at: (-5.5, execZ - 2.6), in: execRoot)
        placeAsset("BookcaseBooks", height: 2.1, accent: nil, at: (5.5, execZ - 2.6), in: execRoot)
        placeAsset("Sofa", height: 0.95, accent: gold, at: (-4.5, execZ + 1.6), rotY: .pi / 2.4, in: execRoot)

        // Skyline window band: the real night-city photograph, framed by
        // slim mullions. Falls back to a deep-navy glass band.
        let sky = SCNPlane(width: 15, height: 3.4)
        let skm = SCNMaterial()
        skm.diffuse.contents = UIColor.black
        if let image = HQAssetLibrary.skylineImage() {
            skm.emission.contents = image
            skm.emission.intensity = 1.1
        } else {
            skm.emission.contents = UIColor(red: 0.10, green: 0.16, blue: 0.30, alpha: 1)
        }
        sky.materials = [skm]
        let windowBand = SCNNode(geometry: sky)
        windowBand.position = SCNVector3(0, 3.2, execZ - 4.1)
        root.addChildNode(windowBand)

        let mullionMat = SCNMaterial()
        mullionMat.lightingModel = .physicallyBased
        mullionMat.diffuse.contents = UIColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1)
        mullionMat.metalness.contents = 0.6
        mullionMat.roughness.contents = 0.35
        for i in 0...5 {
            let mull = SCNBox(width: 0.09, height: 3.4, length: 0.1, chamferRadius: 0)
            mull.materials = [mullionMat]
            let mn = SCNNode(geometry: mull)
            mn.position = SCNVector3(Float(i) * 3.0 - 7.5, 3.2, execZ - 4.05)
            root.addChildNode(mn)
        }
    }

    // MARK: Department pods — desks, machines, status totems

    private static func addPod(to root: SCNNode, x: Float, accent: UIColor) {
        let z: Float = 3.5
        for i in 0..<2 {
            let dz = z + Float(i) * 2.4
            placeAsset("Desk", height: 1.0, accent: accent, at: (x, dz),
                       rotY: x < 0 ? .pi / 2 : -.pi / 2, in: root)
            placeAsset("Computer", height: 0.55, accent: accent, at: (x, dz),
                       rotY: x < 0 ? .pi / 2 : -.pi / 2, in: root)
        }
        // Status display totems along the outer edge.
        for i in 0..<3 {
            let body = SCNBox(width: 1.9, height: 2.6, length: 0.16, chamferRadius: 0.03)
            let bm = SCNMaterial()
            bm.lightingModel = .physicallyBased
            bm.diffuse.contents = UIColor(red: 0.07, green: 0.085, blue: 0.115, alpha: 1)
            bm.metalness.contents = 0.4
            bm.roughness.contents = 0.4
            body.materials = [bm]
            let totem = SCNNode(geometry: body)
            totem.position = SCNVector3(x + (x < 0 ? -2.2 : 2.2), 1.3, z + Float(i) * 2.4)
            totem.eulerAngles.y = x < 0 ? .pi / 2 : -.pi / 2
            root.addChildNode(totem)

            let screen = SCNPlane(width: 1.6, height: 1.0)
            let sm = SCNMaterial()
            sm.diffuse.contents = UIColor.black
            sm.emission.contents = accent
            sm.emission.intensity = 1.2
            sm.isDoubleSided = true
            screen.materials = [sm]
            let sn = SCNNode(geometry: screen)
            sn.position = SCNVector3(0, 0.55, 0.09)
            totem.addChildNode(sn)
        }
    }

    // MARK: Security mechs + lounge

    private static func addMechsAndLounge(to root: SCNNode) {
        if let stan = HQAssetLibrary.node(named: "Stan", height: 2.3, isCharacter: true) {
            HQAssetLibrary.playAnimation(matching: "Idle", under: stan)
            place(stan, -6.8, 6.2, rotY: .pi * 0.6, in: root)
        }
        if let mike = HQAssetLibrary.node(named: "Mike", height: 2.3, isCharacter: true) {
            HQAssetLibrary.playAnimation(matching: "Idle", under: mike)
            place(mike, 6.8, 6.2, rotY: -.pi * 0.735, in: root)
        }
        placeAsset("Table2", height: 0.72, accent: nil, at: (0, 9), in: root)
        placeAsset("Sofa", height: 0.95, accent: nil, at: (-2.1, 9), rotY: .pi / 2, in: root)
        placeAsset("Sofa", height: 0.95, accent: nil, at: (2.1, 9), rotY: -.pi / 2, in: root)
    }

    // MARK: Perimeter walls + emissive trim

    private static func addPerimeter(to root: SCNNode) {
        let wallMat = SCNMaterial()
        wallMat.lightingModel = .physicallyBased
        wallMat.diffuse.contents = UIColor(red: 0.045, green: 0.055, blue: 0.08, alpha: 1)
        wallMat.metalness.contents = 0.15
        wallMat.roughness.contents = 0.6

        for z in [Float(-15.5), 15.5] {
            let wall = SCNBox(width: 40, height: 5.5, length: 0.4, chamferRadius: 0)
            wall.materials = [wallMat]
            let n = SCNNode(geometry: wall)
            n.position = SCNVector3(0, 2.75, z)
            root.addChildNode(n)

            let trim = SCNBox(width: 40, height: 0.05, length: 0.42, chamferRadius: 0)
            let tm = SCNMaterial()
            tm.diffuse.contents = UIColor.black
            tm.emission.contents = emerald
            trim.materials = [tm]
            let tn = SCNNode(geometry: trim)
            tn.position = SCNVector3(0, 1.15, z)
            tn.opacity = 0.8
            root.addChildNode(tn)
        }
        for x in [Float(-20), 20] {
            let wall = SCNBox(width: 0.4, height: 5.5, length: 31.5, chamferRadius: 0)
            wall.materials = [wallMat]
            let n = SCNNode(geometry: wall)
            n.position = SCNVector3(x, 2.75, 0)
            root.addChildNode(n)
        }
    }

    // MARK: Ceiling light panels

    private static func addCeiling(to root: SCNNode) {
        // Single-sided, facing DOWN only — double-sided panels render their top
        // faces as giant floating white slabs under the elevated overview camera.
        for gx in [Float(-9.5), 0, 9.5] {
            for gz in [Float(-9.5), 0, 9.5] {
                let p = SCNPlane(width: 2.6, height: 2.6)
                let m = SCNMaterial()
                m.diffuse.contents = UIColor.black
                m.emission.contents = UIColor(red: 0.75, green: 0.85, blue: 1.0, alpha: 1)
                m.emission.intensity = 1.1
                m.isDoubleSided = false
                p.materials = [m]
                let n = SCNNode(geometry: p)
                n.position = SCNVector3(gx, 5.4, gz)
                n.eulerAngles.x = .pi / 2   // +90° about X maps the +Z normal to −Y (down)
                root.addChildNode(n)
            }
        }
    }

    // MARK: Light rig (proven: emissives don't illuminate — real lights do)

    private static func addLights(to root: SCNNode) {
        func light(_ type: SCNLight.LightType, _ color: UIColor, _ intensity: CGFloat,
                   pos: SCNVector3, lookAt: SCNVector3? = nil, shadows: Bool = false) {
            let l = SCNLight()
            l.type = type
            l.color = color
            l.intensity = intensity
            if shadows { l.castsShadow = true; l.shadowRadius = 10; l.shadowSampleCount = 8 }
            if type == .spot { l.spotOuterAngle = 46 }
            let n = SCNNode()
            n.light = l
            n.position = pos
            if let t = lookAt { n.look(at: t) }
            root.addChildNode(n)
        }

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor(red: 0.18, green: 0.22, blue: 0.33, alpha: 1)
        ambient.intensity = 340
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        ambientNode.name = "hq.light.ambient"   // named → time-of-day retune
        root.addChildNode(ambientNode)

        let sun = SCNLight()
        sun.type = .directional
        sun.color = UIColor(red: 0.65, green: 0.75, blue: 0.95, alpha: 1)
        sun.intensity = 350
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.name = "hq.light.sun"           // named → time-of-day retune
        sunNode.eulerAngles = SCNVector3(-Float.pi / 2.6, 0.4, 0)
        root.addChildNode(sunNode)

        // Real downlights under the lit ceiling panels (quincunx — five omnis
        // keep the mobile GPU budget sane vs. the Mac rig's nine).
        for (gx, gz) in [(Float(0), Float(0)), (-9.5, -9.5), (9.5, -9.5), (-9.5, 9.5), (9.5, 9.5)] {
            let dl = SCNLight()
            dl.type = .omni
            dl.color = UIColor(red: 0.72, green: 0.82, blue: 1.0, alpha: 1)
            dl.intensity = 250
            dl.attenuationStartDistance = 2
            dl.attenuationEndDistance = 20
            let dn = SCNNode()
            dn.light = dl
            dn.position = SCNVector3(gx, 4.9, gz)
            root.addChildNode(dn)
        }

        light(.spot, UIColor(red: 1.0, green: 0.87, blue: 0.65, alpha: 1), 140,
              pos: SCNVector3(0, 8, execZ + 3), lookAt: SCNVector3(0, 1, execZ + 0.5), shadows: true)
        light(.omni, emerald, 750, pos: SCNVector3(0, 4.0, 0))
        light(.spot, UIColor(red: 0.7, green: 0.8, blue: 1.0, alpha: 1), 650,
              pos: SCNVector3(0, 12, 10), lookAt: SCNVector3(0, 0, 2))
    }

    // MARK: Placement helpers

    private static func place(_ n: SCNNode, _ x: Float, _ z: Float, rotY: Float = 0, in parent: SCNNode) {
        n.position = SCNVector3(x, n.position.y, z)
        n.eulerAngles.y = rotY
        parent.addChildNode(n)
    }

    private static func placeAsset(_ name: String, height: CGFloat, accent: UIColor?,
                                   at xz: (Float, Float), rotY: Float = 0, in parent: SCNNode) {
        let node = HQAssetLibrary.node(named: name, height: height, recolorYellowTo: accent)
            ?? fallbackBox(w: height * 0.9, h: height, l: height * 0.6, color: surface)
        place(node, xz.0, xz.1, rotY: rotY, in: parent)
    }

    private static func fallbackBox(w: CGFloat, h: CGFloat, l: CGFloat, color: UIColor) -> SCNNode {
        let box = SCNBox(width: w, height: h, length: l, chamferRadius: 0.04)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = 0.3
        m.roughness.contents = 0.5
        box.materials = [m]
        let n = SCNNode(geometry: box)
        n.position = SCNVector3(0, Float(h / 2), 0)
        let wrapper = SCNNode()
        wrapper.addChildNode(n)
        return wrapper
    }
}
