import SceneKit
import SwiftUI
import UIKit

// MARK: - 3D conference room — cinematic boardroom (round holo-table, skyline
// glass, live dashboard wall) modeled on the user's reference render.

/// REAL numbers for the boardroom's wall screens, computed from live company
/// state by whoever presents the room. Zeros render honestly as zeros — the
/// invented "79% ON TRACK" era is over.
struct RoomStats: Equatable {
    struct Bar: Equatable {
        var label: String
        var value: Int
    }

    var headline = "BOARDROOM"          // live meeting topic, or the honest default
    var live = false                    // a meeting is actually in session
    var shipped = 0
    var active = 0
    var gates = 0
    var tasksDone = 0
    var tasksTotal = 0
    var divisionBars: [Bar] = []        // shipped per division
    var activeRows: [String] = []       // initiatives in motion + stage
    var eventRows: [String] = []        // latest real activity

    static func from(state: CompanyState, liveTopic: String? = nil) -> RoomStats {
        var stats = RoomStats()
        if let liveTopic, !liveTopic.isEmpty {
            stats.headline = String(liveTopic.uppercased().prefix(34))
            stats.live = true
        }
        let initiatives = state.initiatives
        stats.shipped = initiatives.filter { $0.stage == "shipped" }.count
        stats.active = initiatives.filter { !$0.isTerminal }.count
        stats.gates = initiatives.filter(\.isAwaitingDecision).count
        let tasks = state.tasks ?? []
        stats.tasksDone = tasks.filter { $0.status == "done" }.count
        stats.tasksTotal = tasks.count
        var byDivision: [String: Int] = [:]
        for item in initiatives where item.stage == "shipped" {
            let division = item.division ?? ""
            let label = HQDivision(rawValue: division)?.name ?? "General"
            byDivision[label, default: 0] += 1
        }
        stats.divisionBars = byDivision
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { Bar(label: $0.key, value: $0.value) }
        stats.activeRows = initiatives
            .filter { !$0.isTerminal && !$0.isAwaitingDecision }
            .prefix(3)
            .map { "\($0.title) — \($0.stage)" }
        stats.eventRows = (state.events ?? []).suffix(3).reversed().map(\.text)
        return stats
    }
}

