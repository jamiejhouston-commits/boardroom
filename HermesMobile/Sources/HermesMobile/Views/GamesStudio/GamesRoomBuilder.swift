import SceneKit
import SwiftUI
import UIKit

/// Builds the Games Production Room — the Games Studio division's home, off the
/// Boardroom HQ floor. Same engine and the same dark-premium look-dev palette as
/// `HQSceneBuilder` (linear-P3 PBR surfaces, real light rig, emerald seams,
/// single-sided down-facing ceiling panels, fog), so it reads as one HQ.
///
/// The room's fixtures map 1:1 to the studio's real work:
///  • a giant arcade screen on the north wall showing the live build,
///  • a playtest couch with robot testers playing the game,
///  • a design whiteboard of the current game's pillars,
///  • an actually-playable arcade cabinet (tap it to play the shipped game),
///  • a lit Fun Gate arch (emerald = approved, amber = rejected),
///  • a distribution board (itch / Reddit / portals).
enum GamesRoomBuilder {

    // MARK: Palette (shared with HQ — muted, premium, never neon)

    static let emerald = HQSceneBuilder.emerald
    static let emeraldHot = HQSceneBuilder.emeraldHot
    static let gold = HQSceneBuilder.gold
    static let amber = UIColor(red: 0.86, green: 0.55, blue: 0.22, alpha: 1)
    static let navyDeep = HQSceneBuilder.navyDeep
    static let surface = HQSceneBuilder.surface
    static let graphite = UIColor(red: 0.09, green: 0.105, blue: 0.14, alpha: 1)

    // MARK: Layout — the single source of truth for placement, taps, and roam

    static let cabinetPos = SCNVector3(5.0, 0, -2.6)
    static let cabinetYaw: Float = 0.18            // screen angled toward the room center
    static let loungeCenter = SCNVector3(-5.6, 0, -1.4)
    /// Where the robot playtesters sit (facing the mega screen, -Z).
    static let testerSpots: [SCNVector3] = [
        SCNVector3(-6.9, 0, -1.9), SCNVector3(-5.6, 0, -2.0), SCNVector3(-4.3, 0, -1.9),
    ]
    static let funGateZ: Float = 3.4
    static let funGateHalfX: Float = 2.5

    // MARK: Tap-routing node names

    static let megaScreenName = "games.tap.megascreen"
    static let cabinetName = "games.tap.cabinet"
    static let funGateName = "games.tap.fungate"
    static let whiteboardName = "games.tap.whiteboard"
    static let distributionName = "games.tap.distribution"

    // Live-updated sub-nodes.
    static let funGateTrimName = "games.fungate.trim"
    static let funGateBadgeName = "games.fungate.badge"
    static let cabinetMarqueeName = "games.cabinet.marquee"
    static let cabinetScreenName = "games.cabinet.screen"
    static let pipelineCartName = "games.pipeline.cart"
    static let pipelineLampPrefix = "games.pipeline.lamp."
    static let highScoreBoardName = "games.highscores"

    // MARK: The production line — the pipeline made physical
    //
    // A conveyor runs the room's spine, straight through the Fun Gate arch;
    // one station per stage, and a glowing cart that sits at the stage the
    // current build is in. The Fun Gate station lands exactly at the arch.

    static let pipelineStages = ["concept", "design", "build", "playtest",
                                 "fun_gate", "distribution", "shipped"]
    static let pipelineStationSpacing: Float = 2.1

    static func pipelineStationZ(_ index: Int) -> Float {
        funGateZ + Float(index - 4) * pipelineStationSpacing   // fun_gate == index 4 → the arch
    }

    static func pipelineStageIndex(_ stage: String) -> Int {
        pipelineStages.firstIndex(of: stage) ?? 1   // shelved/unknown parks at design
    }

    /// What a tapped node opens.
    enum Tap { case megaScreen, cabinet, funGate, whiteboard, distribution }

