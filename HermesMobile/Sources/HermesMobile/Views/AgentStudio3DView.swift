import SceneKit
import SwiftUI
import UIKit

// MARK: - War Room panel: swipe through the leadership's rooms (CEO + department heads)

struct AgentStudio3DPanel: View {
    @EnvironmentObject private var org: OrgStore
    @State private var selection = 0
    private var agents: [OrgAgent] { org.leadership }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AGENT STUDIO")
                        .font(.caption.weight(.black))
                    Text("Swipe through the leadership's rooms")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(title: "Live", color: .green, systemImage: "circle.fill")
            }

            TabView(selection: $selection) {
                ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                    AgentRoomView(agent: agent)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            // Layered ambient depth (Cinema Mobile tokens): soft drop + accent glow.
            .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            .shadow(color: HermesTheme.emerald.opacity(0.10), radius: 24, y: 4)
        }
    }
}

private struct AgentRoomView: View {
    var agent: OrgAgent

    var body: some View {
        ZStack(alignment: .bottom) {
            AgentRoomSceneView(agent: agent)

            // Frosted glass info bar (Cinema Mobile): name + role + live status,
            // kept at the bottom so the robot and dashboards stay unobstructed.
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(agent.title.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(Color(hex: agent.accentHex))
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 12)
            .padding(.bottom, 26)
        }
    }
}

// MARK: - One agent's room, rendered in SceneKit

