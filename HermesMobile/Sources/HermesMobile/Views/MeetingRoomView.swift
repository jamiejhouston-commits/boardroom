import SceneKit
import SwiftUI
import UIKit

// MARK: - 3D conference room — cinematic boardroom (round holo-table, skyline
// glass, live dashboard wall) modeled on the user's reference render.

struct MeetingRoomSceneView: UIViewRepresentable {
    var attendees: [OrgAgent]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.006, green: 0.012, blue: 0.025, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.isPlaying = true
        view.scene = MeetingSceneBuilder.scene(attendees: attendees)
        context.coordinator.attach(to: view, ids: attendees.map(\.id))
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let ids = attendees.map(\.id)
        guard ids != context.coordinator.ids else { return }
        uiView.scene = MeetingSceneBuilder.scene(attendees: attendees)
        context.coordinator.attach(to: uiView, ids: ids)
    }

    /// Tracks attendees and lights up the speaking agent's seat console
    /// during a live debate.
    final class Coordinator: NSObject {
        var ids: [String] = []
        private weak var view: SCNView?

        func attach(to view: SCNView, ids: [String]) {
            self.view = view
            self.ids = ids
            NotificationCenter.default.removeObserver(self)
            NotificationCenter.default.addObserver(self, selector: #selector(speakerChanged(_:)),
                                                   name: .hermesDebateSpeaker, object: nil)
        }

        @objc private func speakerChanged(_ note: Notification) {
            guard let speakingID = note.userInfo?["agentID"] as? String,
                  let root = view?.scene?.rootNode else { return }
            root.enumerateChildNodes { node, _ in
                guard let name = node.name else { return }
                if name.hasPrefix("console-") {
                    let isSpeaking = name == "console-\(speakingID)"
                    node.geometry?.firstMaterial?.emission.intensity = isSpeaking ? 1.8 : 0.6
                } else if name.hasPrefix("dot-") {
                    if name == "dot-\(speakingID)" {
                        if node.action(forKey: "speak") == nil {
                            let pulse = SCNAction.sequence([
                                .scale(to: 2.0, duration: 0.35),
                                .scale(to: 1.0, duration: 0.35)
                            ])
                            node.runAction(.repeatForever(pulse), forKey: "speak")
                        }
                    } else {
                        node.removeAction(forKey: "speak")
                        node.scale = SCNVector3(1, 1, 1)
                    }
                }
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

private enum MeetingSceneBuilder {

    // The room's signature teal — bright enough to read as light, not paint.
    private static let teal = UIColor(red: 0.16, green: 0.78, blue: 0.84, alpha: 1)
    private static let emerald = UIColor(red: 0.18, green: 0.78, blue: 0.55, alpha: 1)

    static func scene(attendees: [OrgAgent]) -> SCNScene {
        let scene = SCNScene()

        scene.lightingEnvironment.contents = environmentMap()
        scene.lightingEnvironment.intensity = 1.4
        scene.background.contents = UIColor(red: 0.006, green: 0.012, blue: 0.025, alpha: 1)
        scene.fogStartDistance = 14
        scene.fogEndDistance = 36
        scene.fogColor = UIColor(red: 0.006, green: 0.012, blue: 0.025, alpha: 1)

        addCamera(to: scene)
        addLights(to: scene)
        addFloor(to: scene)
        addCeiling(to: scene)
        addBackWall(to: scene)
        addSideWindows(to: scene)
        addTable(to: scene)
        addSeating(attendees, to: scene)
        addPlants(to: scene)
        return scene
    }

    // MARK: Camera — elevated, looking down at the table like the render

    private static func addCamera(to scene: SCNScene) {
        let camera = SCNCamera()
        camera.fieldOfView = 46
        camera.wantsHDR = true
        camera.bloomIntensity = 0.55          // tasteful cinematic glow
        camera.bloomThreshold = 0.5
        camera.bloomBlurRadius = 6
        camera.wantsExposureAdaptation = false
        camera.zFar = 90

        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(0, 5.3, 6.3)
        let target = SCNNode()
        target.position = SCNVector3(0, 0.85, -0.55)
        scene.rootNode.addChildNode(target)
        node.constraints = [SCNLookAtConstraint(target: target)]
        scene.rootNode.addChildNode(node)
    }

    private static func addLights(to scene: SCNScene) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 110
        ambient.color = UIColor(white: 0.25, alpha: 1)
        let an = SCNNode(); an.light = ambient
        scene.rootNode.addChildNode(an)

        // White spot straight down over the table — the hero light.
        let spot = SCNLight()
        spot.type = .spot
        spot.intensity = 1000
        spot.color = UIColor(white: 0.95, alpha: 1)
        spot.spotInnerAngle = 30
        spot.spotOuterAngle = 75
        spot.castsShadow = true
        spot.shadowRadius = 8
        spot.shadowColor = UIColor(white: 0, alpha: 0.6)
        let sn = SCNNode(); sn.light = spot
        sn.position = SCNVector3(0, 3.5, 0)
        sn.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(sn)

        // Cool teal washes from the dashboard wall and the windows.
        for (pos, intensity) in [(SCNVector3(0, 2.2, -3.4), 220.0), (SCNVector3(-3.8, 2.0, 0), 160.0), (SCNVector3(3.8, 2.0, 0), 160.0)] {
            let wash = SCNLight()
            wash.type = .omni
            wash.intensity = CGFloat(intensity)
            wash.color = UIColor(red: 0.35, green: 0.7, blue: 0.8, alpha: 1)
            let wn = SCNNode(); wn.light = wash
            wn.position = pos
            scene.rootNode.addChildNode(wn)
        }
    }

    // MARK: Floor — reflective, with the glowing ring inlay around the table

    private static func addFloor(to scene: SCNScene) {
        let floorGeo = SCNFloor()
        floorGeo.reflectivity = 0.3
        floorGeo.reflectionFalloffEnd = 6
        let fm = SCNMaterial()
        fm.diffuse.contents = UIColor(red: 0.018, green: 0.028, blue: 0.04, alpha: 1)
        fm.metalness.contents = 0.8
        fm.roughness.contents = 0.16
        fm.lightingModel = .physicallyBased
        floorGeo.firstMaterial = fm
        scene.rootNode.addChildNode(SCNNode(geometry: floorGeo))

        // Twin glowing rings circling the seating area (signature of the render).
        for (radius, alpha) in [(CGFloat(2.85), 0.55), (CGFloat(3.05), 0.22)] {
            let ring = SCNNode(geometry: SCNTorus(ringRadius: radius, pipeRadius: 0.012))
            ring.position = SCNVector3(0, 0.012, 0)
            ring.geometry?.firstMaterial = glow(teal.withAlphaComponent(alpha))
            scene.rootNode.addChildNode(ring)
        }
    }

    // MARK: Ceiling — circular cove ring over the table + recessed strips

    private static func addCeiling(to scene: SCNScene) {
        let ceiling = SCNNode(geometry: SCNPlane(width: 12, height: 11))
        ceiling.position = SCNVector3(0, 3.6, -0.5)
        ceiling.eulerAngles.x = .pi / 2
        ceiling.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.015, green: 0.022, blue: 0.035, alpha: 1),
                                              emission: .black, metalness: 0.2, roughness: 0.8)
        scene.rootNode.addChildNode(ceiling)

        // Halo cove above the table.
        let halo = SCNNode(geometry: SCNTorus(ringRadius: 2.1, pipeRadius: 0.03))
        halo.position = SCNVector3(0, 3.55, 0)
        halo.geometry?.firstMaterial = glow(UIColor(red: 0.5, green: 0.85, blue: 0.9, alpha: 0.8))
        scene.rootNode.addChildNode(halo)

        // Recessed linear strips toward the walls.
        for x in [Float(-3.2), 3.2] {
            let strip = SCNNode(geometry: SCNBox(width: 0.08, height: 0.03, length: 6.5, chamferRadius: 0.01))
            strip.position = SCNVector3(x, 3.56, -0.3)
            strip.geometry?.firstMaterial = glow(UIColor(red: 0.45, green: 0.8, blue: 0.85, alpha: 0.5))
            scene.rootNode.addChildNode(strip)
        }
    }

    // MARK: Back wall — the live dashboard screens

    private static func addBackWall(to scene: SCNScene) {
        let wall = SCNNode(geometry: SCNPlane(width: 11, height: 3.8))
        wall.position = SCNVector3(0, 1.85, -4.1)
        wall.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.02, green: 0.032, blue: 0.05, alpha: 1),
                                           emission: .black, metalness: 0.4, roughness: 0.5)
        scene.rootNode.addChildNode(wall)

        // Glowing baseboard along the wall.
        let base = SCNNode(geometry: SCNBox(width: 10.6, height: 0.025, length: 0.03, chamferRadius: 0))
        base.position = SCNVector3(0, 0.05, -4.05)
        base.geometry?.firstMaterial = glow(teal.withAlphaComponent(0.6))
        scene.rootNode.addChildNode(base)

        // Two big dashboard screens with REAL drawn content.
        addScreen(to: scene, texture: dashboardTexture(title: "Q2 STRATEGY REVIEW", style: .strategy),
                  center: SCNVector3(1.55, 2.05, -4.04), size: CGSize(width: 2.7, height: 1.55))
        addScreen(to: scene, texture: dashboardTexture(title: "OPERATIONS PULSE", style: .operations),
                  center: SCNVector3(-1.55, 2.05, -4.04), size: CGSize(width: 2.7, height: 1.55))
    }

    private static func addScreen(to scene: SCNScene, texture: UIImage, center: SCNVector3, size: CGSize) {
        // Bezel
        let bezel = SCNNode(geometry: SCNBox(width: size.width + 0.08, height: size.height + 0.08, length: 0.06, chamferRadius: 0.02))
        bezel.position = SCNVector3(center.x, center.y, center.z - 0.02)
        bezel.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1),
                                            emission: .black, metalness: 0.85, roughness: 0.25)
        scene.rootNode.addChildNode(bezel)

        // Panel — emissive texture so it reads as a lit display.
        let panel = SCNNode(geometry: SCNPlane(width: size.width, height: size.height))
        panel.position = SCNVector3(center.x, center.y, center.z + 0.012)
        let m = SCNMaterial()
        m.diffuse.contents = texture
        m.emission.contents = texture
        m.emission.intensity = 0.9
        m.lightingModel = .constant
        panel.geometry?.firstMaterial = m
        scene.rootNode.addChildNode(panel)

        // Thin teal edge light around the panel.
        let edge = SCNNode(geometry: SCNBox(width: size.width + 0.1, height: size.height + 0.1, length: 0.008, chamferRadius: 0.01))
        edge.position = SCNVector3(center.x, center.y, center.z - 0.045)
        edge.geometry?.firstMaterial = glow(teal.withAlphaComponent(0.35))
        scene.rootNode.addChildNode(edge)
    }

    // MARK: Side windows — floor-to-ceiling glass + drawn night skyline

    private static func addSideWindows(to scene: SCNScene) {
        let sky = skylineTexture()
        for side in [Float(-1), 1] {
            // Painted skyline behind the glass.
            let backdrop = SCNNode(geometry: SCNPlane(width: 10.5, height: 4.4))
            backdrop.position = SCNVector3(side * 4.85, 2.0, -0.5)
            backdrop.eulerAngles.y = side > 0 ? -.pi / 2 : .pi / 2
            let bm = SCNMaterial()
            bm.diffuse.contents = sky
            bm.emission.contents = sky
            bm.emission.intensity = 0.55
            bm.lightingModel = .constant
            backdrop.geometry?.firstMaterial = bm
            scene.rootNode.addChildNode(backdrop)

            // Glass with a faint blue tint + reflectivity.
            let glass = SCNNode(geometry: SCNPlane(width: 9.6, height: 3.6))
            glass.position = SCNVector3(side * 4.45, 1.8, -0.5)
            glass.eulerAngles.y = side > 0 ? -.pi / 2 : .pi / 2
            let gm = SCNMaterial()
            gm.diffuse.contents = UIColor(red: 0.4, green: 0.6, blue: 0.85, alpha: 0.05)
            gm.metalness.contents = 0.9
            gm.roughness.contents = 0.05
            gm.lightingModel = .physicallyBased
            gm.isDoubleSided = true
            gm.transparency = 0.5
            glass.geometry?.firstMaterial = gm
            scene.rootNode.addChildNode(glass)

            // Mullions.
            let frameMat = pbr(diffuse: UIColor(white: 0.4, alpha: 1), emission: .black, metalness: 0.95, roughness: 0.2)
            for k in 0...6 {
                let z = Float(k) * 1.6 - 5.3
                let mull = SCNNode(geometry: SCNBox(width: 0.04, height: 3.6, length: 0.04, chamferRadius: 0))
                mull.position = SCNVector3(side * 4.45, 1.8, z)
                mull.geometry?.firstMaterial = frameMat
                scene.rootNode.addChildNode(mull)
            }

            // Glowing baseboard along the window wall.
            let strip = SCNNode(geometry: SCNBox(width: 0.03, height: 0.025, length: 9.6, chamferRadius: 0))
            strip.position = SCNVector3(side * 4.42, 0.05, -0.5)
            strip.geometry?.firstMaterial = glow(teal.withAlphaComponent(0.5))
            scene.rootNode.addChildNode(strip)
        }
    }

    // MARK: Table — dark drum, glowing ring inlay, emblem core, holo rings

    private static func addTable(to scene: SCNScene) {
        // Drum base to the floor.
        let drum = SCNNode(geometry: SCNCylinder(radius: 1.42, height: 0.66))
        drum.position = SCNVector3(0, 0.33, 0)
        drum.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.03, green: 0.045, blue: 0.065, alpha: 1),
                                           emission: .black, metalness: 0.7, roughness: 0.3)
        scene.rootNode.addChildNode(drum)

        // Glowing ring where the drum meets the floor.
        let footRing = SCNNode(geometry: SCNTorus(ringRadius: 1.43, pipeRadius: 0.014))
        footRing.position = SCNVector3(0, 0.02, 0)
        footRing.geometry?.firstMaterial = glow(teal.withAlphaComponent(0.6))
        scene.rootNode.addChildNode(footRing)

        // Tabletop with slight overhang — near-black glass.
        let top = SCNNode(geometry: SCNCylinder(radius: 1.72, height: 0.09))
        top.position = SCNVector3(0, 0.71, 0)
        top.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.025, green: 0.04, blue: 0.06, alpha: 1),
                                          emission: .black, metalness: 0.95, roughness: 0.1)
        scene.rootNode.addChildNode(top)

        // Teal ring inset near the table edge.
        let inset = SCNNode(geometry: SCNTorus(ringRadius: 1.52, pipeRadius: 0.015))
        inset.position = SCNVector3(0, 0.757, 0)
        inset.geometry?.firstMaterial = glow(teal.withAlphaComponent(0.85))
        scene.rootNode.addChildNode(inset)

        // Center holo-projector: emblem disc + slow counter-rotating rings.
        let disc = SCNNode(geometry: SCNCylinder(radius: 0.62, height: 0.015))
        disc.position = SCNVector3(0, 0.762, 0)
        let dm = SCNMaterial()
        let emblem = emblemTexture()
        dm.diffuse.contents = emblem
        dm.emission.contents = emblem
        dm.emission.intensity = 0.95
        dm.lightingModel = .constant
        disc.geometry?.firstMaterial = dm
        scene.rootNode.addChildNode(disc)
        disc.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 24)))

        for (i, r) in [CGFloat(0.34), 0.48].enumerated() {
            let ring = SCNNode(geometry: SCNTorus(ringRadius: r, pipeRadius: 0.008))
            ring.position = SCNVector3(0, 0.80 + Float(i) * 0.05, 0)
            ring.geometry?.firstMaterial = glow(teal.withAlphaComponent(0.4))
            scene.rootNode.addChildNode(ring)
            ring.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2 * (i % 2 == 0 ? 1 : -1), z: 0, duration: 9 + Double(i) * 4)))
        }

        // Soft light column rising from the projector.
        let beam = SCNNode(geometry: SCNCylinder(radius: 0.3, height: 0.9))
        beam.position = SCNVector3(0, 1.25, 0)
        let bm = SCNMaterial()
        bm.diffuse.contents = teal.withAlphaComponent(0.04)
        bm.emission.contents = teal.withAlphaComponent(0.06)
        bm.lightingModel = .constant
        bm.isDoubleSided = true
        bm.transparency = 0.5
        beam.geometry?.firstMaterial = bm
        scene.rootNode.addChildNode(beam)
    }

    // MARK: Seating — executive chairs + per-seat consoles

    private static func addSeating(_ attendees: [OrgAgent], to scene: SCNScene) {
        // The render shows a full ring of chairs; keep the room looking staffed
        // even with few attendees. Attendee seats get their accent on the console.
        let seats = max(attendees.count, 12)
        for i in 0..<seats {
            let a = Float(i) / Float(seats) * Float.pi * 2

            let chair = chairNode()
            chair.position = SCNVector3(2.35 * sin(a), 0, 2.35 * cos(a))
            chair.eulerAngles.y = a
            scene.rootNode.addChildNode(chair)

            // Seat console on the table edge, tilted toward the chair.
            let isLive = i < attendees.count
            let accent = isLive ? muted(UIColor(hexString: attendees[i].accentHex)) : UIColor(white: 0.35, alpha: 1)
            let console = SCNNode(geometry: SCNBox(width: 0.3, height: 0.19, length: 0.015, chamferRadius: 0.01))
            console.position = SCNVector3(1.36 * sin(a), 0.82, 1.36 * cos(a))
            console.eulerAngles = SCNVector3(-0.55, a + .pi, 0)
            let cm = SCNMaterial()
            cm.diffuse.contents = UIColor(red: 0.015, green: 0.03, blue: 0.045, alpha: 1)
            cm.emission.contents = (isLive ? teal : accent).withAlphaComponent(isLive ? 0.5 : 0.12)
            cm.lightingModel = .constant
            console.geometry?.firstMaterial = cm
            if isLive { console.name = "console-\(attendees[i].id)" }   // debate spotlight
            scene.rootNode.addChildNode(console)

            // Tiny accent indicator above live consoles.
            if isLive {
                let dot = SCNNode(geometry: SCNSphere(radius: 0.018))
                dot.position = SCNVector3(1.36 * sin(a), 0.95, 1.36 * cos(a))
                dot.geometry?.firstMaterial = glow(accent)
                dot.name = "dot-\(attendees[i].id)"                      // debate pulse
                scene.rootNode.addChildNode(dot)
            }
        }
    }

    private static func chairNode() -> SCNNode {
        let node = SCNNode()
        let leather = pbr(diffuse: UIColor(red: 0.045, green: 0.055, blue: 0.075, alpha: 1),
                          emission: .black, metalness: 0.25, roughness: 0.5)
        let chrome = pbr(diffuse: UIColor(white: 0.55, alpha: 1), emission: .black, metalness: 0.95, roughness: 0.2)

        let seat = SCNNode(geometry: SCNBox(width: 0.46, height: 0.09, length: 0.44, chamferRadius: 0.06))
        seat.position = SCNVector3(0, 0.52, 0); seat.geometry?.firstMaterial = leather
        node.addChildNode(seat)

        // High back with a headrest — executive profile.
        let back = SCNNode(geometry: SCNBox(width: 0.46, height: 0.64, length: 0.08, chamferRadius: 0.1))
        back.position = SCNVector3(0, 0.88, 0.2); back.eulerAngles.x = -0.1
        back.geometry?.firstMaterial = leather
        node.addChildNode(back)

        let headrest = SCNNode(geometry: SCNBox(width: 0.34, height: 0.16, length: 0.07, chamferRadius: 0.05))
        headrest.position = SCNVector3(0, 1.27, 0.235); headrest.eulerAngles.x = -0.12
        headrest.geometry?.firstMaterial = leather
        node.addChildNode(headrest)

        // Signature teal trim down the back edges (like the render's lit chairs).
        for dx in [Float(-0.225), 0.225] {
            let trim = SCNNode(geometry: SCNBox(width: 0.012, height: 0.6, length: 0.012, chamferRadius: 0))
            trim.position = SCNVector3(dx, 0.88, 0.245); trim.eulerAngles.x = -0.1
            trim.geometry?.firstMaterial = glow(teal.withAlphaComponent(0.55))
            node.addChildNode(trim)
        }

        for dx in [Float(-0.25), 0.25] {
            let arm = SCNNode(geometry: SCNBox(width: 0.05, height: 0.05, length: 0.32, chamferRadius: 0.02))
            arm.position = SCNVector3(dx, 0.63, 0.02); arm.geometry?.firstMaterial = leather
            node.addChildNode(arm)
        }

        let post = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 0.44))
        post.position = SCNVector3(0, 0.28, 0); post.geometry?.firstMaterial = chrome
        node.addChildNode(post)

        for k in 0..<5 {
            let a = Float(k) / 5 * Float.pi * 2
            let leg = SCNNode(geometry: SCNBox(width: 0.035, height: 0.025, length: 0.27, chamferRadius: 0.01))
            leg.position = SCNVector3(sin(a) * 0.13, 0.045, cos(a) * 0.13)
            leg.eulerAngles.y = a; leg.geometry?.firstMaterial = chrome
            node.addChildNode(leg)
            let wheel = SCNNode(geometry: SCNSphere(radius: 0.028))
            wheel.position = SCNVector3(sin(a) * 0.25, 0.028, cos(a) * 0.25)
            wheel.geometry?.firstMaterial = chrome
            node.addChildNode(wheel)
        }
        return node
    }

    private static func addPlants(to scene: SCNScene) {
        for pos in [SCNVector3(-3.9, 0, 2.9), SCNVector3(3.9, 0, 2.9), SCNVector3(-3.9, 0, -3.3), SCNVector3(3.9, 0, -3.3)] {
            let pot = SCNNode(geometry: SCNCylinder(radius: 0.22, height: 0.4))
            pot.position = SCNVector3(pos.x, 0.2, pos.z)
            pot.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.07, green: 0.08, blue: 0.1, alpha: 1),
                                              emission: .black, metalness: 0.5, roughness: 0.4)
            scene.rootNode.addChildNode(pot)

            let green = pbr(diffuse: UIColor(red: 0.1, green: 0.38, blue: 0.2, alpha: 1),
                            emission: UIColor(red: 0, green: 0.04, blue: 0, alpha: 1), metalness: 0, roughness: 0.75)
            for (dx, h, dz) in [(Float(0), Float(0.95), Float(0)), (-0.16, 0.75, 0.1), (0.16, 0.8, -0.1), (0.06, 0.6, 0.16), (-0.08, 0.55, -0.14)] {
                let leaf = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.13, height: CGFloat(h)))
                leaf.position = SCNVector3(pos.x + dx, 0.4 + h / 2, pos.z + dz)
                leaf.geometry?.firstMaterial = green
                scene.rootNode.addChildNode(leaf)
            }
        }
    }

    // MARK: Drawn textures — what makes the screens/skyline look real

    private enum DashboardStyle { case strategy, operations }

    private static func dashboardTexture(title: String, style: DashboardStyle) -> UIImage {
        let size = CGSize(width: 1024, height: 590)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext

            // Panel background.
            UIColor(red: 0.012, green: 0.035, blue: 0.05, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))

            // Border.
            c.setStrokeColor(teal.withAlphaComponent(0.5).cgColor)
            c.setLineWidth(3)
            c.stroke(CGRect(x: 6, y: 6, width: size.width - 12, height: size.height - 12))

            // Header.
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 38, weight: .bold),
                .foregroundColor: UIColor(red: 0.75, green: 0.95, blue: 1, alpha: 1),
                .kern: 6
            ]
            (title as NSString).draw(at: CGPoint(x: 40, y: 30), withAttributes: titleAttrs)
            c.setFillColor(emerald.withAlphaComponent(0.25).cgColor)
            let pill = CGRect(x: size.width - 170, y: 32, width: 130, height: 42)
            c.addPath(UIBezierPath(roundedRect: pill, cornerRadius: 21).cgPath); c.fillPath()
            ("● LIVE" as NSString).draw(at: CGPoint(x: pill.minX + 26, y: pill.minY + 9), withAttributes: [
                .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                .foregroundColor: UIColor(red: 0.4, green: 0.95, blue: 0.65, alpha: 1)
            ])
            c.setStrokeColor(teal.withAlphaComponent(0.35).cgColor)
            c.setLineWidth(2)
            c.move(to: CGPoint(x: 40, y: 95)); c.addLine(to: CGPoint(x: size.width - 40, y: 95)); c.strokePath()

            switch style {
            case .strategy:
                drawDonut(c, center: CGPoint(x: 820, y: 240), radius: 80, fraction: 0.79, label: "79%")
                drawLineChart(c, in: CGRect(x: 40, y: 130, width: 560, height: 230))
                drawRows(c, in: CGRect(x: 40, y: 400, width: 560, height: 150), rows: 3)
                drawBars(c, in: CGRect(x: 680, y: 380, width: 290, height: 170))
            case .operations:
                drawBars(c, in: CGRect(x: 40, y: 140, width: 420, height: 220))
                drawDonut(c, center: CGPoint(x: 600, y: 240), radius: 75, fraction: 0.92, label: "92%")
                drawRows(c, in: CGRect(x: 40, y: 400, width: 930, height: 150), rows: 3)
                drawLineChart(c, in: CGRect(x: 720, y: 130, width: 260, height: 220))
            }
        }
    }

    private static func drawDonut(_ c: CGContext, center: CGPoint, radius: CGFloat, fraction: CGFloat, label: String) {
        c.setStrokeColor(UIColor(white: 0.18, alpha: 1).cgColor)
        c.setLineWidth(20)
        c.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        c.strokePath()
        c.setStrokeColor(emerald.cgColor)
        c.setLineCap(.round)
        c.addArc(center: center, radius: radius,
                 startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * fraction, clockwise: false)
        c.strokePath()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 40, weight: .heavy),
            .foregroundColor: UIColor.white
        ]
        let s = label as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2), withAttributes: attrs)
        ("ON TRACK" as NSString).draw(at: CGPoint(x: center.x - 44, y: center.y + radius + 26), withAttributes: [
            .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: UIColor(red: 0.5, green: 0.85, blue: 0.9, alpha: 1), .kern: 2
        ])
    }

    private static func drawLineChart(_ c: CGContext, in rect: CGRect) {
        // Grid.
        c.setStrokeColor(UIColor(white: 1, alpha: 0.07).cgColor)
        c.setLineWidth(1)
        for i in 0...4 {
            let y = rect.minY + rect.height * CGFloat(i) / 4
            c.move(to: CGPoint(x: rect.minX, y: y)); c.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        c.strokePath()

        // Polyline.
        let values: [CGFloat] = [0.62, 0.5, 0.66, 0.58, 0.74, 0.68, 0.84, 0.8, 0.92]
        let pts = values.enumerated().map { i, v in
            CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1),
                    y: rect.maxY - rect.height * v)
        }
        // Area fill.
        c.setFillColor(teal.withAlphaComponent(0.12).cgColor)
        c.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        pts.forEach { c.addLine(to: $0) }
        c.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        c.closePath(); c.fillPath()
        // Line.
        c.setStrokeColor(teal.cgColor)
        c.setLineWidth(5)
        c.setLineJoin(.round)
        c.move(to: pts[0]); pts.dropFirst().forEach { c.addLine(to: $0) }
        c.strokePath()
        // Dots.
        c.setFillColor(UIColor.white.cgColor)
        for p in pts {
            c.fillEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
        }
    }

    private static func drawBars(_ c: CGContext, in rect: CGRect) {
        let values: [CGFloat] = [0.45, 0.7, 0.55, 0.85, 0.65]
        let barW = rect.width / CGFloat(values.count) * 0.55
        for (i, v) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(values.count) + barW * 0.4
            let h = rect.height * v
            c.setFillColor(emerald.withAlphaComponent(0.85).cgColor)
            let bar = CGRect(x: x, y: rect.maxY - h, width: barW, height: h)
            c.addPath(UIBezierPath(roundedRect: bar, cornerRadius: 6).cgPath)
            c.fillPath()
        }
    }

    private static func drawRows(_ c: CGContext, in rect: CGRect, rows: Int) {
        let labels = ["Initiative Alpha — expansion", "Pipeline review — capital", "Agent throughput — weekly"]
        for i in 0..<rows {
            let y = rect.minY + CGFloat(i) * (rect.height / CGFloat(rows))
            c.setFillColor(teal.withAlphaComponent(0.85).cgColor)
            c.fillEllipse(in: CGRect(x: rect.minX, y: y + 10, width: 12, height: 12))
            (labels[i % labels.count] as NSString).draw(at: CGPoint(x: rect.minX + 28, y: y), withAttributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .medium),
                .foregroundColor: UIColor(white: 0.85, alpha: 1)
            ])
            c.setStrokeColor(UIColor(white: 1, alpha: 0.08).cgColor)
            c.setLineWidth(1)
            c.move(to: CGPoint(x: rect.minX, y: y + 40)); c.addLine(to: CGPoint(x: rect.maxX, y: y + 40))
            c.strokePath()
        }
    }

    /// Night city skyline drawn at runtime — towers, lit windows, haze.
    private static func skylineTexture() -> UIImage {
        let size = CGSize(width: 1400, height: 580)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()

            // Sky gradient.
            let sky = CGGradient(colorsSpace: space, colors: [
                UIColor(red: 0.03, green: 0.07, blue: 0.18, alpha: 1).cgColor,
                UIColor(red: 0.01, green: 0.02, blue: 0.06, alpha: 1).cgColor
            ] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

            // Distant glow on the horizon.
            let horizon = CGGradient(colorsSpace: space, colors: [
                UIColor(red: 0.15, green: 0.45, blue: 0.6, alpha: 0.35).cgColor,
                UIColor.clear.cgColor
            ] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(horizon,
                                 start: CGPoint(x: 0, y: size.height),
                                 end: CGPoint(x: 0, y: size.height * 0.55), options: [])

            // Towers — deterministic pseudo-random layout.
            var x: CGFloat = -20
            var k: UInt64 = 11
            func rnd() -> CGFloat { k = k &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((k >> 33) % 1000) / 1000 }
            while x < size.width {
                let w = 60 + rnd() * 90
                let h = 160 + rnd() * 330
                let tower = CGRect(x: x, y: size.height - h, width: w, height: h)
                c.setFillColor(UIColor(red: 0.02 + rnd() * 0.015, green: 0.04, blue: 0.08, alpha: 1).cgColor)
                c.fill(tower)

                // Lit windows.
                var wy = tower.minY + 14
                while wy < tower.maxY - 16 {
                    var wx = tower.minX + 8
                    while wx < tower.maxX - 12 {
                        if rnd() > 0.55 {
                            let warm = rnd() > 0.6
                            c.setFillColor((warm
                                ? UIColor(red: 1, green: 0.85, blue: 0.55, alpha: 0.8)
                                : UIColor(red: 0.5, green: 0.85, blue: 1, alpha: 0.8)).cgColor)
                            c.fill(CGRect(x: wx, y: wy, width: 7, height: 4.5))
                        }
                        wx += 16
                    }
                    wy += 13
                }
                x += w + 8 + rnd() * 26
            }
        }
    }

    /// Round emblem for the table's holo-projector core.
    private static func emblemTexture() -> UIImage {
        let size = CGSize(width: 512, height: 512)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: 256, y: 256)

            UIColor(red: 0.01, green: 0.03, blue: 0.045, alpha: 1).setFill()
            c.fillEllipse(in: CGRect(origin: .zero, size: size))

            c.setStrokeColor(teal.cgColor)
            c.setLineWidth(10)
            c.strokeEllipse(in: CGRect(x: 36, y: 36, width: 440, height: 440))
            c.setStrokeColor(teal.withAlphaComponent(0.45).cgColor)
            c.setLineWidth(4)
            c.strokeEllipse(in: CGRect(x: 86, y: 86, width: 340, height: 340))

            // Tick marks.
            c.setStrokeColor(teal.withAlphaComponent(0.7).cgColor)
            c.setLineWidth(6)
            for i in 0..<24 {
                let a = CGFloat(i) / 24 * .pi * 2
                let r1: CGFloat = 196, r2: CGFloat = 216
                c.move(to: CGPoint(x: center.x + cos(a) * r1, y: center.y + sin(a) * r1))
                c.addLine(to: CGPoint(x: center.x + cos(a) * r2, y: center.y + sin(a) * r2))
            }
            c.strokePath()

            // Center glyph — a bold "H".
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 200, weight: .black),
                .foregroundColor: UIColor(red: 0.65, green: 0.95, blue: 1, alpha: 1)
            ]
            let s = "H" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2), withAttributes: attrs)
        }
    }

    /// Tinted environment so metals/glass have something to reflect.
    private static func environmentMap() -> UIImage {
        let size = CGSize(width: 512, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let base = CGGradient(colorsSpace: space, colors: [
                UIColor(red: 0.05, green: 0.1, blue: 0.2, alpha: 1).cgColor,
                UIColor(red: 0.01, green: 0.015, blue: 0.04, alpha: 1).cgColor
            ] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            let blobs: [(CGFloat, CGFloat, CGFloat, UIColor)] = [
                (120, 60, 90, UIColor(red: 0.3, green: 0.8, blue: 0.9, alpha: 1)),
                (320, 50, 110, UIColor(red: 0.25, green: 0.5, blue: 0.9, alpha: 1)),
                (440, 80, 60, .white)
            ]
            for (x, y, r, col) in blobs {
                let g = CGGradient(colorsSpace: space, colors: [
                    col.withAlphaComponent(0.8).cgColor, col.withAlphaComponent(0).cgColor
                ] as CFArray, locations: [0, 1])!
                c.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                     endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
            }
        }
    }

    // MARK: Materials

    /// Calm an accent into a muted tone for seat consoles.
    private static func muted(_ color: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        return UIColor(hue: h, saturation: s * 0.5, brightness: min(b, 0.7), alpha: a)
    }
    private static func pbr(diffuse: UIColor, emission: UIColor, metalness: CGFloat, roughness: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = diffuse; m.emission.contents = emission
        m.metalness.contents = metalness; m.roughness.contents = roughness
        m.lightingModel = .physicallyBased
        return m
    }
    private static func glow(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial(); m.diffuse.contents = color; m.emission.contents = color; m.lightingModel = .constant; return m
    }
}