    static func tap(forNodeName name: String?) -> Tap? {
        switch name {
        case megaScreenName:   .megaScreen
        case cabinetName:      .cabinet
        case funGateName:      .funGate
        case whiteboardName:   .whiteboard
        case distributionName: .distribution
        default:               nil
        }
    }

    // MARK: Public entry

    static func buildEnvironment(into scene: SCNScene) {
        scene.background.contents = navyDeep
        scene.fogStartDistance = 34
        scene.fogEndDistance = 78
        scene.fogColor = navyDeep

        let root = scene.rootNode
        addFloorAndSeams(to: root)
        addPerimeter(to: root)
        addCeiling(to: root)
        addArcadeCabinet(to: root)
        addPlaytestLounge(to: root)
        addFunGate(to: root)
        addPipeline(to: root)
        mountBoards(to: root)
        addLights(to: root)
    }

    /// The walkable field for this room (bounds + the cabinet/couch as solids).
    static func roamField() -> RoamField {
        RoamField(
            minX: -12.6, maxX: 12.6, minZ: -10.6, maxZ: 10.6,
            blockers: [
                RoamBlocker(centerX: cabinetPos.x, centerZ: cabinetPos.z, halfX: 1.2, halfZ: 1.1),
                RoamBlocker(centerX: loungeCenter.x, centerZ: loungeCenter.z, halfX: 2.4, halfZ: 1.2),
                // The coffee table sits forward of the couch (z − 1.7) — outside
                // the couch blocker — so it needs its own solid or the walker
                // clips through it.
                RoamBlocker(centerX: loungeCenter.x, centerZ: loungeCenter.z - 1.7, halfX: 0.9, halfZ: 0.6),
                // The production-line conveyor runs the room's spine — solid,
                // so the walker steps around it, not through it. Ends short of
                // the roam start (z 9.2).
                RoamBlocker(centerX: 0,
                            centerZ: (pipelineStationZ(0) + pipelineStationZ(6)) / 2,
                            halfX: 0.75,
                            halfZ: (pipelineStationZ(6) - pipelineStationZ(0)) / 2 + 0.9),
            ],
            startPosition: SIMD3(0, 1.6, 9.2),
            startYaw: 0)
    }

    static func funGateColor(approved: Bool?) -> UIColor {
        switch approved {
        case .some(true):  return emeraldHot
        case .some(false): return amber
        case .none:        return UIColor(red: 0.45, green: 0.5, blue: 0.6, alpha: 1)   // undecided steel
        }
    }

    // MARK: Floor + emerald seams

    private static func addFloorAndSeams(to root: SCNNode) {
        let floor = SCNBox(width: 30, height: 0.3, length: 26, chamferRadius: 0)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(red: 0.032, green: 0.04, blue: 0.058, alpha: 1)
        m.metalness.contents = 0.22
        m.roughness.contents = 0.5
        floor.materials = [m]
        let node = SCNNode(geometry: floor)
        node.position = SCNVector3(0, -0.15, 0)
        root.addChildNode(node)

        func seam(_ w: CGFloat, _ l: CGFloat, _ x: Float, _ z: Float) {
            let g = SCNBox(width: w, height: 0.015, length: l, chamferRadius: 0)
            let sm = SCNMaterial()
            sm.diffuse.contents = UIColor.black
            sm.emission.contents = emerald
            g.materials = [sm]
            let n = SCNNode(geometry: g)
            n.position = SCNVector3(x, 0.012, z)
            n.opacity = 0.7
            root.addChildNode(n)
        }
        // A grid framing the play space, and a bright lane leading to the cabinet.
        seam(0.08, 22, -8, 0); seam(0.08, 22, 8, 0)
        seam(26, 0.08, 0, -7.5); seam(26, 0.08, 0, 6.5)
    }

    // MARK: Perimeter walls + trim