struct MeetingRoomSceneView: UIViewRepresentable {
    var attendees: [OrgAgent]
    var avatar: UserAvatar = .default
    // ponytail: the wall screens render the stats from when you walked in;
    // live-updating them would rebuild the scene and fight the camera.
    var stats = RoomStats()
    var onSelectAgent: (String) -> Void = { _ in }
    var onSelectScreen: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.006, green: 0.012, blue: 0.025, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.isPlaying = true
        view.scene = MeetingSceneBuilder.scene(attendees: attendees, avatar: avatar, stats: stats)
        context.coordinator.avatar = avatar
        context.coordinator.onSelectScreen = onSelectScreen
        context.coordinator.attach(to: view, ids: attendees.map(\.id), onSelect: onSelectAgent)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.onSelectAgent = onSelectAgent
        context.coordinator.onSelectScreen = onSelectScreen
        // The avatar changed (customized) → rebuild so "you" update at the table.
        if avatar != context.coordinator.avatar {
            context.coordinator.avatar = avatar
            uiView.scene = MeetingSceneBuilder.scene(attendees: attendees, avatar: avatar, stats: stats)
            context.coordinator.attach(to: uiView, ids: attendees.map(\.id), onSelect: onSelectAgent)
            return
        }
        let ids = attendees.map(\.id)
        let old = context.coordinator.ids
        guard ids != old else { return }
        // Pure removal (a kick): walk the removed agents out the door instead
        // of rebuilding — keeps everyone else seated.
        let removed = old.filter { !ids.contains($0) }
        if !removed.isEmpty, ids.allSatisfy(old.contains) {
            context.coordinator.ids = ids
            context.coordinator.walkOut(removed)
        } else {
            uiView.scene = MeetingSceneBuilder.scene(attendees: attendees, avatar: avatar)
            context.coordinator.attach(to: uiView, ids: ids, onSelect: onSelectAgent)
        }
    }

    /// Tracks attendees and lights up the speaking agent's seat console
    /// during a live debate.
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var ids: [String] = []
        var avatar: UserAvatar = .default
        var onSelectAgent: ((String) -> Void)?
        var onSelectScreen: ((String) -> Void)?
        private weak var view: SCNView?
        private var tapRecognizer: UITapGestureRecognizer?

        func attach(to view: SCNView, ids: [String], onSelect: @escaping (String) -> Void) {
            self.view = view
            self.ids = ids
            self.onSelectAgent = onSelect
            // Add OUR tap recognizer exactly once — tracked by reference, NOT by
            // "is there any tap recognizer", because allowsCameraControl adds its
            // own tap recognizers and that check made ours never get installed.
            if tapRecognizer == nil {
                let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
                tap.delegate = self
                tap.cancelsTouchesInView = false
                view.addGestureRecognizer(tap)
                tapRecognizer = tap
            }
            NotificationCenter.default.removeObserver(self)
            NotificationCenter.default.addObserver(self, selector: #selector(speakerChanged(_:)),
                                                   name: .hermesDebateSpeaker, object: nil)
        }

        /// Tap a seat (robot, console, dot, halo, or nameplate) → talk to that agent.
        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name {
                        if name == "screen-minutes" || name == "screen-vault" {
                            onSelectScreen?(name)
                            return
                        }
                        if let id = Self.agentID(from: name) {
                            onSelectAgent?(id)
                            return
                        }
                    }
                    node = current.parent
                }
            }
        }

        private static func agentID(from name: String) -> String? {
            for prefix in ["robot-", "console-", "dot-", "plate-", "halo-"] where name.hasPrefix(prefix) {
                let id = String(name.dropFirst(prefix.count))
                return id == "__user__" ? nil : id
            }
            return nil
        }

        // Fire our tap even though SceneKit's camera control has its own recognizers.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
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
                } else if name.hasPrefix("halo-") {
                    // The glowing halo over whoever is talking — clear "who's speaking".
                    let isSpeaking = name == "halo-\(speakingID)"
                    node.removeAction(forKey: "halofade")
                    node.runAction(.fadeOpacity(to: isSpeaking ? 1.0 : 0.0, duration: 0.3), forKey: "halofade")
                    if isSpeaking {
                        if node.action(forKey: "halospin") == nil {
                            node.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 6)), forKey: "halospin")
                        }
                    } else {
                        node.removeAction(forKey: "halospin")
                    }
                }
            }
        }

        /// Stand up, turn to the door, walk out, and leave the meeting.
        func walkOut(_ removedIDs: [String]) {
            guard let root = view?.scene?.rootNode else { return }
            let door = MeetingSceneBuilder.doorPosition
            for id in removedIDs {
                guard let robot = root.childNode(withName: "robot-\(id)", recursively: false) else { continue }
                let target = SCNVector3(door.x, robot.position.y, door.z + 0.2)
                let faceDoor = atan2(target.x - robot.position.x, target.z - robot.position.z)
                let stand = SCNAction.moveBy(x: 0, y: 0.06, z: 0, duration: 0.3)
                let turn = SCNAction.rotateTo(x: 0, y: CGFloat(faceDoor), z: 0,
                                              duration: 0.4, usesShortestUnitArc: true)
                let walk = SCNAction.move(to: target, duration: 2.2)
                walk.timingMode = .easeInEaseOut
                let leave = SCNAction.group([.fadeOut(duration: 0.5),
                                             .scale(to: 0.35, duration: 0.5)])
                robot.runAction(.sequence([stand, turn, walk, leave, .removeFromParentNode()]))
                // Dim their seat console + stop any speaking pulse.
                root.childNode(withName: "console-\(id)", recursively: false)?
                    .geometry?.firstMaterial?.emission.intensity = 0.1
                if let dot = root.childNode(withName: "dot-\(id)", recursively: false) {
                    dot.removeAllActions()
                    dot.runAction(.fadeOut(duration: 0.5))
                }
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

private enum MeetingSceneBuilder {

    // The room's signature accent — muted sea-glass, per the palette rule
    // (no neon): one constant recolors the ring, screens, and edge lights.
    private static let teal = UIColor(red: 0.22, green: 0.58, blue: 0.52, alpha: 1)
    private static let emerald = UIColor(red: 0.20, green: 0.62, blue: 0.47, alpha: 1)

    static func scene(attendees: [OrgAgent], avatar: UserAvatar,
                      stats: RoomStats = RoomStats()) -> SCNScene {
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
        addBackWall(to: scene, stats: stats)
        addSideWindows(to: scene)
        addDoor(to: scene)
        addTable(to: scene)
        addSeating(attendees, to: scene)
        addUserSeat(avatar, to: scene)
        addPlants(to: scene)
        return scene
    }

    /// Where kicked agents walk out.
    static let doorPosition = SCNVector3(3.4, 0, -2.4)

    /// A lit doorway on the back-right wall — the exit kicked agents head for.
    private static func addDoor(to scene: SCNScene) {
        let frame = SCNNode(geometry: SCNBox(width: 0.95, height: 2.05, length: 0.08, chamferRadius: 0.02))
        frame.position = SCNVector3(doorPosition.x, 1.02, -2.55)
        frame.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.08, alpha: 1),
                                            emission: .black, metalness: 0.6, roughness: 0.4)
        scene.rootNode.addChildNode(frame)
        let glowPanel = SCNNode(geometry: SCNPlane(width: 0.78, height: 1.9))
        glowPanel.position = SCNVector3(doorPosition.x, 1.02, -2.5)
        let gm = SCNMaterial()
        gm.diffuse.contents = teal.withAlphaComponent(0.22)
        gm.emission.contents = teal.withAlphaComponent(0.22)
        gm.lightingModel = .constant
        glowPanel.geometry?.firstMaterial = gm
        scene.rootNode.addChildNode(glowPanel)
    }

    // MARK: Camera — elevated, looking down at the table like the render

    private static func addCamera(to scene: SCNScene) {
        let camera = SCNCamera()
        camera.fieldOfView = 46
        camera.wantsHDR = true
        // HQ-proven bloom: threshold 0.85 — at 0.5 the agents' bright bodies
        // bloomed into cyan blobs (the "glowing agents" report).
        camera.bloomIntensity = 0.5
        camera.bloomThreshold = 0.85
        camera.bloomBlurRadius = 16
        camera.wantsExposureAdaptation = false
        camera.zFar = 90

        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(0, 5.3, 6.3)
        // Orient toward the table ONCE (baked), not with a live SCNLookAtConstraint.
        // A live constraint + allowsCameraControl fight over the up-vector the first
        // time a gesture engages the camera controller — that's the upside-down flip.
        node.look(at: SCNVector3(0, 0.85, -0.55))
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
        // 700, not 1000: SceneKit spots concentrate lumens into the cone, so
        // the seated agents inside it were lit past saturation (bench-measured).
        let spot = SCNLight()
        spot.type = .spot
        spot.intensity = 700
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
        for (pos, intensity) in [(SCNVector3(0, 2.2, -3.4), 176.0), (SCNVector3(-3.8, 2.0, 0), 128.0), (SCNVector3(3.8, 2.0, 0), 128.0)] {
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

    private static func addBackWall(to scene: SCNScene, stats: RoomStats) {
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

        // Two big dashboard screens drawn from REAL company state — the LIVE
        // badge only appears when a meeting is actually in session. Tap to
        // open the Meeting Minutes (right) or the Decision Vault (left).
        let donutLabel = stats.tasksTotal > 0
            ? "\(Int((CGFloat(stats.tasksDone) / CGFloat(stats.tasksTotal) * 100).rounded()))%"
            : "—"
        let pulse = ScreenSpec(
            title: stats.headline,
            badge: stats.live ? "● LIVE" : "",
            rows: stats.activeRows.isEmpty ? ["Nothing in motion right now"] : stats.activeRows,
            donut: (fraction: stats.tasksTotal > 0
                        ? CGFloat(stats.tasksDone) / CGFloat(stats.tasksTotal) : 0,
                    label: donutLabel, sub: "TASKS DONE"))
        let ops = ScreenSpec(
            title: "OPERATIONS PULSE",
            rows: stats.eventRows.isEmpty ? ["No activity yet"] : stats.eventRows,
            bars: stats.divisionBars,
            bigStats: [("SHIPPED", "\(stats.shipped)"),
                       ("ACTIVE", "\(stats.active)"),
                       ("GATES", "\(stats.gates)")])
        addScreen(to: scene, texture: dashboardTexture(pulse),
                  center: SCNVector3(1.55, 2.05, -4.04), size: CGSize(width: 2.7, height: 1.55),
                  tapName: "screen-minutes")
        addScreen(to: scene, texture: dashboardTexture(ops),
                  center: SCNVector3(-1.55, 2.05, -4.04), size: CGSize(width: 2.7, height: 1.55),
                  tapName: "screen-vault")
    }

    private static func addScreen(to scene: SCNScene, texture: UIImage, center: SCNVector3, size: CGSize, tapName: String) {
        // Bezel
        let bezel = SCNNode(geometry: SCNBox(width: size.width + 0.08, height: size.height + 0.08, length: 0.06, chamferRadius: 0.02))
        bezel.position = SCNVector3(center.x, center.y, center.z - 0.02)
        bezel.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1),
                                            emission: .black, metalness: 0.85, roughness: 0.25)
        scene.rootNode.addChildNode(bezel)

        // Panel — emissive texture so it reads as a lit display.
        let panel = SCNNode(geometry: SCNPlane(width: size.width, height: size.height))
        panel.position = SCNVector3(center.x, center.y, center.z + 0.012)
        panel.name = tapName               // tappable → opens minutes / vault
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
        // even with few attendees. The +0.5 step leaves the front-centre gap for
        // the user's own seat (added separately).
        let seats = max(attendees.count, 12)
        for i in 0..<seats {
            let a = (Float(i) + 0.5) / Float(seats) * Float.pi * 2

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

                // The agent, seated in their chair, facing the table.
                let robot = AgentRobot.node(for: attendees[i], color: accent)
                robot.scale = SCNVector3(0.5, 0.5, 0.5)
                robot.position = SCNVector3(2.18 * sin(a), 0.26, 2.18 * cos(a))
                robot.eulerAngles.y = a + .pi
                robot.name = "robot-\(attendees[i].id)"
                scene.rootNode.addChildNode(robot)

                // Neat floating nameplate so you know who's who at a glance.
                let plate = SCNNode(geometry: SCNPlane(width: 0.6, height: 0.165))
                plate.position = SCNVector3(2.02 * sin(a), 1.18, 2.02 * cos(a))
                let pm = SCNMaterial()
                let tex = nameplateTexture(name: attendees[i].name, accent: accent)
                pm.diffuse.contents = tex
                pm.emission.contents = tex
                pm.emission.intensity = 0.9
                pm.lightingModel = .constant
                pm.isDoubleSided = true
                plate.geometry?.firstMaterial = pm
                plate.constraints = [SCNBillboardConstraint()]   // always faces you
                plate.name = "plate-\(attendees[i].id)"
                scene.rootNode.addChildNode(plate)

                // Speaker halo — hidden until this agent is the one talking.
                let halo = SCNNode(geometry: SCNTorus(ringRadius: 0.17, pipeRadius: 0.02))
                halo.position = SCNVector3(2.18 * sin(a), 1.0, 2.18 * cos(a))
                halo.eulerAngles.x = .pi / 2
                halo.geometry?.firstMaterial = glow(emerald)
                halo.opacity = 0
                halo.name = "halo-\(attendees[i].id)"
                scene.rootNode.addChildNode(halo)
            }
        }
    }

    /// The owner's own seat at the front of the table (nearest the camera),
    /// with their customizable human avatar.
    private static func addUserSeat(_ avatar: UserAvatar, to scene: SCNScene) {
        let a: Float = 0   // front-centre, the gap left by addSeating

        let chair = chairNode()
        chair.position = SCNVector3(2.35 * sin(a), 0, 2.35 * cos(a))
        chair.eulerAngles.y = a
        scene.rootNode.addChildNode(chair)

        let person = UserAvatarBuilder.node(for: avatar)
        person.scale = SCNVector3(0.5, 0.5, 0.5)
        person.position = SCNVector3(2.18 * sin(a), 0.26, 2.18 * cos(a))
        person.eulerAngles.y = a + .pi
        person.name = "robot-__user__"
        scene.rootNode.addChildNode(person)

        let plate = SCNNode(geometry: SCNPlane(width: 0.4, height: 0.165))
        plate.position = SCNVector3(2.02 * sin(a), 1.18, 2.02 * cos(a))
        let pm = SCNMaterial()
        let tex = nameplateTexture(name: "You", accent: emerald)
        pm.diffuse.contents = tex
        pm.emission.contents = tex
        pm.emission.intensity = 0.9
        pm.lightingModel = .constant
        pm.isDoubleSided = true
        plate.geometry?.firstMaterial = pm
        plate.constraints = [SCNBillboardConstraint()]
        scene.rootNode.addChildNode(plate)
    }

    /// Small, clean nameplate: dark chip, accent dot, name — no wall of text.
    private static func nameplateTexture(name: String, accent: UIColor) -> UIImage {
        let size = CGSize(width: 440, height: 120)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let chip = UIBezierPath(roundedRect: CGRect(x: 6, y: 26, width: size.width - 12, height: 68), cornerRadius: 34)
            UIColor(red: 0.02, green: 0.05, blue: 0.07, alpha: 0.92).setFill(); chip.fill()
            c.setStrokeColor(accent.withAlphaComponent(0.65).cgColor); c.setLineWidth(2); chip.stroke()
            accent.setFill(); c.fillEllipse(in: CGRect(x: 34, y: 50, width: 20, height: 20))
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: style
            ]
            (name as NSString).draw(in: CGRect(x: 66, y: 38, width: size.width - 96, height: 46), withAttributes: attrs)
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

    /// What one wall screen shows — every field comes from real state.
    private struct ScreenSpec {
        var title: String
        var badge = ""                  // "● LIVE" only during a real session
        var rows: [String] = []
        var bars: [RoomStats.Bar] = []
        var donut: (fraction: CGFloat, label: String, sub: String)?
        var bigStats: [(String, String)] = []
    }

    private static func dashboardTexture(_ spec: ScreenSpec) -> UIImage {
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
            (spec.title as NSString).draw(at: CGPoint(x: 40, y: 30), withAttributes: titleAttrs)
            if !spec.badge.isEmpty {
                c.setFillColor(emerald.withAlphaComponent(0.25).cgColor)
                let pill = CGRect(x: size.width - 170, y: 32, width: 130, height: 42)
                c.addPath(UIBezierPath(roundedRect: pill, cornerRadius: 21).cgPath); c.fillPath()
                (spec.badge as NSString).draw(at: CGPoint(x: pill.minX + 26, y: pill.minY + 9), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                    .foregroundColor: UIColor(red: 0.4, green: 0.95, blue: 0.65, alpha: 1)
                ])
            }
            c.setStrokeColor(teal.withAlphaComponent(0.35).cgColor)
            c.setLineWidth(2)
            c.move(to: CGPoint(x: 40, y: 95)); c.addLine(to: CGPoint(x: size.width - 40, y: 95)); c.strokePath()

            let rowsWidth: CGFloat = spec.donut != nil ? 620 : 930
            drawRows(c, in: CGRect(x: 40, y: 130, width: rowsWidth, height: 230), rows: spec.rows)
            if let donut = spec.donut {
                drawDonut(c, center: CGPoint(x: 830, y: 240), radius: 80,
                          fraction: donut.fraction, label: donut.label, sub: donut.sub)
            }
            if !spec.bars.isEmpty {
                drawBars(c, in: CGRect(x: 40, y: 410, width: 560, height: 150), bars: spec.bars)
            }
            if !spec.bigStats.isEmpty {
                drawBigStats(c, in: CGRect(x: spec.bars.isEmpty ? 40 : 680, y: 410,
                                           width: spec.bars.isEmpty ? 930 : 290, height: 150),
                             stats: spec.bigStats)
            }
        }
    }

    private static func drawDonut(_ c: CGContext, center: CGPoint, radius: CGFloat,
                                  fraction: CGFloat, label: String, sub: String) {
        c.setStrokeColor(UIColor(white: 0.18, alpha: 1).cgColor)
        c.setLineWidth(20)
        c.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        c.strokePath()
        if fraction > 0 {
            c.setStrokeColor(emerald.cgColor)
            c.setLineCap(.round)
            c.addArc(center: center, radius: radius,
                     startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * min(fraction, 1), clockwise: false)
            c.strokePath()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 40, weight: .heavy),
            .foregroundColor: UIColor.white
        ]
        let s = label as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2), withAttributes: attrs)
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: UIColor(red: 0.5, green: 0.85, blue: 0.9, alpha: 1), .kern: 2
        ]
        let subSize = (sub as NSString).size(withAttributes: subAttrs)
        (sub as NSString).draw(at: CGPoint(x: center.x - subSize.width / 2, y: center.y + radius + 26),
                               withAttributes: subAttrs)
    }

    /// Three big honest numbers (SHIPPED / ACTIVE / GATES).
    private static func drawBigStats(_ c: CGContext, in rect: CGRect, stats: [(String, String)]) {
        let slot = rect.width / CGFloat(max(stats.count, 1))
        for (i, stat) in stats.enumerated() {
            let x = rect.minX + slot * CGFloat(i)
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 58, weight: .black),
                .foregroundColor: UIColor.white
            ]
            (stat.1 as NSString).draw(at: CGPoint(x: x, y: rect.minY + 10), withAttributes: valueAttrs)
            (stat.0 as NSString).draw(at: CGPoint(x: x, y: rect.minY + 82), withAttributes: [
                .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: UIColor(red: 0.5, green: 0.85, blue: 0.9, alpha: 1), .kern: 2
            ])
        }
    }

    /// Labeled bars from real values (shipped per division).
    private static func drawBars(_ c: CGContext, in rect: CGRect, bars: [RoomStats.Bar]) {
        let peak = CGFloat(max(bars.map(\.value).max() ?? 1, 1))
        let chartHeight = rect.height - 34   // room for the labels underneath
        let barW = rect.width / CGFloat(bars.count) * 0.55
        for (i, bar) in bars.enumerated() {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(bars.count) + barW * 0.4
            let h = max(chartHeight * CGFloat(bar.value) / peak, 8)
            c.setFillColor(emerald.withAlphaComponent(0.85).cgColor)
            let barRect = CGRect(x: x, y: rect.minY + chartHeight - h, width: barW, height: h)
            c.addPath(UIBezierPath(roundedRect: barRect, cornerRadius: 6).cgPath)
            c.fillPath()
            ("\(bar.value)" as NSString).draw(
                at: CGPoint(x: x + 4, y: rect.minY + chartHeight - h - 28),
                withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .bold),
                                 .foregroundColor: UIColor.white])
            (String(bar.label.prefix(10)) as NSString).draw(
                at: CGPoint(x: x - 6, y: rect.minY + chartHeight + 8),
                withAttributes: [.font: UIFont.systemFont(ofSize: 17, weight: .medium),
                                 .foregroundColor: UIColor(white: 0.7, alpha: 1)])
        }
    }

    /// Real text rows (initiatives in motion / latest activity).
    private static func drawRows(_ c: CGContext, in rect: CGRect, rows: [String]) {
        let shown = rows.prefix(3)
        for (i, label) in shown.enumerated() {
            let y = rect.minY + CGFloat(i) * (rect.height / CGFloat(max(shown.count, 1)))
            c.setFillColor(teal.withAlphaComponent(0.85).cgColor)
            c.fillEllipse(in: CGRect(x: rect.minX, y: y + 10, width: 12, height: 12))
            (String(label.prefix(52)) as NSString).draw(at: CGPoint(x: rect.minX + 28, y: y), withAttributes: [
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
    /// Set by tapping an agent at the table — the next message goes to them.
    @Published var directedTarget: OrgAgent?
    private var introSent = Set<String>()

    /// Tap-to-talk: address one agent directly.
    func direct(to agent: OrgAgent) { directedTarget = agent }

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
        if directedTarget?.id == agent.id { directedTarget = nil }
        messages.append(ChatMessage(author: .system,
            text: "\(agent.name) was removed from the meeting.", date: Date()))
    }

    func send(_ text: String, attachments: [ChatAttachment] = [], relay base: HermesRelayConfiguration, context: String = "") {
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

        // A tapped agent wins; otherwise route by what was said.
        let target = directedTarget ?? resolveTarget(trimmed)
        directedTarget = nil
        var config = base
        config.profile = target.profileSlug

        let body = trimmed + attachments.payloadSuffix
        let persona = target.soul.isEmpty ? target.summary : target.soul
        let ctx = context.isEmpty ? "" : context + "\n\n"
        let payload: String
        if introSent.contains(target.id) {
            payload = ctx + body
        } else {
            introSent.insert(target.id)
            payload = ctx + "You are the \(target.name) in a company meeting. Your remit: \(persona) Answer in that role.\n\n\(body)"
        }

        isSending = true
        let responseID = UUID()
        var reply = ChatMessage(id: responseID, author: .hermes, text: "", date: Date())
        reply.speaker = target.name
        reply.accentHex = target.accentHex
        messages.append(reply)
        let session = "hermes-mobile-meeting-\(target.id)"

        // Light up the speaking agent's seat (halo + console) while they reply.
        NotificationCenter.default.post(name: .hermesDebateSpeaker, object: nil,
                                        userInfo: ["agentID": target.id])

        Task {
            do {
                // fast: false — a meeting reply is TEXT and runs the FULL agent
                // loop (fast:true is voice-latency only; it truncates tool use).
                let replyText = try await HermesRelayClient(configuration: config)
                    .collect(payload, sessionKey: session, fast: false) { [weak self] text in
                        self?.setText(responseID, text)
                    }
                setText(responseID, replyText)
            } catch {
                if currentText(responseID).isEmpty,
                   let idx = messages.firstIndex(where: { $0.id == responseID }) {
                    messages.remove(at: idx)
                }
                messages.append(ChatMessage(author: .system, text: error.localizedDescription, date: Date()))
            }
            isSending = false
            // Clear the speaker glow when the reply finishes.
            NotificationCenter.default.post(name: .hermesDebateSpeaker, object: nil,
                                            userInfo: ["agentID": ""])
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

    private func setText(_ id: UUID, _ text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }
    private func currentText(_ id: UUID) -> String {
        messages.first { $0.id == id }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Conference Room screen

struct MeetingRoomView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var hub: MeetingHub
    @EnvironmentObject private var company: CompanyStore
    @StateObject private var convo: MeetingConversation
    @StateObject private var avatarStore = UserAvatarStore()
    @State private var draft = ""
    @State private var elapsed = 0
    @State private var showDebate = false
    @State private var showCustomize = false
    @State private var archiveSheet: ConferenceArchiveKind?
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
                MeetingRoomSceneView(
                    attendees: attendees,
                    avatar: avatarStore.avatar,
                    stats: RoomStats.from(state: company.state,
                                          liveTopic: company.liveMeeting?.topic),
                    onSelectAgent: { id in
                        if let agent = attendees.first(where: { $0.id == id }) {
                            convo.direct(to: agent)
                            focused = true
                        }
                    },
                    onSelectScreen: { name in
                        archiveSheet = (name == "screen-minutes") ? .minutes : .vault
                    })

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

            if let directed = convo.directedTarget {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.caption2)
                    Text("Talking to \(directed.name)").font(.caption.weight(.semibold))
                    Spacer()
                    Button { convo.directedTarget = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .foregroundStyle(.secondary)
                }
                .foregroundStyle(HermesTheme.emerald)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(HermesTheme.emerald.opacity(0.12))
            }

            ChatComposer(draft: $draft, focused: $focused, disabled: convo.isSending,
                         placeholder: convo.directedTarget.map { "Message \($0.name)" } ?? "Speak to the room") { attachments in
                convo.send(draft, attachments: attachments, relay: runtime.relayConfiguration,
                           context: CompanyContext.brief(org: org, hub: hub, company: company))
                draft = ""
            }
        }
        .keepScreenAwake()
        .navigationTitle("Conference Room")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCustomize = true } label: {
                    Label("Customize you", systemImage: "person.crop.circle.badge.plus")
                }
                .accessibilityLabel("Customize your seat")
            }
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
        .sheet(isPresented: $showCustomize) {
            AvatarCustomizeView(store: avatarStore)
        }
        .sheet(item: $archiveSheet) { kind in
            switch kind {
            case .minutes: MeetingMinutesView(messages: convo.messages, elapsed: elapsedText)
            case .vault:   DecisionVaultView(initiatives: company.state.initiatives)
            }
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