// MARK: - Meeting conversation (group chat scoped to attendees)

@MainActor
final class MeetingConversation: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isSending = false
    @Published private(set) var attendees: [OrgAgent]
    private var introSent = Set<String>()

    init(attendees: [OrgAgent]) {
        self.attendees = attendees
        let names = attendees.map(\.name).joined(separator: ", ")
        messages = [ChatMessage(author: .system, text: "In the room: \(names). Address one by name, or just speak and the most senior here will answer.", date: Date())]
    }

    /// Remove an agent from the meeting — they stop answering and a note is filed.
    func kick(_ agent: OrgAgent) {
        guard attendees.contains(where: { $0.id == agent.id }) else { return }
        attendees.removeAll { $0.id == agent.id }
        introSent.remove(agent.id)
        messages.append(ChatMessage(author: .system,
            text: "\(agent.name) was removed from the meeting.", date: Date()))
    }

    func send(_ text: String, attachments: [ChatAttachment] = [], relay base: HermesRelayConfiguration) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !attachments.isEmpty { trimmed = "Please review the attached." }
        guard !trimmed.isEmpty, !isSending, !attendees.isEmpty else { return }
        var userMessage = ChatMessage(author: .user, text: text.trimmingCharacters(in: .whitespacesAndNewlines), date: Date())
        userMessage.attachments = attachments
        messages.append(userMessage)

        guard base.isConfigured else {
            messages.append(ChatMessage(author: .system, text: "Connect your relay first (Settings → Mac Relay).", date: Date()))
            return
        }

        let target = resolveTarget(trimmed)
        var config = base
        config.profile = target.profileSlug

        let body = trimmed + attachments.payloadSuffix
        let persona = target.soul.isEmpty ? target.summary : target.soul
        let payload: String
        if introSent.contains(target.id) {
            payload = body
        } else {
            introSent.insert(target.id)
            payload = "You are the \(target.name) in a company meeting. Your remit: \(persona) Answer in that role.\n\n\(body)"
        }

        isSending = true
        let responseID = UUID()
        var reply = ChatMessage(id: responseID, author: .hermes, text: "", date: Date())
        reply.speaker = target.name
        reply.accentHex = target.accentHex
        messages.append(reply)
        let session = "hermes-mobile-meeting-\(target.id)"

        Task {
            do {
                for try await event in HermesRelayClient(configuration: config).stream(payload, sessionKey: session, fast: true) {
                    switch event.type {
                    case .start: break
                    case .delta: appendTo(responseID, event.text ?? "")
                    case .done:
                        if let r = event.reply, currentText(responseID).isEmpty { appendTo(responseID, r) }
                    case .error:
                        throw HermesRelayError.server(event.message ?? "Hermes stream failed.")
                    }
                }
                if currentText(responseID).isEmpty { appendTo(responseID, "(no response)") }
            } catch {
                messages.append(ChatMessage(author: .system, text: error.localizedDescription, date: Date()))
            }
            isSending = false
        }
    }

    private func resolveTarget(_ text: String) -> OrgAgent {
        let lower = text.lowercased()
        for agent in attendees where CompanyConversation.routingKeys(agent).contains(where: { lower.contains($0) }) {
            return agent
        }
        func rank(_ a: OrgAgent) -> Int { a.tier == .ceo ? 0 : (a.tier == .manager ? 1 : 2) }
        return attendees.sorted { rank($0) < rank($1) }.first ?? attendees[0]
    }

    private func appendTo(_ id: UUID, _ text: String) {
        guard !text.isEmpty, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += text
    }
    private func currentText(_ id: UUID) -> String {
        messages.first { $0.id == id }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Conference Room screen

struct MeetingRoomView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController
    @StateObject private var convo: MeetingConversation
    @State private var draft = ""
    @State private var elapsed = 0
    @State private var showDebate = false
    @FocusState private var focused: Bool

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Live roster — the conversation owns it so kicking updates the room too.
    private var attendees: [OrgAgent] { convo.attendees }

    init(attendees: [OrgAgent]) {
        _convo = StateObject(wrappedValue: MeetingConversation(attendees: attendees))
    }

    private var elapsedText: String { String(format: "%02d:%02d", elapsed / 60, elapsed % 60) }

    private static let bottomID = "meeting-bottom"

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                MeetingRoomSceneView(attendees: attendees)

                VStack {
                    HStack {
                        pill { Circle().fill(.green).frame(width: 7, height: 7); Text("Meeting in Progress") }
                        Spacer()
                        Menu {
                            Text("Tap an agent to remove them")
                            ForEach(attendees) { agent in
                                Button(role: .destructive) {
                                    convo.kick(agent)
                                } label: {
                                    Label("Remove \(agent.name)", systemImage: "person.fill.xmark")
                                }
                            }
                        } label: {
                            pill { Image(systemName: "person.2.fill").font(.caption2); Text("\(attendees.count) Participants") }
                        }
                    }
                    Spacer()
                    if !focused {
                        HStack {
                            Label { Text("Live session").lineLimit(1) } icon: { Image(systemName: "chart.bar.fill") }
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Label { Text(elapsedText).monospacedDigit() } icon: { Image(systemName: "clock") }
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(12)
            }
            // The room gives the keyboard its space — shrinks while typing so
            // the composer and conversation always stay visible.
            .frame(height: focused ? 150 : 360)
            .clipped()
            .animation(.easeInOut(duration: 0.28), value: focused)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(convo.messages) { message in
                            ChatBubble(message: message, speaker: "Agent", accentHex: "39D98A")
                        }
                        if convo.isSending {
                            TypingIndicator(name: "The room", accent: HermesTheme.emerald)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture { focused = false }     // tap anywhere → keyboard drops
                .onChange(of: convo.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
                .onChange(of: focused) { _, isUp in
                    if isUp {
                        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
            }

            ChatComposer(draft: $draft, focused: $focused, disabled: convo.isSending, placeholder: "Speak to the room") { attachments in
                convo.send(draft, attachments: attachments, relay: runtime.relayConfiguration)
                draft = ""
            }
        }
        .navigationTitle("Conference Room")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showDebate = true } label: {
                    Label("Debate", systemImage: "person.wave.2.fill")
                }
                .accessibilityLabel("Start a boardroom debate")
            }
        }
        .fullScreenCover(isPresented: $showDebate) {
            DebateView(attendees: attendees)
        }
        .onReceive(ticker) { _ in elapsed += 1 }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .overlay(Capsule().stroke(HermesTheme.emerald.opacity(0.35), lineWidth: 1))
    }
}

private extension UIColor {
    convenience init(hexString: String) {
        let clean = hexString.replacingOccurrences(of: "#", with: "")
        let scanner = Scanner(string: clean)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