    private static func addPerimeter(to root: SCNNode) {
        let wallMat = SCNMaterial()
        wallMat.lightingModel = .physicallyBased
        wallMat.diffuse.contents = UIColor(red: 0.043, green: 0.052, blue: 0.078, alpha: 1)
        wallMat.metalness.contents = 0.14
        wallMat.roughness.contents = 0.62

        // North + south walls (span x), east + west walls (span z).
        for z in [Float(-12), 12] {
            let wall = SCNBox(width: 28, height: 6, length: 0.4, chamferRadius: 0)
            wall.materials = [wallMat]
            let n = SCNNode(geometry: wall)
            n.position = SCNVector3(0, 3, z)
            root.addChildNode(n)
        }
        for x in [Float(-14), 14] {
            let wall = SCNBox(width: 0.4, height: 6, length: 24.4, chamferRadius: 0)
            wall.materials = [wallMat]
            let n = SCNNode(geometry: wall)
            n.position = SCNVector3(x, 3, 0)
            root.addChildNode(n)
        }
        // Emerald baseboard trim on the long walls.
        for x in [Float(-13.78), 13.78] {
            let trim = SCNBox(width: 0.05, height: 0.05, length: 24, chamferRadius: 0)
            let tm = SCNMaterial()
            tm.diffuse.contents = UIColor.black
            tm.emission.contents = emerald
            trim.materials = [tm]
            let tn = SCNNode(geometry: trim)
            tn.position = SCNVector3(x, 0.7, 0)
            tn.opacity = 0.8
            root.addChildNode(tn)
        }
    }

    // MARK: Ceiling light panels (single-sided, facing down)

    private static func addCeiling(to root: SCNNode) {
        for gx in [Float(-8), 0, 8] {
            for gz in [Float(-7), 0, 7] {
                let p = SCNPlane(width: 3.0, height: 3.0)
                let m = SCNMaterial()
                m.diffuse.contents = UIColor.black
                m.emission.contents = UIColor(red: 0.72, green: 0.82, blue: 1.0, alpha: 1)
                m.emission.intensity = 1.0
                m.isDoubleSided = false
                p.materials = [m]
                let n = SCNNode(geometry: p)
                n.position = SCNVector3(gx, 5.9, gz)
                n.eulerAngles.x = .pi / 2   // +Z normal → -Y (down)
                root.addChildNode(n)
            }
        }
    }

    // MARK: The arcade cabinet — actually playable (tap → the real game)