struct AgentRoomSceneView: UIViewRepresentable {
    var agent: OrgAgent
    /// Pause Metal rendering entirely (e.g. while collapsed behind the
    /// keyboard) — an invisible HDR scene otherwise keeps eating GPU and
    /// makes typing lag.
    var paused: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.012, green: 0.02, blue: 0.035, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        // Ambient scenes don't need 60fps — 30 halves the GPU/battery cost.
        view.preferredFramesPerSecond = 30
        view.isPlaying = !paused
        view.scene = AgentRoomBuilder.scene(for: agent)
        context.coordinator.attach(to: view, agentID: agent.id)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.isPlaying = !paused
        uiView.scene?.isPaused = paused
        guard context.coordinator.agentID != agent.id else { return }
        uiView.scene = AgentRoomBuilder.scene(for: agent)
        uiView.scene?.isPaused = paused
        context.coordinator.attach(to: uiView, agentID: agent.id)
    }

    /// Listens for chat orders (`hermesRobotCommand`) and animates this
    /// room's robot when the order is addressed to its agent.
    /// Selector-based observer keeps Swift 6 strict concurrency happy.
    final class Coordinator: NSObject {
        var agentID: String?
        private weak var view: SCNView?
        private var home = SCNVector3Zero

        func attach(to view: SCNView, agentID: String) {
            self.view = view
            self.agentID = agentID
            if let robot = view.scene?.rootNode.childNode(withName: "robotRoot", recursively: true) {
                home = robot.position
            }
            NotificationCenter.default.removeObserver(self)
            NotificationCenter.default.addObserver(self, selector: #selector(handle(_:)),
                                                   name: .hermesRobotCommand, object: nil)
        }

        @objc private func handle(_ note: Notification) {
            guard let id = note.userInfo?["agentID"] as? String, id == agentID,
                  let raw = note.userInfo?["command"] as? String,
                  let command = RobotCommand(rawValue: raw),
                  let robot = view?.scene?.rootNode.childNode(withName: "robotRoot", recursively: true)
            else { return }
            AgentRobot.perform(command, on: robot, home: home)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: - Cinematic office builder

private enum AgentRoomBuilder {

    private static let tealAccent = UIColor(red: 0.3, green: 0.72, blue: 0.78, alpha: 1)

    static func scene(for agent: OrgAgent) -> SCNScene {
        let scene = SCNScene()
        let color = muted(UIColor(hexString: agent.accentHex))
        let roomKit = kit(for: agent)

        scene.lightingEnvironment.contents = environmentMap()
        scene.lightingEnvironment.intensity = 1.3
        scene.background.contents = UIColor(red: 0.012, green: 0.02, blue: 0.035, alpha: 1)
        scene.fogStartDistance = 7.5
        scene.fogEndDistance = 17
        scene.fogColor = UIColor(red: 0.01, green: 0.016, blue: 0.03, alpha: 1)

        addCamera(to: scene)
        addLights(to: scene, accent: color)
        addFloor(to: scene)

        if agent.tier == .ceo {
            addExecutiveBackdrop(to: scene)
        } else {
            addOfficeBackdrop(to: scene, agent: agent, accent: color)
        }
        addCredenza(to: scene, accent: color)
        addFloorLamp(to: scene)
        addPlant(to: scene, at: SCNVector3(-2.05, 0, 0.85))
        addDesk(to: scene, accent: color)
        addMonitor(to: scene, kit: roomKit, accent: color)
        addProp(kit: roomKit, accent: color, to: scene)

        let robot = AgentRobot.node(for: agent, color: color)
        robot.position = SCNVector3(0, 0, -0.1)
        scene.rootNode.addChildNode(robot)

        return scene
    }

    // MARK: Camera — DOF, vignette, gentle bloom: the cinematic look

    private static func addCamera(to scene: SCNScene) {
        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.bloomIntensity = 0.4
        camera.bloomThreshold = 0.55
        camera.bloomBlurRadius = 8
        camera.wantsDepthOfField = true
        camera.focusDistance = 3.3
        camera.fStop = 5.0
        camera.apertureBladeCount = 6
        camera.vignettingPower = 1.1
        camera.vignettingIntensity = 0.7
        camera.contrast = 1.06
        camera.saturation = 1.05
        camera.zFar = 60

        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(0.95, 1.62, 3.55)
        let target = SCNNode()
        target.position = SCNVector3(0, 0.92, 0.15)
        scene.rootNode.addChildNode(target)
        node.constraints = [SCNLookAtConstraint(target: target)]
        scene.rootNode.addChildNode(node)
    }

    private static func addLights(to scene: SCNScene, accent: UIColor) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 90
        ambient.color = UIColor(white: 0.28, alpha: 1)
        let an = SCNNode(); an.light = ambient
        scene.rootNode.addChildNode(an)

        // Warm key spot with soft shadows — the hero light on the robot.
        let key = SCNLight()
        key.type = .spot
        key.intensity = 950
        key.color = UIColor(red: 1.0, green: 0.93, blue: 0.82, alpha: 1)
        key.spotInnerAngle = 25
        key.spotOuterAngle = 70
        key.castsShadow = true
        key.shadowRadius = 14
        key.shadowColor = UIColor(white: 0, alpha: 0.65)
        let kn = SCNNode(); kn.light = key
        kn.position = SCNVector3(-2.0, 3.1, 2.4)
        let keyTarget = SCNNode()
        keyTarget.position = SCNVector3(0, 0.7, 0)
        scene.rootNode.addChildNode(keyTarget)
        kn.constraints = [SCNLookAtConstraint(target: keyTarget)]
        scene.rootNode.addChildNode(kn)

        // Cool teal rim from behind-right — separates the robot from the wall.
        let rim = SCNLight()
        rim.type = .omni
        rim.intensity = 330
        rim.color = UIColor(red: 0.45, green: 0.75, blue: 0.85, alpha: 1)
        let rn = SCNNode(); rn.light = rim
        rn.position = SCNVector3(1.9, 2.1, -1.5)
        scene.rootNode.addChildNode(rn)

        // The monitor's glow on the robot's face.
        let screenGlow = SCNLight()
        screenGlow.type = .omni
        screenGlow.intensity = 240
        screenGlow.color = accent
        screenGlow.attenuationStartDistance = 0.2
        screenGlow.attenuationEndDistance = 2.6
        let sg = SCNNode(); sg.light = screenGlow
        sg.position = SCNVector3(-0.3, 1.0, 0.5)
        scene.rootNode.addChildNode(sg)

        // Warm pool from the floor lamp.
        let lamp = SCNLight()
        lamp.type = .omni
        lamp.intensity = 170
        lamp.color = UIColor(red: 1.0, green: 0.8, blue: 0.55, alpha: 1)
        lamp.attenuationStartDistance = 0.2
        lamp.attenuationEndDistance = 3.2
        let ln = SCNNode(); ln.light = lamp
        ln.position = SCNVector3(1.62, 1.5, -1.1)
        scene.rootNode.addChildNode(ln)
    }

    private static func addFloor(to scene: SCNScene) {
        let floorGeo = SCNFloor()
        floorGeo.reflectivity = 0.26
        floorGeo.reflectionFalloffEnd = 6
        let fm = SCNMaterial()
        fm.diffuse.contents = UIColor(red: 0.02, green: 0.03, blue: 0.045, alpha: 1)
        fm.metalness.contents = 0.7
        fm.roughness.contents = 0.2
        fm.lightingModel = .physicallyBased
        floorGeo.firstMaterial = fm
        scene.rootNode.addChildNode(SCNNode(geometry: floorGeo))
    }

    // MARK: Backdrops

    /// Department office: panelled wall + a live drawn dashboard.
    private static func addOfficeBackdrop(to scene: SCNScene, agent: OrgAgent, accent: UIColor) {
        let wall = SCNNode(geometry: SCNPlane(width: 8.5, height: 3.6))
        wall.position = SCNVector3(0, 1.8, -2.15)
        wall.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.026, green: 0.038, blue: 0.058, alpha: 1),
                                           emission: .black, metalness: 0.25, roughness: 0.65)
        scene.rootNode.addChildNode(wall)

        // Vertical panel seams with a whisper of light.
        for x in [Float(-2.6), -1.3, 1.3, 2.6] {
            let seam = SCNNode(geometry: SCNBox(width: 0.012, height: 3.4, length: 0.012, chamferRadius: 0))
            seam.position = SCNVector3(x, 1.75, -2.13)
            seam.geometry?.firstMaterial = glow(tealAccent.withAlphaComponent(0.12))
            scene.rootNode.addChildNode(seam)
        }

        // Glowing baseboard.
        let base = SCNNode(geometry: SCNBox(width: 8.2, height: 0.02, length: 0.025, chamferRadius: 0))
        base.position = SCNVector3(0, 0.04, -2.1)
        base.geometry?.firstMaterial = glow(tealAccent.withAlphaComponent(0.45))
        scene.rootNode.addChildNode(base)

        // The department's live wall dashboard — real drawn content.
        let texture = dashboardTexture(title: agent.title.uppercased(), accent: accent)
        let bezel = SCNNode(geometry: SCNBox(width: 2.42, height: 1.42, length: 0.05, chamferRadius: 0.02))
        bezel.position = SCNVector3(0.95, 1.85, -2.1)
        bezel.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1),
                                            emission: .black, metalness: 0.85, roughness: 0.25)
        scene.rootNode.addChildNode(bezel)

        let panel = SCNNode(geometry: SCNPlane(width: 2.3, height: 1.3))
        panel.position = SCNVector3(0.95, 1.85, -2.07)
        let pm = SCNMaterial()
        pm.diffuse.contents = texture
        pm.emission.contents = texture
        pm.emission.intensity = 0.85
        pm.lightingModel = .constant
        panel.geometry?.firstMaterial = pm
        scene.rootNode.addChildNode(panel)

        // Brand plaque on the left.
        let plaque = SCNNode(geometry: SCNPlane(width: 0.85, height: 0.85))
        plaque.position = SCNVector3(-2.0, 1.9, -2.1)
        let plm = SCNMaterial()
        let plaqueImage = plaqueTexture(accent: accent)
        plm.diffuse.contents = plaqueImage
        plm.emission.contents = plaqueImage
        plm.emission.intensity = 0.6
        plm.lightingModel = .constant
        plaque.geometry?.firstMaterial = plm
        scene.rootNode.addChildNode(plaque)
    }

    /// CEO corner office: floor-to-ceiling glass over a painted night skyline.
    private static func addExecutiveBackdrop(to scene: SCNScene) {
        let sky = skylineTexture()
        let backdrop = SCNNode(geometry: SCNPlane(width: 7.6, height: 3.8))
        backdrop.position = SCNVector3(0, 1.9, -2.5)
        let bm = SCNMaterial()
        bm.diffuse.contents = sky
        bm.emission.contents = sky
        bm.emission.intensity = 0.55
        bm.lightingModel = .constant
        backdrop.geometry?.firstMaterial = bm
        scene.rootNode.addChildNode(backdrop)

        // Glass + champagne-gold mullions.
        let glass = SCNNode(geometry: SCNPlane(width: 7.0, height: 3.5))
        glass.position = SCNVector3(0, 1.75, -2.18)
        let gm = SCNMaterial()
        gm.diffuse.contents = UIColor(red: 0.4, green: 0.6, blue: 0.85, alpha: 0.05)
        gm.metalness.contents = 0.9
        gm.roughness.contents = 0.06
        gm.lightingModel = .physicallyBased
        gm.isDoubleSided = true
        gm.transparency = 0.45
        glass.geometry?.firstMaterial = gm
        scene.rootNode.addChildNode(glass)

        let gold = pbr(diffuse: UIColor(red: 0.62, green: 0.52, blue: 0.34, alpha: 1),
                       emission: .black, metalness: 0.9, roughness: 0.25)
        for x in stride(from: Float(-3.0), through: 3.0, by: 1.5) {
            let mull = SCNNode(geometry: SCNBox(width: 0.04, height: 3.5, length: 0.04, chamferRadius: 0))
            mull.position = SCNVector3(x, 1.75, -2.16)
            mull.geometry?.firstMaterial = gold
            scene.rootNode.addChildNode(mull)
        }

        let base = SCNNode(geometry: SCNBox(width: 7.0, height: 0.02, length: 0.025, chamferRadius: 0))
        base.position = SCNVector3(0, 0.04, -2.14)
        base.geometry?.firstMaterial = glow(UIColor(red: 0.85, green: 0.72, blue: 0.45, alpha: 0.5))
        scene.rootNode.addChildNode(base)
    }

    // MARK: Furniture

    private static func addCredenza(to scene: SCNScene, accent: UIColor) {
        let walnut = pbr(diffuse: UIColor(red: 0.13, green: 0.095, blue: 0.07, alpha: 1),
                         emission: .black, metalness: 0.05, roughness: 0.42)
        let body = SCNNode(geometry: SCNBox(width: 1.55, height: 0.52, length: 0.42, chamferRadius: 0.02))
        body.position = SCNVector3(-1.85, 0.26, -1.78)
        body.geometry?.firstMaterial = walnut
        scene.rootNode.addChildNode(body)

        // Books leaning on top.
        let bookColors = [accent, UIColor(red: 0.2, green: 0.28, blue: 0.4, alpha: 1), UIColor(white: 0.65, alpha: 1)]
        for (i, c) in bookColors.enumerated() {
            let book = SCNNode(geometry: SCNBox(width: 0.045, height: 0.26 - CGFloat(i) * 0.02, length: 0.18, chamferRadius: 0.004))
            book.position = SCNVector3(-2.28 + Float(i) * 0.07, 0.52 + 0.13, -1.78)
            book.eulerAngles.z = Float(i) * 0.06
            book.geometry?.firstMaterial = pbr(diffuse: c, emission: .black, metalness: 0.05, roughness: 0.6)
            scene.rootNode.addChildNode(book)
        }

        // Small plant on the credenza.
        let pot = SCNNode(geometry: SCNCylinder(radius: 0.07, height: 0.1))
        pot.position = SCNVector3(-1.45, 0.57, -1.78)
        pot.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.2, alpha: 1), emission: .black, metalness: 0.3, roughness: 0.5)
        scene.rootNode.addChildNode(pot)
        for (dx, h) in [(Float(0), Float(0.22)), (-0.05, 0.16), (0.05, 0.17)] {
            let leaf = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.045, height: CGFloat(h)))
            leaf.position = SCNVector3(-1.45 + dx, 0.62 + h / 2, -1.78)
            leaf.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.12, green: 0.4, blue: 0.22, alpha: 1),
                                               emission: .black, metalness: 0, roughness: 0.7)
            scene.rootNode.addChildNode(leaf)
        }
    }

    private static func addFloorLamp(to scene: SCNScene) {
        let chrome = pbr(diffuse: UIColor(white: 0.35, alpha: 1), emission: .black, metalness: 0.9, roughness: 0.3)
        let pole = SCNNode(geometry: SCNCylinder(radius: 0.018, height: 1.55))
        pole.position = SCNVector3(1.62, 0.775, -1.1)
        pole.geometry?.firstMaterial = chrome
        scene.rootNode.addChildNode(pole)

        let footBase = SCNNode(geometry: SCNCylinder(radius: 0.14, height: 0.02))
        footBase.position = SCNVector3(1.62, 0.01, -1.1)
        footBase.geometry?.firstMaterial = chrome
        scene.rootNode.addChildNode(footBase)

        let shade = SCNNode(geometry: SCNCone(topRadius: 0.07, bottomRadius: 0.15, height: 0.17))
        shade.position = SCNVector3(1.62, 1.6, -1.1)
        shade.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.12, alpha: 1), emission: .black, metalness: 0.4, roughness: 0.4)
        scene.rootNode.addChildNode(shade)

        let bulb = SCNNode(geometry: SCNSphere(radius: 0.045))
        bulb.position = SCNVector3(1.62, 1.55, -1.1)
        bulb.geometry?.firstMaterial = glow(UIColor(red: 1.0, green: 0.85, blue: 0.6, alpha: 0.95))
        scene.rootNode.addChildNode(bulb)
    }

    private static func addPlant(to scene: SCNScene, at pos: SCNVector3) {
        let pot = SCNNode(geometry: SCNCylinder(radius: 0.17, height: 0.3))
        pot.position = SCNVector3(pos.x, 0.15, pos.z)
        pot.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.09, green: 0.1, blue: 0.12, alpha: 1),
                                          emission: .black, metalness: 0.4, roughness: 0.5)
        scene.rootNode.addChildNode(pot)

        let green = pbr(diffuse: UIColor(red: 0.1, green: 0.36, blue: 0.2, alpha: 1),
                        emission: UIColor(red: 0, green: 0.03, blue: 0, alpha: 1), metalness: 0, roughness: 0.75)
        for (dx, h, dz) in [(Float(0), Float(0.8), Float(0)), (-0.12, 0.6, 0.08), (0.12, 0.65, -0.08), (0.05, 0.5, 0.12), (-0.07, 0.45, -0.1)] {
            let leaf = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.11, height: CGFloat(h)))
            leaf.position = SCNVector3(pos.x + dx, 0.3 + h / 2, pos.z + dz)
            leaf.geometry?.firstMaterial = green
            scene.rootNode.addChildNode(leaf)
        }
    }

    /// Premium walnut desk with an accent light edge + props.
    private static func addDesk(to scene: SCNScene, accent: UIColor) {
        let walnut = pbr(diffuse: UIColor(red: 0.155, green: 0.11, blue: 0.08, alpha: 1),
                         emission: .black, metalness: 0.05, roughness: 0.3)
        let darkPanel = pbr(diffuse: UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1),
                            emission: .black, metalness: 0.5, roughness: 0.35)

        let top = SCNNode(geometry: SCNBox(width: 1.95, height: 0.06, length: 0.72, chamferRadius: 0.02))
        top.position = SCNVector3(0, 0.585, 0.85)
        top.geometry?.firstMaterial = walnut
        scene.rootNode.addChildNode(top)

        // Modesty panel facing the camera.
        let front = SCNNode(geometry: SCNBox(width: 1.88, height: 0.52, length: 0.05, chamferRadius: 0.01))
        front.position = SCNVector3(0, 0.29, 1.16)
        front.geometry?.firstMaterial = darkPanel
        scene.rootNode.addChildNode(front)

        // Accent light line under the desk lip — the premium signature.
        let edge = SCNNode(geometry: SCNBox(width: 1.88, height: 0.012, length: 0.012, chamferRadius: 0))
        edge.position = SCNVector3(0, 0.553, 1.205)
        edge.geometry?.firstMaterial = glow(accent.withAlphaComponent(0.8))
        scene.rootNode.addChildNode(edge)

        // Side slab legs.
        for dx in [Float(-0.9), 0.9] {
            let leg = SCNNode(geometry: SCNBox(width: 0.06, height: 0.55, length: 0.6, chamferRadius: 0.01))
            leg.position = SCNVector3(dx, 0.275, 0.85)
            leg.geometry?.firstMaterial = darkPanel
            scene.rootNode.addChildNode(leg)
        }

        // Keyboard.
        let keyboard = SCNNode(geometry: SCNBox(width: 0.46, height: 0.015, length: 0.15, chamferRadius: 0.006))
        keyboard.position = SCNVector3(0.02, 0.625, 0.62)
        keyboard.geometry?.firstMaterial = darkPanel
        scene.rootNode.addChildNode(keyboard)
        for r in 0..<3 {
            let row = SCNNode(geometry: SCNBox(width: 0.42, height: 0.004, length: 0.03, chamferRadius: 0.002))
            row.position = SCNVector3(0.02, 0.634, 0.575 + Float(r) * 0.04)
            row.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.18, alpha: 1), emission: .black, metalness: 0.3, roughness: 0.5)
            scene.rootNode.addChildNode(row)
        }

        // Mug with accent glaze.
        let mug = SCNNode(geometry: SCNCylinder(radius: 0.045, height: 0.1))
        mug.position = SCNVector3(-0.75, 0.665, 0.72)
        mug.geometry?.firstMaterial = pbr(diffuse: accent, emission: .black, metalness: 0.1, roughness: 0.4)
        scene.rootNode.addChildNode(mug)

        // A few papers.
        let papers = SCNNode(geometry: SCNBox(width: 0.24, height: 0.006, length: 0.32, chamferRadius: 0))
        papers.position = SCNVector3(0.62, 0.62, 0.66)
        papers.eulerAngles.y = -0.25
        papers.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.85, alpha: 1), emission: .black, metalness: 0, roughness: 0.9)
        scene.rootNode.addChildNode(papers)
    }

    /// Monitor on the desk facing the robot, with real drawn screen content.
    private static func addMonitor(to scene: SCNScene, kit: RoomKit, accent: UIColor) {
        let darkMetal = pbr(diffuse: UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1),
                            emission: .black, metalness: 0.7, roughness: 0.3)

        let stand = SCNNode(geometry: SCNCylinder(radius: 0.025, height: 0.18))
        stand.position = SCNVector3(-0.38, 0.7, 0.92)
        stand.geometry?.firstMaterial = darkMetal
        scene.rootNode.addChildNode(stand)

        let foot = SCNNode(geometry: SCNCylinder(radius: 0.1, height: 0.015))
        foot.position = SCNVector3(-0.38, 0.62, 0.92)
        foot.geometry?.firstMaterial = darkMetal
        scene.rootNode.addChildNode(foot)

        let bezel = SCNNode(geometry: SCNBox(width: 0.78, height: 0.5, length: 0.03, chamferRadius: 0.012))
        bezel.position = SCNVector3(-0.38, 1.02, 0.92)
        bezel.eulerAngles.y = .pi          // screen faces the robot (-z side)
        bezel.geometry?.firstMaterial = darkMetal
        scene.rootNode.addChildNode(bezel)

        let texture = screenTexture(kit: kit, accent: accent)
        let screen = SCNNode(geometry: SCNPlane(width: 0.72, height: 0.44))
        screen.position = SCNVector3(-0.38, 1.02, 0.9)
        screen.eulerAngles.y = .pi
        let sm = SCNMaterial()
        sm.diffuse.contents = texture
        sm.emission.contents = texture
        sm.emission.intensity = 0.9
        sm.lightingModel = .constant
        screen.geometry?.firstMaterial = sm
        scene.rootNode.addChildNode(screen)
    }

    // MARK: Role props (on the desk)

    private static func addProp(kit roomKit: RoomKit, accent: UIColor, to scene: SCNScene) {
        let metal = pbr(diffuse: UIColor(white: 0.7, alpha: 1), emission: .black, metalness: 0.9, roughness: 0.25)
        let node = SCNNode()
        node.position = SCNVector3(0.62, 0.615, 0.95)

        switch roomKit {
        case .finance:
            for i in 0..<3 {
                let coin = SCNNode(geometry: SCNCylinder(radius: 0.05, height: 0.018))
                coin.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.85, green: 0.7, blue: 0.3, alpha: 1),
                                                   emission: .black, metalness: 0.9, roughness: 0.3)
                coin.position = SCNVector3(0, Float(i) * 0.02 + 0.01, 0)
                node.addChildNode(coin)
            }
        case .marketing:
            let cone = SCNNode(geometry: SCNCone(topRadius: 0.025, bottomRadius: 0.08, height: 0.16))
            cone.geometry?.firstMaterial = pbr(diffuse: accent, emission: .black, metalness: 0.3, roughness: 0.4)
            cone.position = SCNVector3(0, 0.06, 0)
            cone.eulerAngles.z = -.pi / 2.6
            node.addChildNode(cone)
        case .legal:
            let post = SCNNode(geometry: SCNCylinder(radius: 0.01, height: 0.22))
            post.geometry?.firstMaterial = metal
            post.position = SCNVector3(0, 0.11, 0)
            node.addChildNode(post)
            let beam = SCNNode(geometry: SCNBox(width: 0.2, height: 0.01, length: 0.01, chamferRadius: 0))
            beam.geometry?.firstMaterial = metal
            beam.position = SCNVector3(0, 0.21, 0)
            node.addChildNode(beam)
            for dx in [Float(-0.09), 0.09] {
                let pan = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 0.008))
                pan.geometry?.firstMaterial = metal
                pan.position = SCNVector3(dx, 0.17, 0)
                node.addChildNode(pan)
            }
        case .research:
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.06, pipeRadius: 0.012))
            ring.geometry?.firstMaterial = metal
            ring.position = SCNVector3(0, 0.1, 0)
            ring.eulerAngles.x = .pi / 2.4
            node.addChildNode(ring)
            let handle = SCNNode(geometry: SCNCylinder(radius: 0.008, height: 0.12))
            handle.geometry?.firstMaterial = metal
            handle.position = SCNVector3(0.05, 0.04, 0.03)
            handle.eulerAngles.z = 0.5
            node.addChildNode(handle)
        case .engineering, .operations:
            let hub = SCNNode(geometry: SCNCylinder(radius: 0.055, height: 0.02))
            hub.geometry?.firstMaterial = metal
            hub.position = SCNVector3(0, 0.05, 0)
            hub.eulerAngles.x = .pi / 2
            node.addChildNode(hub)
            for i in 0..<8 {
                let a = Float(i) / 8 * .pi * 2
                let tooth = SCNNode(geometry: SCNBox(width: 0.02, height: 0.02, length: 0.02, chamferRadius: 0.003))
                tooth.geometry?.firstMaterial = metal
                tooth.position = SCNVector3(cos(a) * 0.07, 0.05, sin(a) * 0.07)
                node.addChildNode(tooth)
            }
        case .people:
            for (dx, dz) in [(Float(-0.04), Float(0)), (0.04, 0), (0, 0.06)] {
                let p = SCNNode(geometry: SCNSphere(radius: 0.03))
                p.geometry?.firstMaterial = pbr(diffuse: accent, emission: .black, metalness: 0.2, roughness: 0.4)
                p.position = SCNVector3(dx, 0.03, dz)
                node.addChildNode(p)
            }
        case .design:
            let disc = SCNNode(geometry: SCNCylinder(radius: 0.07, height: 0.01))
            disc.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.85, alpha: 1), emission: .black, metalness: 0, roughness: 0.6)
            disc.position = SCNVector3(0, 0.01, 0)
            node.addChildNode(disc)
        case .coordinator, .generic:
            let tablet = SCNNode(geometry: SCNBox(width: 0.12, height: 0.008, length: 0.17, chamferRadius: 0.006))
            tablet.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.08, alpha: 1), emission: .black, metalness: 0.6, roughness: 0.3)
            tablet.position = SCNVector3(0, 0.01, 0)
            tablet.eulerAngles.y = 0.4
            node.addChildNode(tablet)
        }
        scene.rootNode.addChildNode(node)
    }

    // MARK: Role classification

    enum RoomKit {
        case coordinator, finance, marketing, legal, research, engineering, operations, people, design, generic
    }

    static func kit(for agent: OrgAgent) -> RoomKit {
        let s = (agent.title + " " + agent.name + " " + agent.summary).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }
        if has(["cfo", "financ", "account", "payroll", "procure", "budget", "report"]) { return .finance }
        if has(["design", "creative", "art"]) { return .design }
        if has(["market", "content", "seo", "ads", "growth", "community", "brand"]) { return .marketing }
        if has(["legal", "lawyer", "complianc", "contract", "policy"]) { return .legal }
        if has(["research", "intelligence", "analyst", "data"]) { return .research }
        if has(["build", "develop", "engineer", "cto", "devops", "qa", "frontend", "backend", "product"]) { return .engineering }
        if has(["ops", "operation", "coo", "workflow", "task", "quality", "deliver"]) { return .operations }
        if has(["resource", "training", "skills", "performance", "capacity", "recruit", "hr"]) { return .people }
        if has(["coordinator", "ceo", "manager", "strateg", "plan", "partnership"]) { return .coordinator }
        return .generic
    }

    // MARK: Drawn textures

    /// Department wall dashboard — title, line chart, gauge, rows.
    private static func dashboardTexture(title: String, accent: UIColor) -> UIImage {
        let size = CGSize(width: 920, height: 520)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            UIColor(red: 0.014, green: 0.035, blue: 0.05, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            c.setStrokeColor(tealAccent.withAlphaComponent(0.45).cgColor)
            c.setLineWidth(3)
            c.stroke(CGRect(x: 5, y: 5, width: size.width - 10, height: size.height - 10))

            (title as NSString).draw(at: CGPoint(x: 36, y: 26), withAttributes: [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold),
                .foregroundColor: UIColor(red: 0.78, green: 0.95, blue: 1, alpha: 1),
                .kern: 5
            ])
            ("● LIVE" as NSString).draw(at: CGPoint(x: size.width - 120, y: 32), withAttributes: [
                .font: UIFont.systemFont(ofSize: 19, weight: .bold),
                .foregroundColor: UIColor(red: 0.4, green: 0.9, blue: 0.6, alpha: 1)
            ])
            c.setStrokeColor(tealAccent.withAlphaComponent(0.3).cgColor)
            c.setLineWidth(2)
            c.move(to: CGPoint(x: 36, y: 84)); c.addLine(to: CGPoint(x: size.width - 36, y: 84)); c.strokePath()

            // Line chart.
            let chart = CGRect(x: 36, y: 110, width: 500, height: 200)
            c.setStrokeColor(UIColor(white: 1, alpha: 0.06).cgColor)
            c.setLineWidth(1)
            for i in 0...4 {
                let y = chart.minY + chart.height * CGFloat(i) / 4
                c.move(to: CGPoint(x: chart.minX, y: y)); c.addLine(to: CGPoint(x: chart.maxX, y: y))
            }
            c.strokePath()
            let vals: [CGFloat] = [0.55, 0.48, 0.62, 0.58, 0.72, 0.68, 0.85, 0.9]
            let pts = vals.enumerated().map { i, v in
                CGPoint(x: chart.minX + chart.width * CGFloat(i) / CGFloat(vals.count - 1), y: chart.maxY - chart.height * v)
            }
            c.setFillColor(accent.withAlphaComponent(0.15).cgColor)
            c.move(to: CGPoint(x: chart.minX, y: chart.maxY))
            pts.forEach { c.addLine(to: $0) }
            c.addLine(to: CGPoint(x: chart.maxX, y: chart.maxY)); c.closePath(); c.fillPath()
            c.setStrokeColor(accent.cgColor); c.setLineWidth(5); c.setLineJoin(.round)
            c.move(to: pts[0]); pts.dropFirst().forEach { c.addLine(to: $0) }; c.strokePath()

            // Gauge.
            let center = CGPoint(x: 740, y: 210)
            c.setLineWidth(18)
            c.setStrokeColor(UIColor(white: 0.16, alpha: 1).cgColor)
            c.addArc(center: center, radius: 70, startAngle: 0, endAngle: .pi * 2, clockwise: false); c.strokePath()
            c.setStrokeColor(UIColor(red: 0.35, green: 0.85, blue: 0.6, alpha: 1).cgColor)
            c.setLineCap(.round)
            c.addArc(center: center, radius: 70, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2 * 0.84, clockwise: false); c.strokePath()
            ("84%" as NSString).draw(at: CGPoint(x: center.x - 34, y: center.y - 20), withAttributes: [
                .font: UIFont.systemFont(ofSize: 36, weight: .heavy), .foregroundColor: UIColor.white
            ])

            // Status rows.
            for i in 0..<3 {
                let y = 350 + CGFloat(i) * 50
                c.setFillColor(accent.withAlphaComponent(0.8).cgColor)
                c.fillEllipse(in: CGRect(x: 40, y: y + 6, width: 10, height: 10))
                c.setFillColor(UIColor(white: 1, alpha: 0.12).cgColor)
                c.fill(CGRect(x: 64, y: y, width: 320 - CGFloat(i) * 60, height: 20))
            }
        }
    }

    /// Small brand plaque beside the dashboard.
    private static func plaqueTexture(accent: UIColor) -> UIImage {
        let size = CGSize(width: 360, height: 360)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            UIColor(red: 0.02, green: 0.03, blue: 0.045, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            c.setStrokeColor(accent.withAlphaComponent(0.8).cgColor)
            c.setLineWidth(5)
            c.strokeEllipse(in: CGRect(x: 60, y: 60, width: 240, height: 240))
            ("H" as NSString).draw(at: CGPoint(x: 128, y: 95), withAttributes: [
                .font: UIFont.systemFont(ofSize: 150, weight: .black),
                .foregroundColor: UIColor(red: 0.85, green: 0.75, blue: 0.5, alpha: 1)
            ])
        }
    }

    /// Per-role monitor content.
    private static func screenTexture(kit roomKit: RoomKit, accent: UIColor) -> UIImage {
        let size = CGSize(width: 700, height: 430)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            UIColor(red: 0.015, green: 0.035, blue: 0.05, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))

            // Title bar.
            c.setFillColor(UIColor(white: 1, alpha: 0.06).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: size.width, height: 48))
            c.setFillColor(accent.withAlphaComponent(0.9).cgColor)
            for i in 0..<3 { c.fillEllipse(in: CGRect(x: 18 + CGFloat(i) * 26, y: 17, width: 14, height: 14)) }

            switch roomKit {
            case .engineering:
                // Code lines.
                let palette = [accent, UIColor(red: 0.5, green: 0.8, blue: 1, alpha: 1), UIColor(white: 0.6, alpha: 1)]
                var seed: UInt64 = 7
                func rnd() -> CGFloat { seed = seed &* 2862933555777941757 &+ 3037000493; return CGFloat((seed >> 33) % 1000) / 1000 }
                for i in 0..<10 {
                    let y = 72 + CGFloat(i) * 34
                    let indent = CGFloat(Int(rnd() * 3)) * 36
                    c.setFillColor(palette[i % palette.count].withAlphaComponent(0.8).cgColor)
                    c.fill(CGRect(x: 28 + indent, y: y, width: 120 + rnd() * 320, height: 14))
                }
            case .finance:
                let vals: [CGFloat] = [0.3, 0.45, 0.4, 0.6, 0.55, 0.75, 0.9]
                let chart = CGRect(x: 30, y: 80, width: 420, height: 280)
                let pts = vals.enumerated().map { i, v in
                    CGPoint(x: chart.minX + chart.width * CGFloat(i) / CGFloat(vals.count - 1), y: chart.maxY - chart.height * v)
                }
                c.setStrokeColor(UIColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1).cgColor)
                c.setLineWidth(6); c.setLineJoin(.round)
                c.move(to: pts[0]); pts.dropFirst().forEach { c.addLine(to: $0) }; c.strokePath()
                ("+18.4%" as NSString).draw(at: CGPoint(x: 480, y: 110), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 44, weight: .heavy),
                    .foregroundColor: UIColor(red: 0.4, green: 0.9, blue: 0.6, alpha: 1)
                ])
            case .marketing:
                for (i, v) in [CGFloat(0.5), 0.8, 0.6, 0.95, 0.7].enumerated() {
                    let h: CGFloat = 260 * v
                    c.setFillColor(accent.withAlphaComponent(0.85).cgColor)
                    c.fill(CGRect(x: 50 + CGFloat(i) * 90, y: 370 - h, width: 52, height: h))
                }
            case .legal:
                for i in 0..<8 {
                    c.setFillColor(UIColor(white: 0.8, alpha: i == 0 ? 0.9 : 0.35).cgColor)
                    c.fill(CGRect(x: 36, y: 80 + CGFloat(i) * 38, width: i == 0 ? 280 : 400 - CGFloat(i % 3) * 60, height: i == 0 ? 20 : 12))
                }
                c.setStrokeColor(accent.cgColor); c.setLineWidth(5)
                c.strokeEllipse(in: CGRect(x: 540, y: 280, width: 90, height: 90))
            case .research:
                var seed: UInt64 = 99
                func rnd() -> CGFloat { seed = seed &* 2862933555777941757 &+ 3037000493; return CGFloat((seed >> 33) % 1000) / 1000 }
                for _ in 0..<40 {
                    c.setFillColor(accent.withAlphaComponent(0.3 + rnd() * 0.6).cgColor)
                    c.fillEllipse(in: CGRect(x: 40 + rnd() * 580, y: 80 + rnd() * 300, width: 10, height: 10))
                }
            case .operations:
                for col in 0..<3 {
                    let x = 36 + CGFloat(col) * 215
                    c.setFillColor(UIColor(white: 1, alpha: 0.05).cgColor)
                    c.fill(CGRect(x: x, y: 70, width: 195, height: 330))
                    for card in 0..<(3 - col % 2) {
                        c.setFillColor(accent.withAlphaComponent(0.55).cgColor)
                        c.fill(CGRect(x: x + 12, y: 86 + CGFloat(card) * 76, width: 171, height: 60))
                    }
                }
            case .people:
                let centers = [(170, 150), (350, 110), (520, 170), (260, 290), (450, 300)]
                c.setStrokeColor(accent.withAlphaComponent(0.5).cgColor); c.setLineWidth(3)
                for i in 0..<centers.count {
                    for j in (i + 1)..<centers.count where (i + j) % 2 == 0 {
                        c.move(to: CGPoint(x: centers[i].0, y: centers[i].1))
                        c.addLine(to: CGPoint(x: centers[j].0, y: centers[j].1))
                    }
                }
                c.strokePath()
                for (x, y) in centers {
                    c.setFillColor(accent.cgColor)
                    c.fillEllipse(in: CGRect(x: x - 22, y: y - 22, width: 44, height: 44))
                }
            case .design:
                let colors: [UIColor] = [accent, UIColor(red: 0.85, green: 0.7, blue: 0.35, alpha: 1),
                                         UIColor(red: 0.35, green: 0.55, blue: 0.8, alpha: 1), UIColor(white: 0.75, alpha: 1)]
                for (i, col) in colors.enumerated() {
                    c.setFillColor(col.cgColor)
                    c.fill(CGRect(x: 40 + CGFloat(i % 2) * 320, y: 80 + CGFloat(i / 2) * 170, width: 290, height: 140))
                }
            case .coordinator, .generic:
                // Org tree.
                c.setFillColor(accent.withAlphaComponent(0.9).cgColor)
                c.fill(CGRect(x: 290, y: 80, width: 120, height: 52))
                c.setStrokeColor(accent.withAlphaComponent(0.6).cgColor); c.setLineWidth(3)
                for i in 0..<3 {
                    let x = 120 + CGFloat(i) * 180
                    c.move(to: CGPoint(x: 350, y: 132)); c.addLine(to: CGPoint(x: x + 60, y: 220)); c.strokePath()
                    c.setFillColor(UIColor(white: 1, alpha: 0.15).cgColor)
                    c.fill(CGRect(x: x, y: 220, width: 120, height: 48))
                }
            }
        }
    }

    /// Night skyline behind the CEO's glass.
    private static func skylineTexture() -> UIImage {
        let size = CGSize(width: 1200, height: 600)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let sky = CGGradient(colorsSpace: space, colors: [
                UIColor(red: 0.03, green: 0.07, blue: 0.18, alpha: 1).cgColor,
                UIColor(red: 0.01, green: 0.02, blue: 0.06, alpha: 1).cgColor
            ] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            let horizon = CGGradient(colorsSpace: space, colors: [
                UIColor(red: 0.6, green: 0.45, blue: 0.2, alpha: 0.3).cgColor, UIColor.clear.cgColor
            ] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(horizon, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: size.height * 0.55), options: [])

            var x: CGFloat = -10
            var k: UInt64 = 23
            func rnd() -> CGFloat { k = k &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((k >> 33) % 1000) / 1000 }
            while x < size.width {
                let w = 55 + rnd() * 85
                let h = 150 + rnd() * 340
                c.setFillColor(UIColor(red: 0.02 + rnd() * 0.012, green: 0.035, blue: 0.07, alpha: 1).cgColor)
                c.fill(CGRect(x: x, y: size.height - h, width: w, height: h))
                var wy = size.height - h + 12
                while wy < size.height - 14 {
                    var wx = x + 7
                    while wx < x + w - 10 {
                        if rnd() > 0.55 {
                            let warm = rnd() > 0.5
                            c.setFillColor((warm
                                ? UIColor(red: 1, green: 0.83, blue: 0.5, alpha: 0.85)
                                : UIColor(red: 0.5, green: 0.8, blue: 1, alpha: 0.85)).cgColor)
                            c.fill(CGRect(x: wx, y: wy, width: 6, height: 4))
                        }
                        wx += 14
                    }
                    wy += 12
                }
                x += w + 7 + rnd() * 22
            }
        }
    }

    /// Tinted environment so PBR materials have something to reflect.
    private static func environmentMap() -> UIImage {
        let size = CGSize(width: 512, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let base = CGGradient(colorsSpace: space, colors: [
                UIColor(red: 0.06, green: 0.1, blue: 0.18, alpha: 1).cgColor,
                UIColor(red: 0.01, green: 0.015, blue: 0.035, alpha: 1).cgColor
            ] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            let blobs: [(CGFloat, CGFloat, CGFloat, UIColor)] = [
                (120, 55, 85, UIColor(red: 1.0, green: 0.85, blue: 0.6, alpha: 1)),
                (330, 60, 100, UIColor(red: 0.3, green: 0.65, blue: 0.8, alpha: 1)),
                (450, 85, 55, .white)
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

    private static func muted(_ color: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        return UIColor(hue: h, saturation: s * 0.5, brightness: min(b, 0.7), alpha: a)
    }

    private static func pbr(diffuse: UIColor, emission: UIColor, metalness: CGFloat, roughness: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = diffuse
        m.emission.contents = emission
        m.metalness.contents = metalness
        m.roughness.contents = roughness
        m.lightingModel = .physicallyBased
        return m
    }

    private static func glow(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.emission.contents = color
        m.lightingModel = .constant
        return m
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