    private static func addArcadeCabinet(to root: SCNNode) {
        let cabinet = SCNNode()
        cabinet.name = cabinetName
        cabinet.position = cabinetPos
        cabinet.eulerAngles.y = cabinetYaw

        let bodyMat = SCNMaterial()
        bodyMat.lightingModel = .physicallyBased
        bodyMat.diffuse.contents = graphite
        bodyMat.metalness.contents = 0.5
        bodyMat.roughness.contents = 0.38

        // Main body (front face is +Z).
        let body = SCNBox(width: 1.15, height: 2.0, length: 0.85, chamferRadius: 0.05)
        body.materials = [bodyMat]
        let bodyNode = SCNNode(geometry: body)
        bodyNode.position = SCNVector3(0, 1.0, 0)
        cabinet.addChildNode(bodyNode)

        // Side accent light strips (emerald).
        for sx in [Float(-0.585), 0.585] {
            let strip = SCNBox(width: 0.02, height: 1.9, length: 0.08, chamferRadius: 0)
            let sm = SCNMaterial()
            sm.diffuse.contents = UIColor.black
            sm.emission.contents = emerald
            strip.materials = [sm]
            let n = SCNNode(geometry: strip)
            n.position = SCNVector3(sx, 1.05, 0.4)
            cabinet.addChildNode(n)
        }

        // Marquee header (angled forward, glowing title).
        let marquee = SCNBox(width: 1.16, height: 0.34, length: 0.14, chamferRadius: 0.03)
        let mm = SCNMaterial()
        mm.lightingModel = .physicallyBased
        mm.diffuse.contents = UIColor(red: 0.06, green: 0.07, blue: 0.1, alpha: 1)
        mm.metalness.contents = 0.4; mm.roughness.contents = 0.4
        marquee.materials = [mm]
        let marqueeNode = SCNNode(geometry: marquee)
        marqueeNode.position = SCNVector3(0, 2.02, 0.34)
        marqueeNode.eulerAngles.x = -0.32
        cabinet.addChildNode(marqueeNode)

        // Marquee glowing title panel (a SpriteKit label surface).
        let marqueeFace = SCNPlane(width: 1.05, height: 0.26)
        marqueeFace.materials = [GamesRoomBoards.marqueeMaterial()]
        let marqueeFaceNode = SCNNode(geometry: marqueeFace)
        marqueeFaceNode.name = cabinetMarqueeName
        marqueeFaceNode.position = SCNVector3(0, 2.04, 0.415)
        marqueeFaceNode.eulerAngles.x = -0.32
        cabinet.addChildNode(marqueeFaceNode)

        // Recessed bezel + the attract screen (live SpriteKit render).
        let bezel = SCNBox(width: 1.0, height: 0.86, length: 0.06, chamferRadius: 0.02)
        let bez = SCNMaterial()
        bez.diffuse.contents = UIColor.black
        bez.metalness.contents = 0.2; bez.roughness.contents = 0.6
        bezel.materials = [bez]
        let bezelNode = SCNNode(geometry: bezel)
        bezelNode.position = SCNVector3(0, 1.5, 0.43)
        bezelNode.eulerAngles.x = -0.12
        cabinet.addChildNode(bezelNode)

        let screen = SCNPlane(width: 0.86, height: 0.72)
        screen.materials = [GamesRoomBoards.cabinetScreenMaterial()]
        let screenNode = SCNNode(geometry: screen)
        screenNode.name = cabinetScreenName
        screenNode.position = SCNVector3(0, 1.5, 0.47)
        screenNode.eulerAngles.x = -0.12
        cabinet.addChildNode(screenNode)

        // Control deck (angled), joystick + two buttons.
        let deck = SCNBox(width: 1.14, height: 0.1, length: 0.55, chamferRadius: 0.03)
        deck.materials = [bodyMat]
        let deckNode = SCNNode(geometry: deck)
        deckNode.position = SCNVector3(0, 0.92, 0.62)
        deckNode.eulerAngles.x = 0.5
        cabinet.addChildNode(deckNode)

        let stickBase = SCNCylinder(radius: 0.05, height: 0.14)
        let stickMat = SCNMaterial(); stickMat.diffuse.contents = UIColor.black
        stickMat.metalness.contents = 0.6; stickMat.roughness.contents = 0.3
        stickBase.materials = [stickMat]
        let stickNode = SCNNode(geometry: stickBase)
        stickNode.position = SCNVector3(-0.28, 0.99, 0.6)
        stickNode.eulerAngles.x = 0.5
        cabinet.addChildNode(stickNode)
        let ball = SCNSphere(radius: 0.055)
        let ballMat = SCNMaterial(); ballMat.diffuse.contents = UIColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1)
        ballMat.lightingModel = .physicallyBased; ballMat.roughness.contents = 0.4
        ball.materials = [ballMat]
        let ballNode = SCNNode(geometry: ball)
        ballNode.position = SCNVector3(-0.28, 1.06, 0.53)
        cabinet.addChildNode(ballNode)

        for (i, color) in [emerald, gold].enumerated() {
            let btn = SCNCylinder(radius: 0.05, height: 0.05)
            let bm = SCNMaterial()
            bm.diffuse.contents = UIColor.black
            bm.emission.contents = color
            bm.emission.intensity = 0.9
            btn.materials = [bm]
            let n = SCNNode(geometry: btn)
            n.position = SCNVector3(0.12 + Float(i) * 0.22, 1.0, 0.58)
            n.eulerAngles.x = 0.5
            cabinet.addChildNode(n)
        }

        // A low pedestal + a spotlight to make the cabinet the room's hero.
        let dais = SCNCylinder(radius: 1.5, height: 0.12)
        let dm = SCNMaterial()
        dm.lightingModel = .physicallyBased
        dm.diffuse.contents = surface
        dm.metalness.contents = 0.3; dm.roughness.contents = 0.45
        dais.materials = [dm]
        let daisNode = SCNNode(geometry: dais)
        daisNode.position = SCNVector3(0, 0.06, 0.1)
        cabinet.addChildNode(daisNode)

        let ring = SCNTorus(ringRadius: 1.5, pipeRadius: 0.02)
        let rm = SCNMaterial()
        rm.diffuse.contents = UIColor.black; rm.emission.contents = emeraldHot
        rm.emission.intensity = 1.4
        ring.materials = [rm]
        let ringNode = SCNNode(geometry: ring)
        ringNode.position = SCNVector3(0, 0.12, 0.1)
        cabinet.addChildNode(ringNode)

        root.addChildNode(cabinet)
    }

    // MARK: Playtest lounge — couch + robot testers

    private static func addPlaytestLounge(to root: SCNNode) {
        // Couch (behind the testers, opening toward the mega screen).
        let couch = HQAssetLibrary.node(named: "Sofa", height: 1.0, recolorYellowTo: nil)
            ?? fallbackBox(w: 2.6, h: 0.9, l: 1.0, color: surface)
        couch.position = SCNVector3(loungeCenter.x, couch.position.y, loungeCenter.z + 0.7)
        couch.eulerAngles.y = 0                     // faces -Z (toward the screen)
        root.addChildNode(couch)

        // A low table with a scattering of "controllers".
        let table = HQAssetLibrary.node(named: "Table2", height: 0.5, recolorYellowTo: nil)
            ?? fallbackBox(w: 1.4, h: 0.5, l: 0.8, color: graphite)
        table.position = SCNVector3(loungeCenter.x, table.position.y, loungeCenter.z - 1.7)
        root.addChildNode(table)

        // A rug of light under the lounge.
        let rug = SCNPlane(width: 5.2, height: 3.4)
        let rugMat = SCNMaterial()
        rugMat.diffuse.contents = UIColor.black
        rugMat.emission.contents = emerald
        rugMat.emission.intensity = 0.25
        rug.materials = [rugMat]
        let rugNode = SCNNode(geometry: rug)
        rugNode.position = SCNVector3(loungeCenter.x, 0.02, loungeCenter.z)
        rugNode.eulerAngles.x = -.pi / 2
        root.addChildNode(rugNode)
    }

    // MARK: Fun Gate — a lit arch the game passes through

    private static func addFunGate(to root: SCNNode) {
        let gate = SCNNode()
        gate.name = funGateName
        gate.position = SCNVector3(0, 0, funGateZ)

        let postMat = SCNMaterial()
        postMat.lightingModel = .physicallyBased
        postMat.diffuse.contents = graphite
        postMat.metalness.contents = 0.55; postMat.roughness.contents = 0.35

        let height: Float = 3.6
        for sx in [-funGateHalfX, funGateHalfX] {
            let post = SCNBox(width: 0.32, height: CGFloat(height), length: 0.32, chamferRadius: 0.04)
            post.materials = [postMat]
            let n = SCNNode(geometry: post)
            n.position = SCNVector3(sx, height / 2, 0)
            gate.addChildNode(n)
        }
        // Crossbar.
        let bar = SCNBox(width: CGFloat(funGateHalfX * 2 + 0.32), height: 0.4, length: 0.32, chamferRadius: 0.04)
        bar.materials = [postMat]
        let barNode = SCNNode(geometry: bar)
        barNode.position = SCNVector3(0, height, 0)
        gate.addChildNode(barNode)

        // Inner emissive trim (verdict color — recolored live).
        let trimMat = SCNMaterial()
        trimMat.diffuse.contents = UIColor.black
        trimMat.emission.contents = funGateColor(approved: nil)
        trimMat.emission.intensity = 1.2
        func trim(_ w: CGFloat, _ h: CGFloat, _ x: Float, _ y: Float) {
            let g = SCNBox(width: w, height: h, length: 0.05, chamferRadius: 0)
            g.materials = [trimMat]
            let n = SCNNode(geometry: g)
            n.name = funGateTrimName
            n.position = SCNVector3(x, y, 0.17)
            gate.addChildNode(n)
        }
        trim(0.06, CGFloat(height - 0.4), -funGateHalfX + 0.15, (height - 0.4) / 2)
        trim(0.06, CGFloat(height - 0.4), funGateHalfX - 0.15, (height - 0.4) / 2)
        trim(CGFloat(funGateHalfX * 2 - 0.3), 0.06, 0, height - 0.2)

        // "FUN GATE" plaque on the crossbar + a verdict badge below it.
        let plaque = SCNPlane(width: 2.6, height: 0.5)
        plaque.materials = [GamesRoomBoards.funGatePlaqueMaterial()]
        let plaqueNode = SCNNode(geometry: plaque)
        plaqueNode.name = funGateBadgeName
        plaqueNode.position = SCNVector3(0, height + 0.45, 0.05)
        gate.addChildNode(plaqueNode)

        root.addChildNode(gate)
    }

    // MARK: The production line — conveyor, stations, and the live cart

    private static func addPipeline(to root: SCNNode) {
        let line = SCNNode()
        root.addChildNode(line)

        let beltStart = pipelineStationZ(0) - 0.9
        let beltEnd = pipelineStationZ(6) + 0.9
        let beltLength = CGFloat(beltEnd - beltStart)
        let beltCenterZ = (beltStart + beltEnd) / 2

        // Belt bed + emissive rails down both edges.
        let bed = SCNBox(width: 0.95, height: 0.14, length: beltLength, chamferRadius: 0.04)
        let bedMat = SCNMaterial()
        bedMat.lightingModel = .physicallyBased
        bedMat.diffuse.contents = graphite
        bedMat.metalness.contents = 0.5
        bedMat.roughness.contents = 0.4
        bed.materials = [bedMat]
        let bedNode = SCNNode(geometry: bed)
        bedNode.position = SCNVector3(0, 0.07, beltCenterZ)
        line.addChildNode(bedNode)

        for sx in [Float(-0.44), 0.44] {
            let rail = SCNBox(width: 0.04, height: 0.02, length: beltLength - 0.1, chamferRadius: 0)
            let rm = SCNMaterial()
            rm.diffuse.contents = UIColor.black
            rm.emission.contents = emerald
            rm.emission.intensity = 0.8
            rail.materials = [rm]
            let rn = SCNNode(geometry: rail)
            rn.position = SCNVector3(sx, 0.15, beltCenterZ)
            line.addChildNode(rn)
        }

        // One station per stage: a lamp puck beside the belt + a floor label.
        // Lamps are named per stage so the live update relights them.
        for (index, stage) in pipelineStages.enumerated() {
            let z = pipelineStationZ(index)

            let puck = SCNCylinder(radius: 0.16, height: 0.05)
            let pm = SCNMaterial()
            pm.diffuse.contents = UIColor.black
            pm.emission.contents = UIColor(red: 0.45, green: 0.5, blue: 0.6, alpha: 1)
            pm.emission.intensity = 0.3
            puck.materials = [pm]
            let puckNode = SCNNode(geometry: puck)
            puckNode.name = pipelineLampPrefix + stage
            puckNode.position = SCNVector3(0.75, 0.03, z)
            line.addChildNode(puckNode)

            let text = SCNText(string: stageSign(stage), extrusionDepth: 0.2)
            text.font = UIFont.systemFont(ofSize: 5, weight: .semibold)
            text.flatness = 0.2
            let tm = SCNMaterial()
            tm.diffuse.contents = UIColor.black
            tm.emission.contents = gold
            tm.emission.intensity = 0.75
            text.materials = [tm]
            let textNode = SCNNode(geometry: text)
            textNode.scale = SCNVector3(0.032, 0.032, 0.032)
            let (lo, hi) = textNode.boundingBox
            textNode.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, 0, 0)
            // Flat on the floor beside the lamp, readable from the south entry.
            textNode.position = SCNVector3(1.6, 0.02, z)
            textNode.eulerAngles.x = -.pi / 2
            line.addChildNode(textNode)
        }

        // The cart — the current build made physical: a glowing crate that
        // hovers over the belt and rides to whichever station the game is in.
        let cart = SCNNode()
        cart.name = pipelineCartName
        cart.position = SCNVector3(0, 0.42, pipelineStationZ(0))

        // The visible body bobs on its own child node so the idle bob never
        // fights the absolute ride-to-station move on the cart itself.
        let body = SCNNode()
        cart.addChildNode(body)

        let crate = SCNBox(width: 0.52, height: 0.36, length: 0.52, chamferRadius: 0.06)
        let crateMat = SCNMaterial()
        crateMat.lightingModel = .physicallyBased
        crateMat.diffuse.contents = surface
        crateMat.metalness.contents = 0.45
        crateMat.roughness.contents = 0.35
        crate.materials = [crateMat]
        body.addChildNode(SCNNode(geometry: crate))

        let band = SCNBox(width: 0.54, height: 0.05, length: 0.54, chamferRadius: 0.02)
        let bandMat = SCNMaterial()
        bandMat.diffuse.contents = UIColor.black
        bandMat.emission.contents = emeraldHot
        bandMat.emission.intensity = 1.3
        band.materials = [bandMat]
        body.addChildNode(SCNNode(geometry: band))

        // A gentle idle bob so the line always reads alive.
        let bob = SCNAction.sequence([
            .moveBy(x: 0, y: 0.08, z: 0, duration: 1.1),
            .moveBy(x: 0, y: -0.08, z: 0, duration: 1.1),
        ])
        bob.timingMode = .easeInEaseOut
        body.runAction(.repeatForever(bob))
        line.addChildNode(cart)
    }

    private static func stageSign(_ stage: String) -> String {
        switch stage {
        case "concept":      "CONCEPT"
        case "design":       "DESIGN"
        case "build":        "BUILD"
        case "playtest":     "PLAYTEST"
        case "fun_gate":     "FUN GATE"
        case "distribution": "DISTRIBUTE"
        default:             "SHIPPED"
        }
    }

    /// Ride the cart to the station for `stage` and relight the lamps: done
    /// stages glow soft emerald, the live one burns hot, the future stays dim.
    static func updatePipeline(root: SCNNode, stage: String) {
        let index = pipelineStageIndex(stage)
        if let cart = root.childNode(withName: pipelineCartName, recursively: true) {
            let ride = SCNAction.move(
                to: SCNVector3(0, cart.position.y, pipelineStationZ(index)),
                duration: 1.4)
            ride.timingMode = .easeInEaseOut
            cart.runAction(ride, forKey: "ride")
        }
        for (i, name) in pipelineStages.enumerated() {
            guard let lamp = root.childNode(withName: pipelineLampPrefix + name, recursively: true),
                  let material = lamp.geometry?.firstMaterial else { continue }
            if i < index {
                material.emission.contents = emerald
                material.emission.intensity = 0.7
            } else if i == index {
                material.emission.contents = emeraldHot
                material.emission.intensity = 1.5
            } else {
                material.emission.contents = UIColor(red: 0.45, green: 0.5, blue: 0.6, alpha: 1)
                material.emission.intensity = 0.3
            }
        }
    }

    // MARK: Live wall surfaces

    private static func mountBoards(to root: SCNNode) {
        // The giant arcade screen — north wall, centered, the live build.
        let mega = GamesRoomBoards.megaScreenNode()
        mega.position = SCNVector3(0, 3.35, -11.78)
        root.addChildNode(mega)

        // Design whiteboard — west wall.
        let board = GamesRoomBoards.whiteboardNode()
        board.position = SCNVector3(-13.78, 2.7, -4.2)
        board.eulerAngles.y = .pi / 2
        root.addChildNode(board)

        // Distribution board — east wall.
        let dist = GamesRoomBoards.distributionNode()
        dist.position = SCNVector3(13.78, 2.5, -3.4)
        dist.eulerAngles.y = -.pi / 2
        root.addChildNode(dist)

        // High-score wall — east wall, south of distribution, by the cabinet.
        let scores = GamesRoomBoards.highScoresNode()
        scores.position = SCNVector3(13.78, 2.5, 3.6)
        scores.eulerAngles.y = -.pi / 2
        root.addChildNode(scores)
    }

    // MARK: Light rig (real lights — emissives don't illuminate)

    private static func addLights(to root: SCNNode) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor(red: 0.2, green: 0.24, blue: 0.34, alpha: 1)
        ambient.intensity = 360
        let ambientNode = SCNNode(); ambientNode.light = ambient
        root.addChildNode(ambientNode)

        let sun = SCNLight()
        sun.type = .directional
        sun.color = UIColor(red: 0.7, green: 0.78, blue: 0.96, alpha: 1)
        sun.intensity = 360
        let sunNode = SCNNode(); sunNode.light = sun
        sunNode.eulerAngles = SCNVector3(-Float.pi / 2.6, 0.5, 0)
        root.addChildNode(sunNode)

        // Downlights under the lit ceiling panels (quincunx, mobile-safe).
        for (gx, gz) in [(Float(0), Float(0)), (-8, -7), (8, -7), (-8, 7), (8, 7)] {
            let dl = SCNLight()
            dl.type = .omni
            dl.color = UIColor(red: 0.74, green: 0.83, blue: 1.0, alpha: 1)
            dl.intensity = 240
            dl.attenuationStartDistance = 2
            dl.attenuationEndDistance = 18
            let n = SCNNode(); n.light = dl
            n.position = SCNVector3(gx, 5.4, gz)
            root.addChildNode(n)
        }

        // Hero spot on the arcade cabinet.
        let spot = SCNLight()
        spot.type = .spot
        spot.color = UIColor(red: 0.65, green: 0.95, blue: 0.8, alpha: 1)
        spot.intensity = 900
        spot.spotOuterAngle = 40
        spot.castsShadow = true
        spot.shadowRadius = 8
        let spotNode = SCNNode(); spotNode.light = spot
        spotNode.position = SCNVector3(cabinetPos.x, 6.5, cabinetPos.z + 3)
        spotNode.look(at: SCNVector3(cabinetPos.x, 1.4, cabinetPos.z))
        root.addChildNode(spotNode)

        // A warm wash on the playtest lounge.
        let wash = SCNLight()
        wash.type = .omni
        wash.color = emerald
        wash.intensity = 420
        wash.attenuationEndDistance = 10
        let washNode = SCNNode(); washNode.light = wash
        washNode.position = SCNVector3(loungeCenter.x, 3.2, loungeCenter.z)
        root.addChildNode(washNode)

        // Backlight on the mega screen wall so it doesn't fall into fog-black.
        let back = SCNLight()
        back.type = .omni
        back.color = UIColor(red: 0.5, green: 0.7, blue: 1.0, alpha: 1)
        back.intensity = 300
        back.attenuationEndDistance = 14
        let backNode = SCNNode(); backNode.light = back
        backNode.position = SCNVector3(0, 4, -8)
        root.addChildNode(backNode)
    }

    // MARK: Helpers

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
