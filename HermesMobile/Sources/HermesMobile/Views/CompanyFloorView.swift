import SceneKit
import SwiftUI
import UIKit

// MARK: - Company Floor: a grid of furnished office pods, one per department

struct CompanyFloorView: View {
    @EnvironmentObject private var org: OrgStore
    @State private var showAR = false
    private var pods: [OrgAgent] { org.leadership }
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.04, blue: 0.08),
                                    Color(red: 0.01, green: 0.02, blue: 0.045)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(pods) { agent in
                        NavigationLink {
                            OrgAgentDetailView(agent: agent)
                        } label: {
                            RoomPodCard(agent: agent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)

                HStack(spacing: 8) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("\(org.agents.count) Agents")
                        .font(.caption.weight(.semibold))
                    Text("· All Online")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            }
        }
        .navigationTitle("Company Floor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAR = true } label: {
                    Image(systemName: "arkit")
                }
                .accessibilityLabel("View headquarters in AR")
            }
        }
        .fullScreenCover(isPresented: $showAR) { ARHeadquartersView() }
    }
}

private struct RoomPodCard: View {
    let agent: OrgAgent

    private var label: String {
        agent.tier == .ceo ? "CEO" : agent.title
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoomDioramaSceneView(agent: agent)
                .frame(height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 6) {
                Image(systemName: agent.systemImage)
                    .font(.caption2.weight(.bold))
                Text(label)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
            .overlay(Capsule().stroke(Color(hex: agent.accentHex).opacity(0.6), lineWidth: 1))
            .padding(.top, 8)
        }
        .frame(height: 168)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(hex: agent.accentHex).opacity(0.55), lineWidth: 1.5)
        )
    }
}

// MARK: - AR access: a pod as a free-standing node

/// Extracts a department pod (room + furniture + seated robot) as a single
/// node for AR placement — reuses the full diorama builder, minus its
/// camera/lights (the AR session provides those).
enum CompanyPod {
    static func node(for agent: OrgAgent) -> SCNNode {
        let scene = RoomDioramaBuilder.scene(for: agent)
        let root = SCNNode()
        root.name = "pod-\(agent.id)"
        for child in scene.rootNode.childNodes where child.camera == nil && child.light == nil {
            root.addChildNode(child)   // reparents out of the throwaway scene
        }
        return root
    }
}

// MARK: - One office diorama (isometric, role-differentiated)

private struct RoomDioramaSceneView: UIViewRepresentable {
    var agent: OrgAgent

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.02, green: 0.035, blue: 0.06, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.isPlaying = true
        view.rendersContinuously = true
        view.scene = RoomDioramaBuilder.scene(for: agent)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

/// Builds each department's pod with a distinct identity — the whole point of
/// the floor: you can tell what a team does before reading its label.
private enum RoomDioramaBuilder {

    enum Role {
        case executive, finance, marketing, legal, research, engineering, operations, people, design, generic
    }

    static func role(for agent: OrgAgent) -> Role {
        if agent.tier == .ceo { return .executive }
        let s = (agent.title + " " + agent.name + " " + agent.summary).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }
        if has(["cfo", "financ", "account", "payroll", "procure", "budget"]) { return .finance }
        if has(["design", "creative", "art"]) { return .design }
        if has(["market", "content", "seo", "ads", "growth", "community", "brand"]) { return .marketing }
        if has(["legal", "lawyer", "complianc", "contract", "policy"]) { return .legal }
        if has(["research", "intelligence", "analyst"]) { return .research }
        if has(["build", "develop", "engineer", "cto", "devops", "qa", "command"]) { return .engineering }
        if has(["ops", "operation", "coo", "workflow", "task", "deliver"]) { return .operations }
        if has(["resource", "recruit", "training", "skills", "people", "hr"]) { return .people }
        if has(["strateg", "plan", "partnership", "product"]) { return .generic }
        return .generic
    }

    static func scene(for agent: OrgAgent) -> SCNScene {
        let scene = SCNScene()
        let accent = muted(UIColor(podHex: agent.accentHex))
        let r = role(for: agent)
        let seed = agent.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }

        addCamera(to: scene)
        addLights(to: scene, accent: accent, role: r)
        addShell(to: scene, accent: accent, role: r)
        addWallFeature(to: scene, accent: accent, role: r)
        addWorkstation(to: scene, agent: agent, accent: accent, role: r)
        addCozy(to: scene, accent: accent, role: r, seed: seed)
        addProps(to: scene, accent: accent, role: r)

        return scene
    }

    // MARK: Camera & light

    private static func addCamera(to scene: SCNScene) {
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 1.85          // wider frame for the bigger room
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(3.8, 3.5, 3.8)
        let target = SCNNode()
        target.position = SCNVector3(0, 0.7, -0.2)
        scene.rootNode.addChildNode(target)
        node.constraints = [SCNLookAtConstraint(target: target)]
        scene.rootNode.addChildNode(node)
    }

    private static func addLights(to scene: SCNScene, accent: UIColor, role: Role) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 330
        ambient.color = UIColor(white: 0.3, alpha: 1)
        let an = SCNNode(); an.light = ambient
        scene.rootNode.addChildNode(an)

        let key = SCNLight()
        key.type = .omni
        key.intensity = 820
        // The CEO's office is lit warm; everyone else neutral.
        key.color = role == .executive
            ? UIColor(red: 1.0, green: 0.92, blue: 0.78, alpha: 1)
            : UIColor(white: 0.95, alpha: 1)
        let kn = SCNNode(); kn.light = key
        kn.position = SCNVector3(1.5, 2.2, 1.8)
        scene.rootNode.addChildNode(kn)

        let fill = SCNLight()
        fill.type = .omni
        fill.intensity = 420
        fill.color = UIColor(white: 0.85, alpha: 1)
        let fn = SCNNode(); fn.light = fill
        fn.position = SCNVector3(-1.5, 1.6, 1.0)
        scene.rootNode.addChildNode(fn)
    }

    // MARK: Shell (floor + walls, role-tinted)

    private static func addShell(to scene: SCNScene, accent: UIColor, role: Role) {
        // Per-role floor finish. (Executive gets pale polished marble — luxury.)
        let floorMat: SCNMaterial
        switch role {
        case .executive:
            floorMat = pbr(diffuse: UIColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1), metalness: 0.3, roughness: 0.12) // polished marble
        case .legal:
            floorMat = pbr(diffuse: UIColor(red: 0.16, green: 0.115, blue: 0.08, alpha: 1), metalness: 0.05, roughness: 0.35) // walnut
        case .engineering, .operations:
            floorMat = pbr(diffuse: UIColor(red: 0.07, green: 0.085, blue: 0.1, alpha: 1), metalness: 0.7, roughness: 0.3)   // tech plate
        case .design, .marketing:
            floorMat = pbr(diffuse: UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1), metalness: 0.2, roughness: 0.6)   // studio concrete
        default:
            floorMat = pbr(diffuse: UIColor(red: 0.06, green: 0.09, blue: 0.12, alpha: 1), metalness: 0.6, roughness: 0.3)   // dark glass
        }
        // Bigger footprint + taller ceiling = spacious, not a cramped box.
        let floor = SCNNode(geometry: SCNBox(width: 2.9, height: 0.08, length: 2.9, chamferRadius: 0.02))
        floor.position = SCNVector3(0, -0.04, 0)
        floor.geometry?.firstMaterial = floorMat
        scene.rootNode.addChildNode(floor)

        // Walls, faintly tinted toward the department accent.
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        accent.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let wallColor = UIColor(hue: h, saturation: s * 0.25, brightness: 0.14, alpha: 1)
        let wall = pbr(diffuse: wallColor, metalness: 0.3, roughness: 0.6)

        let back = SCNNode(geometry: SCNBox(width: 2.9, height: 2.3, length: 0.08, chamferRadius: 0))
        back.position = SCNVector3(0, 1.1, -1.41)
        back.geometry?.firstMaterial = wall
        scene.rootNode.addChildNode(back)

        let left = SCNNode(geometry: SCNBox(width: 0.08, height: 2.3, length: 2.9, chamferRadius: 0))
        left.position = SCNVector3(-1.41, 1.1, 0)
        left.geometry?.firstMaterial = wall
        scene.rootNode.addChildNode(left)

        // Base trim — gold for the executive, accent for everyone else.
        let trimColor = role == .executive ? UIColor(red: 0.85, green: 0.7, blue: 0.4, alpha: 1) : accent
        let trimA = SCNNode(geometry: SCNBox(width: 2.9, height: 0.03, length: 0.03, chamferRadius: 0))
        trimA.position = SCNVector3(0, 0.02, 1.41)
        trimA.geometry?.firstMaterial = glow(trimColor.withAlphaComponent(0.8))
        scene.rootNode.addChildNode(trimA)
        let trimB = SCNNode(geometry: SCNBox(width: 0.03, height: 0.03, length: 2.9, chamferRadius: 0))
        trimB.position = SCNVector3(1.41, 0.02, 0)
        trimB.geometry?.firstMaterial = glow(trimColor.withAlphaComponent(0.8))
        scene.rootNode.addChildNode(trimB)
    }

    // MARK: Wall feature — the department's signature view

    private static func addWallFeature(to scene: SCNScene, accent: UIColor, role: Role) {
        if role == .executive {
            // Grand floor-to-ceiling window with the night skyline.
            let window = SCNNode(geometry: SCNPlane(width: 2.3, height: 1.85))
            window.position = SCNVector3(0.1, 1.18, -1.36)
            let m = SCNMaterial()
            let sky = skylineMini()
            m.diffuse.contents = sky
            m.emission.contents = sky
            m.emission.intensity = 0.7
            m.lightingModel = .constant
            window.geometry?.firstMaterial = m
            scene.rootNode.addChildNode(window)

            let gold = pbr(diffuse: UIColor(red: 0.62, green: 0.52, blue: 0.34, alpha: 1), metalness: 0.9, roughness: 0.25)
            for x in [Float(-1.0), -0.35, 0.4, 1.15] {
                let mull = SCNNode(geometry: SCNBox(width: 0.025, height: 1.85, length: 0.02, chamferRadius: 0))
                mull.position = SCNVector3(x, 1.18, -1.35)
                mull.geometry?.firstMaterial = gold
                scene.rootNode.addChildNode(mull)
            }
        } else {
            // Drawn role dashboard on the wall.
            let panel = SCNNode(geometry: SCNPlane(width: 1.15, height: 0.72))
            panel.position = SCNVector3(0.35, 1.2, -1.36)
            let m = SCNMaterial()
            let tex = wallTexture(role: role, accent: accent)
            m.diffuse.contents = tex
            m.emission.contents = tex
            m.emission.intensity = 0.8
            m.lightingModel = .constant
            panel.geometry?.firstMaterial = m
            scene.rootNode.addChildNode(panel)

            let frame = SCNNode(geometry: SCNBox(width: 1.22, height: 0.79, length: 0.02, chamferRadius: 0.01))
            frame.position = SCNVector3(0.35, 1.2, -1.38)
            frame.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.08, alpha: 1), metalness: 0.8, roughness: 0.3)
            scene.rootNode.addChildNode(frame)
        }
    }

    // MARK: Workstation — desk + chair + monitor + the robot SEATED at it,
    // the whole group angled toward the camera so the face shows.

    private static func addWorkstation(to scene: SCNScene, agent: OrgAgent, accent: UIColor, role: Role) {
        let deskMat: SCNMaterial
        switch role {
        case .executive, .legal:
            deskMat = pbr(diffuse: UIColor(red: 0.13, green: 0.09, blue: 0.065, alpha: 1), metalness: 0.05, roughness: 0.35)
        default:
            deskMat = pbr(diffuse: UIColor(red: 0.08, green: 0.1, blue: 0.13, alpha: 1), metalness: 0.6, roughness: 0.3)
        }
        let dark = pbr(diffuse: UIColor(white: 0.09, alpha: 1), metalness: 0.6, roughness: 0.35)

        let station = SCNNode()
        station.position = SCNVector3(-0.18, 0, -0.05)
        station.eulerAngles.y = 0.82          // face the isometric camera

        // Desk between robot and camera (local +z is "toward viewer").
        let top = SCNNode(geometry: SCNBox(width: 1.15, height: 0.06, length: 0.46, chamferRadius: 0.02))
        top.position = SCNVector3(0, 0.52, 0.22)
        top.geometry?.firstMaterial = deskMat
        station.addChildNode(top)
        for x in [Float(-0.5), 0.5] {
            let leg = SCNNode(geometry: SCNBox(width: 0.05, height: 0.52, length: 0.4, chamferRadius: 0.01))
            leg.position = SCNVector3(x, 0.26, 0.22)
            leg.geometry?.firstMaterial = deskMat
            station.addChildNode(leg)
        }

        // Monitor on the desk, screen toward the robot (back to camera).
        let bezel = SCNNode(geometry: SCNBox(width: 0.5, height: 0.32, length: 0.025, chamferRadius: 0.01))
        bezel.position = SCNVector3(0, 0.78, 0.28)
        bezel.geometry?.firstMaterial = dark
        station.addChildNode(bezel)
        let stand = SCNNode(geometry: SCNCylinder(radius: 0.02, height: 0.14))
        stand.position = SCNVector3(0, 0.6, 0.28)
        stand.geometry?.firstMaterial = dark
        station.addChildNode(stand)
        // Soft screen-light spill on the robot.
        let spill = SCNNode(geometry: SCNPlane(width: 0.46, height: 0.28))
        spill.position = SCNVector3(0, 0.78, 0.265)
        spill.eulerAngles.y = .pi
        let sm = SCNMaterial()
        sm.diffuse.contents = UIColor(red: 0.04, green: 0.08, blue: 0.1, alpha: 1)
        sm.emission.contents = accent.withAlphaComponent(0.5)
        sm.lightingModel = .constant
        spill.geometry?.firstMaterial = sm
        station.addChildNode(spill)

        // Desk clutter: mug + papers.
        let mug = SCNNode(geometry: SCNCylinder(radius: 0.035, height: 0.08))
        mug.position = SCNVector3(0.4, 0.59, 0.16)
        mug.geometry?.firstMaterial = pbr(diffuse: accent, metalness: 0.1, roughness: 0.4)
        station.addChildNode(mug)
        let papers = SCNNode(geometry: SCNBox(width: 0.16, height: 0.006, length: 0.22, chamferRadius: 0))
        papers.position = SCNVector3(-0.38, 0.555, 0.2)
        papers.eulerAngles.y = -0.2
        papers.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.85, alpha: 1), metalness: 0, roughness: 0.9)
        station.addChildNode(papers)

        // The chair — and the robot actually sitting on it.
        let chair = SCNNode()
        chair.position = SCNVector3(0, 0, -0.28)
        let seat = SCNNode(geometry: SCNCylinder(radius: 0.21, height: 0.06))
        seat.position = SCNVector3(0, 0.27, 0)
        seat.geometry?.firstMaterial = dark
        chair.addChildNode(seat)
        let backRest = SCNNode(geometry: SCNBox(width: 0.36, height: 0.42, length: 0.05, chamferRadius: 0.05))
        backRest.position = SCNVector3(0, 0.52, -0.2)
        backRest.eulerAngles.x = -0.08
        backRest.geometry?.firstMaterial = dark
        chair.addChildNode(backRest)
        let post = SCNNode(geometry: SCNCylinder(radius: 0.03, height: 0.24))
        post.position = SCNVector3(0, 0.12, 0)
        post.geometry?.firstMaterial = dark
        chair.addChildNode(post)
        for k in 0..<5 {
            let a = Float(k) / 5 * .pi * 2
            let footLeg = SCNNode(geometry: SCNBox(width: 0.03, height: 0.02, length: 0.18, chamferRadius: 0.01))
            footLeg.position = SCNVector3(sin(a) * 0.1, 0.02, cos(a) * 0.1)
            footLeg.eulerAngles.y = a
            footLeg.geometry?.firstMaterial = dark
            chair.addChildNode(footLeg)
        }
        station.addChildNode(chair)

        // Robot seated: lowered onto the seat, legs tucked behind the desk.
        let robot = AgentRobot.node(for: agent, color: accent)
        robot.scale = SCNVector3(0.5, 0.5, 0.5)
        robot.position = SCNVector3(0, 0.14, -0.28)
        station.addChildNode(robot)

        scene.rootNode.addChildNode(station)
    }

    // MARK: Cozy layer — rug, window, pendant lamp, sofa, plant, wall art

    private static func addCozy(to scene: SCNScene, accent: UIColor, role: Role, seed: Int) {
        // Rug under the workstation.
        let rug = SCNNode(geometry: SCNCylinder(radius: 0.78, height: 0.012))
        rug.position = SCNVector3(-0.18, 0.012, -0.05)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        accent.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        rug.geometry?.firstMaterial = pbr(diffuse: UIColor(hue: h, saturation: s * 0.35, brightness: 0.22, alpha: 1),
                                          metalness: 0, roughness: 0.95)
        scene.rootNode.addChildNode(rug)

        // Pendant lamp over the desk — warm, cozy pool of light.
        let cord = SCNNode(geometry: SCNCylinder(radius: 0.008, height: 0.42))
        cord.position = SCNVector3(-0.18, 1.66, -0.05)
        cord.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.1, alpha: 1), metalness: 0.5, roughness: 0.4)
        scene.rootNode.addChildNode(cord)
        let shade = SCNNode(geometry: SCNCone(topRadius: 0.035, bottomRadius: 0.12, height: 0.1))
        shade.position = SCNVector3(-0.18, 1.42, -0.05)
        shade.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.12, alpha: 1), metalness: 0.4, roughness: 0.4)
        scene.rootNode.addChildNode(shade)
        let bulb = SCNNode(geometry: SCNSphere(radius: 0.035))
        bulb.position = SCNVector3(-0.18, 1.39, -0.05)
        bulb.geometry?.firstMaterial = glow(UIColor(red: 1, green: 0.85, blue: 0.6, alpha: 0.95))
        scene.rootNode.addChildNode(bulb)
        let warm = SCNLight()
        warm.type = .omni
        warm.intensity = 220
        warm.color = UIColor(red: 1, green: 0.85, blue: 0.6, alpha: 1)
        warm.attenuationStartDistance = 0.1
        warm.attenuationEndDistance = 2.4
        let wn = SCNNode(); wn.light = warm
        wn.position = SCNVector3(-0.18, 1.35, -0.05)
        scene.rootNode.addChildNode(wn)

        // Window with the city on the left wall (where it doesn't fight a board).
        if role != .operations && role != .research && role != .executive {
            let window = SCNNode(geometry: SCNPlane(width: 0.95, height: 0.7))
            window.position = SCNVector3(-1.36, 1.12, 0.45)
            window.eulerAngles.y = .pi / 2
            let m = SCNMaterial()
            let sky = skylineMini()
            m.diffuse.contents = sky
            m.emission.contents = sky
            m.emission.intensity = 0.6
            m.lightingModel = .constant
            window.geometry?.firstMaterial = m
            scene.rootNode.addChildNode(window)
            let frame = SCNNode(geometry: SCNBox(width: 0.03, height: 0.76, length: 1.01, chamferRadius: 0.01))
            frame.position = SCNVector3(-1.38, 1.12, 0.45)
            frame.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.12, alpha: 1), metalness: 0.6, roughness: 0.35)
            scene.rootNode.addChildNode(frame)
        }

        // Lounge seating against the back wall. The executive (GM) gets a
        // proper, larger sofa + a coffee table; other roles get a tidy loveseat.
        if role == .executive {
            scene.rootNode.addChildNode(executiveLounge(h: h, s: s))
        } else if [Role.marketing, .people, .design, .generic, .research].contains(role) {
            let sofa = SCNNode()
            sofa.position = SCNVector3(0.85, 0, -1.15)
            let base = SCNNode(geometry: SCNBox(width: 0.62, height: 0.18, length: 0.3, chamferRadius: 0.04))
            base.position = SCNVector3(0, 0.13, 0)
            base.geometry?.firstMaterial = pbr(diffuse: UIColor(hue: h, saturation: s * 0.4, brightness: 0.3, alpha: 1),
                                               metalness: 0, roughness: 0.8)
            sofa.addChildNode(base)
            let backCushion = SCNNode(geometry: SCNBox(width: 0.62, height: 0.26, length: 0.08, chamferRadius: 0.04))
            backCushion.position = SCNVector3(0, 0.31, -0.11)
            backCushion.geometry?.firstMaterial = base.geometry?.firstMaterial
            sofa.addChildNode(backCushion)
            for dx in [Float(-0.155), 0.155] {
                let cushion = SCNNode(geometry: SCNBox(width: 0.28, height: 0.07, length: 0.26, chamferRadius: 0.03))
                cushion.position = SCNVector3(dx, 0.25, 0.01)
                cushion.geometry?.firstMaterial = pbr(diffuse: UIColor(hue: h, saturation: s * 0.3, brightness: 0.38, alpha: 1),
                                                      metalness: 0, roughness: 0.85)
                sofa.addChildNode(cushion)
            }
            scene.rootNode.addChildNode(sofa)
        }

        // Every office gets a plant — size and spot vary per agent.
        let plantX: Float = seed % 2 == 0 ? -0.88 : 0.92
        let plantZ: Float = seed % 2 == 0 ? 0.78 : 0.55
        let scalePlant: Float = 0.8 + Float(seed % 5) / 10
        let pot = SCNNode(geometry: SCNCylinder(radius: 0.1, height: 0.16))
        pot.position = SCNVector3(plantX, 0.08, plantZ)
        pot.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.14, green: 0.12, blue: 0.1, alpha: 1), metalness: 0.1, roughness: 0.8)
        scene.rootNode.addChildNode(pot)
        let green = pbr(diffuse: UIColor(red: 0.12, green: 0.4, blue: 0.21, alpha: 1), metalness: 0, roughness: 0.75)
        for (dx, dh, dz) in [(Float(0), Float(0.34), Float(0)), (-0.07, 0.26, 0.05), (0.07, 0.28, -0.05), (0.03, 0.2, 0.08)] {
            let leaf = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.085, height: CGFloat(dh * scalePlant)))
            leaf.position = SCNVector3(plantX + dx, 0.16 + dh * scalePlant / 2, plantZ + dz)
            leaf.geometry?.firstMaterial = green
            scene.rootNode.addChildNode(leaf)
        }

        // A piece of wall art beside the role screen.
        let art = SCNNode(geometry: SCNPlane(width: 0.3, height: 0.38))
        art.position = SCNVector3(-0.78, 1.25, -1.36)
        let artMat = SCNMaterial()
        artMat.diffuse.contents = UIColor(hue: h, saturation: s * 0.45, brightness: 0.42, alpha: 1)
        artMat.lightingModel = .constant
        art.geometry?.firstMaterial = artMat
        scene.rootNode.addChildNode(art)
        let artFrame = SCNNode(geometry: SCNBox(width: 0.34, height: 0.42, length: 0.015, chamferRadius: 0.005))
        artFrame.position = SCNVector3(-0.78, 1.25, -1.38)
        artFrame.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.55, green: 0.45, blue: 0.3, alpha: 1), metalness: 0.7, roughness: 0.35)
        scene.rootNode.addChildNode(artFrame)
    }

    /// The GM's lounge — a long leather sofa with gold feet + a glass-and-gold
    /// coffee table. The executive office's centerpiece comfort.
    private static func executiveLounge(h: CGFloat, s: CGFloat) -> SCNNode {
        let lounge = SCNNode()
        lounge.position = SCNVector3(0.7, 0, -1.02)
        let leather = pbr(diffuse: UIColor(red: 0.18, green: 0.13, blue: 0.10, alpha: 1), metalness: 0.1, roughness: 0.5)
        let gold = pbr(diffuse: UIColor(red: 0.82, green: 0.67, blue: 0.34, alpha: 1), metalness: 0.9, roughness: 0.25)

        let base = SCNNode(geometry: SCNBox(width: 1.0, height: 0.2, length: 0.42, chamferRadius: 0.05))
        base.position = SCNVector3(0, 0.16, 0)
        base.geometry?.firstMaterial = leather
        lounge.addChildNode(base)
        let backRest = SCNNode(geometry: SCNBox(width: 1.0, height: 0.34, length: 0.1, chamferRadius: 0.05))
        backRest.position = SCNVector3(0, 0.4, -0.16)
        backRest.geometry?.firstMaterial = leather
        lounge.addChildNode(backRest)
        for dx in [Float(-0.46), 0.46] {
            let arm = SCNNode(geometry: SCNBox(width: 0.1, height: 0.28, length: 0.42, chamferRadius: 0.05))
            arm.position = SCNVector3(dx, 0.34, 0)
            arm.geometry?.firstMaterial = leather
            lounge.addChildNode(arm)
        }
        let cushionMat = pbr(diffuse: UIColor(hue: h, saturation: s * 0.25, brightness: 0.22, alpha: 1),
                             metalness: 0.1, roughness: 0.6)
        for dx in [Float(-0.3), 0, 0.3] {
            let cushion = SCNNode(geometry: SCNBox(width: 0.3, height: 0.08, length: 0.38, chamferRadius: 0.04))
            cushion.position = SCNVector3(dx, 0.3, 0.01)
            cushion.geometry?.firstMaterial = cushionMat
            lounge.addChildNode(cushion)
        }
        for dx in [Float(-0.44), 0.44] {
            for dz in [Float(-0.16), 0.16] {
                let foot = SCNNode(geometry: SCNCylinder(radius: 0.022, height: 0.08))
                foot.position = SCNVector3(dx, 0.04, dz)
                foot.geometry?.firstMaterial = gold
                lounge.addChildNode(foot)
            }
        }
        // Glass + gold coffee table in front of the sofa.
        let table = SCNNode()
        table.position = SCNVector3(0, 0, 0.5)
        let glass = SCNNode(geometry: SCNBox(width: 0.6, height: 0.03, length: 0.34, chamferRadius: 0.02))
        glass.position = SCNVector3(0, 0.3, 0)
        glass.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.1, green: 0.14, blue: 0.16, alpha: 1), metalness: 0.3, roughness: 0.1)
        table.addChildNode(glass)
        for dx in [Float(-0.26), 0.26] {
            for dz in [Float(-0.13), 0.13] {
                let leg = SCNNode(geometry: SCNCylinder(radius: 0.012, height: 0.3))
                leg.position = SCNVector3(dx, 0.15, dz)
                leg.geometry?.firstMaterial = gold
                table.addChildNode(leg)
            }
        }
        lounge.addChildNode(table)
        return lounge
    }

    // MARK: Role props — the furniture that makes each pod ITS pod

    private static func addProps(to scene: SCNScene, accent: UIColor, role: Role) {
        let gold = pbr(diffuse: UIColor(red: 0.82, green: 0.67, blue: 0.34, alpha: 1), metalness: 0.9, roughness: 0.25)
        let dark = pbr(diffuse: UIColor(white: 0.1, alpha: 1), metalness: 0.6, roughness: 0.35)

        switch role {
        case .executive:
            // Globe on a stand + low credenza.
            let credenza = SCNNode(geometry: SCNBox(width: 0.7, height: 0.32, length: 0.3, chamferRadius: 0.02))
            credenza.position = SCNVector3(-0.85, 0.16, -0.9)
            credenza.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.13, green: 0.09, blue: 0.065, alpha: 1), metalness: 0.05, roughness: 0.35)
            scene.rootNode.addChildNode(credenza)
            let globe = SCNNode(geometry: SCNSphere(radius: 0.12))
            globe.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.1, green: 0.25, blue: 0.4, alpha: 1), metalness: 0.3, roughness: 0.4)
            globe.position = SCNVector3(0.85, 0.7, 0.55)
            scene.rootNode.addChildNode(globe)
            let stand = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 0.58))
            stand.geometry?.firstMaterial = gold
            stand.position = SCNVector3(0.85, 0.29, 0.55)
            scene.rootNode.addChildNode(stand)

        case .finance:
            // Gold coin stacks + a safe.
            for (i, x) in [Float(0.7), 0.86, 0.78].enumerated() {
                for c in 0..<(3 + i % 2) {
                    let coin = SCNNode(geometry: SCNCylinder(radius: 0.07, height: 0.025))
                    coin.geometry?.firstMaterial = gold
                    coin.position = SCNVector3(x, 0.013 + Float(c) * 0.027, 0.55 + Float(i) * 0.12 - 0.1)
                    scene.rootNode.addChildNode(coin)
                }
            }
            let safe = SCNNode(geometry: SCNBox(width: 0.4, height: 0.5, length: 0.35, chamferRadius: 0.02))
            safe.position = SCNVector3(-0.85, 0.25, -0.85)
            safe.geometry?.firstMaterial = dark
            scene.rootNode.addChildNode(safe)
            let dial = SCNNode(geometry: SCNCylinder(radius: 0.06, height: 0.02))
            dial.eulerAngles.x = .pi / 2
            dial.position = SCNVector3(-0.85, 0.28, -0.66)
            dial.geometry?.firstMaterial = gold
            scene.rootNode.addChildNode(dial)

        case .engineering:
            // Server rack with LED rows.
            let rack = SCNNode(geometry: SCNBox(width: 0.45, height: 1.15, length: 0.4, chamferRadius: 0.02))
            rack.position = SCNVector3(-0.82, 0.575, -0.82)
            rack.geometry?.firstMaterial = dark
            scene.rootNode.addChildNode(rack)
            for row in 0..<6 {
                for col in 0..<3 {
                    let led = SCNNode(geometry: SCNSphere(radius: 0.014))
                    let on = (row + col) % 3 != 0
                    led.geometry?.firstMaterial = glow((on ? UIColor(red: 0.3, green: 0.85, blue: 0.5, alpha: 1) : accent).withAlphaComponent(0.9))
                    led.position = SCNVector3(-0.7 + Float(col) * 0.09, 0.25 + Float(row) * 0.16, -0.61)
                    scene.rootNode.addChildNode(led)
                }
            }

        case .operations:
            // Kanban board on the side wall + crates.
            let board = SCNNode(geometry: SCNPlane(width: 0.9, height: 0.6))
            board.position = SCNVector3(-1.36, 1.0, 0.2)
            board.eulerAngles.y = .pi / 2
            board.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.12, alpha: 1), metalness: 0.2, roughness: 0.6)
            scene.rootNode.addChildNode(board)
            for col in 0..<3 {
                for card in 0..<(3 - col % 2) {
                    let note = SCNNode(geometry: SCNPlane(width: 0.2, height: 0.1))
                    note.position = SCNVector3(-1.35, 1.2 - Float(card) * 0.15, -0.05 + Float(col) * 0.26)
                    note.eulerAngles.y = .pi / 2
                    note.geometry?.firstMaterial = glow(accent.withAlphaComponent(0.55))
                    scene.rootNode.addChildNode(note)
                }
            }
            let crate = SCNNode(geometry: SCNBox(width: 0.32, height: 0.32, length: 0.32, chamferRadius: 0.02))
            crate.position = SCNVector3(0.85, 0.16, 0.6)
            crate.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.35, green: 0.27, blue: 0.18, alpha: 1), metalness: 0.05, roughness: 0.7)
            scene.rootNode.addChildNode(crate)

        case .marketing:
            // Megaphone on a tripod + billboard strip.
            let cone = SCNNode(geometry: SCNCone(topRadius: 0.05, bottomRadius: 0.14, height: 0.26))
            cone.geometry?.firstMaterial = pbr(diffuse: accent, metalness: 0.3, roughness: 0.4)
            cone.position = SCNVector3(0.85, 0.62, 0.55)
            cone.eulerAngles = SCNVector3(0.2, 0, -.pi / 2.4)
            scene.rootNode.addChildNode(cone)
            let tripod = SCNNode(geometry: SCNCylinder(radius: 0.02, height: 0.5))
            tripod.geometry?.firstMaterial = dark
            tripod.position = SCNVector3(0.85, 0.25, 0.55)
            scene.rootNode.addChildNode(tripod)
            let strip = SCNNode(geometry: SCNBox(width: 0.04, height: 0.5, length: 1.4, chamferRadius: 0.01))
            strip.position = SCNVector3(-1.35, 0.55, 0.2)
            strip.geometry?.firstMaterial = glow(accent.withAlphaComponent(0.35))
            scene.rootNode.addChildNode(strip)

        case .legal:
            // Bookshelf with rows of books + scales on the desk.
            let shelf = SCNNode(geometry: SCNBox(width: 0.5, height: 1.2, length: 0.3, chamferRadius: 0.01))
            shelf.position = SCNVector3(-0.82, 0.6, -0.82)
            shelf.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.13, green: 0.09, blue: 0.065, alpha: 1), metalness: 0.05, roughness: 0.4)
            scene.rootNode.addChildNode(shelf)
            let bookColors = [accent, UIColor(red: 0.5, green: 0.42, blue: 0.3, alpha: 1), UIColor(white: 0.55, alpha: 1)]
            for row in 0..<3 {
                for slot in 0..<4 {
                    let book = SCNNode(geometry: SCNBox(width: 0.055, height: 0.18, length: 0.12, chamferRadius: 0.004))
                    book.geometry?.firstMaterial = pbr(diffuse: bookColors[(row + slot) % 3], metalness: 0.05, roughness: 0.6)
                    book.position = SCNVector3(-0.93 + Float(slot) * 0.075, 0.32 + Float(row) * 0.34, -0.62)
                    scene.rootNode.addChildNode(book)
                }
            }
            let post = SCNNode(geometry: SCNCylinder(radius: 0.012, height: 0.26))
            post.geometry?.firstMaterial = gold
            post.position = SCNVector3(0.85, 0.13, 0.55)
            scene.rootNode.addChildNode(post)
            let beam = SCNNode(geometry: SCNBox(width: 0.22, height: 0.012, length: 0.012, chamferRadius: 0))
            beam.geometry?.firstMaterial = gold
            beam.position = SCNVector3(0.85, 0.26, 0.55)
            scene.rootNode.addChildNode(beam)
            for dx in [Float(-0.1), 0.1] {
                let pan = SCNNode(geometry: SCNCylinder(radius: 0.045, height: 0.01))
                pan.geometry?.firstMaterial = gold
                pan.position = SCNVector3(0.85 + dx, 0.21, 0.55)
                scene.rootNode.addChildNode(pan)
            }

        case .research:
            // Whiteboard on the side wall + magnifier on desk.
            let board = SCNNode(geometry: SCNPlane(width: 0.95, height: 0.62))
            board.position = SCNVector3(-1.36, 1.0, 0.2)
            board.eulerAngles.y = .pi / 2
            board.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.85, alpha: 1), metalness: 0, roughness: 0.6)
            scene.rootNode.addChildNode(board)
            var seed: UInt64 = 5
            func rnd() -> Float { seed = seed &* 2862933555777941757 &+ 3037000493; return Float((seed >> 33) % 1000) / 1000 }
            for _ in 0..<10 {
                let dot = SCNNode(geometry: SCNSphere(radius: 0.014))
                dot.geometry?.firstMaterial = glow(accent)
                dot.position = SCNVector3(-1.345, 0.75 + rnd() * 0.5, -0.2 + rnd() * 0.8)
                scene.rootNode.addChildNode(dot)
            }
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.07, pipeRadius: 0.013))
            ring.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.7, alpha: 1), metalness: 0.9, roughness: 0.25)
            ring.position = SCNVector3(0.85, 0.1, 0.55)
            ring.eulerAngles.x = .pi / 2.5
            scene.rootNode.addChildNode(ring)

        case .people:
            // A meeting corner: two guest chairs facing each other.
            for (x, rot) in [(Float(0.8), Float.pi / 2), (0.8, -.pi / 2)] {
                let chair = SCNNode()
                let seat = SCNNode(geometry: SCNBox(width: 0.26, height: 0.05, length: 0.26, chamferRadius: 0.03))
                seat.position = SCNVector3(0, 0.22, 0)
                seat.geometry?.firstMaterial = pbr(diffuse: accent, metalness: 0.1, roughness: 0.5)
                chair.addChildNode(seat)
                let back = SCNNode(geometry: SCNBox(width: 0.26, height: 0.3, length: 0.04, chamferRadius: 0.03))
                back.position = SCNVector3(0, 0.38, 0.12)
                back.geometry?.firstMaterial = pbr(diffuse: accent, metalness: 0.1, roughness: 0.5)
                chair.addChildNode(back)
                let post = SCNNode(geometry: SCNCylinder(radius: 0.025, height: 0.2))
                post.position = SCNVector3(0, 0.1, 0)
                post.geometry?.firstMaterial = dark
                chair.addChildNode(post)
                chair.position = SCNVector3(x, 0, rot > 0 ? 0.25 : 0.85)
                chair.eulerAngles.y = rot > 0 ? 0 : .pi
                scene.rootNode.addChildNode(chair)
            }

        case .design:
            // Easel with a color-swatch canvas.
            let canvas = SCNNode(geometry: SCNPlane(width: 0.5, height: 0.4))
            canvas.position = SCNVector3(0.8, 0.75, 0.55)
            canvas.eulerAngles = SCNVector3(-0.15, .pi / 4, 0)
            let cm = SCNMaterial()
            cm.diffuse.contents = swatchTexture(accent: accent)
            cm.lightingModel = .constant
            canvas.geometry?.firstMaterial = cm
            scene.rootNode.addChildNode(canvas)
            for dx in [Float(-0.18), 0.18] {
                let legNode = SCNNode(geometry: SCNCylinder(radius: 0.015, height: 0.8))
                legNode.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.35, green: 0.27, blue: 0.18, alpha: 1), metalness: 0.05, roughness: 0.6)
                legNode.position = SCNVector3(0.8 + dx, 0.4, 0.55 + abs(dx) * 0.4)
                legNode.eulerAngles.x = dx > 0 ? 0.18 : 0.18
                scene.rootNode.addChildNode(legNode)
            }

        case .generic:
            // The cozy layer (sofa, plant, art, window) furnishes this one.
            break
        }
    }

    // MARK: Drawn textures

    /// Compact role dashboard used on the wall panel and the desk monitor.
    private static func wallTexture(role: Role, accent: UIColor) -> UIImage {
        let size = CGSize(width: 460, height: 290)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            UIColor(red: 0.015, green: 0.035, blue: 0.05, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            c.setStrokeColor(accent.withAlphaComponent(0.5).cgColor)
            c.setLineWidth(3)
            c.stroke(CGRect(x: 4, y: 4, width: size.width - 8, height: size.height - 8))

            switch role {
            case .finance:
                let vals: [CGFloat] = [0.3, 0.42, 0.38, 0.55, 0.5, 0.72, 0.88]
                let rect = CGRect(x: 30, y: 40, width: 400, height: 210)
                let pts = vals.enumerated().map { i, v in
                    CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(vals.count - 1), y: rect.maxY - rect.height * v)
                }
                c.setStrokeColor(UIColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1).cgColor)
                c.setLineWidth(7); c.setLineJoin(.round)
                c.move(to: pts[0]); pts.dropFirst().forEach { c.addLine(to: $0) }; c.strokePath()
            case .engineering:
                var seed: UInt64 = 11
                func rnd() -> CGFloat { seed = seed &* 2862933555777941757 &+ 3037000493; return CGFloat((seed >> 33) % 1000) / 1000 }
                for i in 0..<7 {
                    c.setFillColor((i % 3 == 0 ? accent : UIColor(white: 0.55, alpha: 1)).withAlphaComponent(0.85).cgColor)
                    c.fill(CGRect(x: 26 + CGFloat(Int(rnd() * 3)) * 26, y: 30 + CGFloat(i) * 35, width: 90 + rnd() * 240, height: 13))
                }
            case .operations:
                for col in 0..<3 {
                    let x = 26 + CGFloat(col) * 142
                    c.setFillColor(UIColor(white: 1, alpha: 0.07).cgColor)
                    c.fill(CGRect(x: x, y: 28, width: 126, height: 234))
                    for card in 0..<(3 - col % 2) {
                        c.setFillColor(accent.withAlphaComponent(0.6).cgColor)
                        c.fill(CGRect(x: x + 10, y: 40 + CGFloat(card) * 58, width: 106, height: 44))
                    }
                }
            case .marketing:
                for (i, v) in [CGFloat(0.45), 0.75, 0.55, 0.9].enumerated() {
                    let h: CGFloat = 190 * v
                    c.setFillColor(accent.withAlphaComponent(0.85).cgColor)
                    c.fill(CGRect(x: 40 + CGFloat(i) * 105, y: 250 - h, width: 60, height: h))
                }
            case .legal:
                for i in 0..<6 {
                    c.setFillColor(UIColor(white: 0.8, alpha: i == 0 ? 0.9 : 0.35).cgColor)
                    c.fill(CGRect(x: 28, y: 34 + CGFloat(i) * 40, width: i == 0 ? 200 : 330 - CGFloat(i % 3) * 50, height: i == 0 ? 18 : 10))
                }
                c.setStrokeColor(accent.cgColor); c.setLineWidth(4)
                c.strokeEllipse(in: CGRect(x: 360, y: 190, width: 64, height: 64))
            case .research:
                var seed: UInt64 = 31
                func rnd() -> CGFloat { seed = seed &* 2862933555777941757 &+ 3037000493; return CGFloat((seed >> 33) % 1000) / 1000 }
                for _ in 0..<26 {
                    c.setFillColor(accent.withAlphaComponent(0.35 + rnd() * 0.6).cgColor)
                    c.fillEllipse(in: CGRect(x: 30 + rnd() * 390, y: 36 + rnd() * 215, width: 9, height: 9))
                }
            case .people:
                let centers = [(110, 90), (240, 60), (350, 110), (170, 200), (310, 210)]
                c.setStrokeColor(accent.withAlphaComponent(0.5).cgColor); c.setLineWidth(2.5)
                for i in 0..<centers.count {
                    for j in (i + 1)..<centers.count where (i + j) % 2 == 0 {
                        c.move(to: CGPoint(x: centers[i].0, y: centers[i].1))
                        c.addLine(to: CGPoint(x: centers[j].0, y: centers[j].1))
                    }
                }
                c.strokePath()
                for (x, y) in centers {
                    c.setFillColor(accent.cgColor)
                    c.fillEllipse(in: CGRect(x: x - 15, y: y - 15, width: 30, height: 30))
                }
            case .design:
                let colors: [UIColor] = [accent, UIColor(red: 0.85, green: 0.7, blue: 0.35, alpha: 1),
                                         UIColor(red: 0.35, green: 0.55, blue: 0.8, alpha: 1), UIColor(white: 0.75, alpha: 1)]
                for (i, col) in colors.enumerated() {
                    c.setFillColor(col.cgColor)
                    c.fill(CGRect(x: 28 + CGFloat(i % 2) * 210, y: 28 + CGFloat(i / 2) * 120, width: 195, height: 105))
                }
            case .executive, .generic:
                c.setFillColor(accent.withAlphaComponent(0.9).cgColor)
                c.fill(CGRect(x: 185, y: 32, width: 90, height: 38))
                c.setStrokeColor(accent.withAlphaComponent(0.6).cgColor); c.setLineWidth(2.5)
                for i in 0..<3 {
                    let x = 70 + CGFloat(i) * 125
                    c.move(to: CGPoint(x: 230, y: 70)); c.addLine(to: CGPoint(x: x + 45, y: 150)); c.strokePath()
                    c.setFillColor(UIColor(white: 1, alpha: 0.15).cgColor)
                    c.fill(CGRect(x: x, y: 150, width: 90, height: 36))
                }
            }
        }
    }

    /// Night skyline for the executive window.
    private static func skylineMini() -> UIImage {
        let size = CGSize(width: 600, height: 470)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let sky = CGGradient(colorsSpace: space, colors: [
                UIColor(red: 0.03, green: 0.07, blue: 0.18, alpha: 1).cgColor,
                UIColor(red: 0.01, green: 0.02, blue: 0.06, alpha: 1).cgColor
            ] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

            var x: CGFloat = -8
            var k: UInt64 = 17
            func rnd() -> CGFloat { k = k &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((k >> 33) % 1000) / 1000 }
            while x < size.width {
                let w = 45 + rnd() * 70
                let h = 130 + rnd() * 270
                c.setFillColor(UIColor(red: 0.02 + rnd() * 0.012, green: 0.035, blue: 0.07, alpha: 1).cgColor)
                c.fill(CGRect(x: x, y: size.height - h, width: w, height: h))
                var wy = size.height - h + 10
                while wy < size.height - 12 {
                    var wx = x + 6
                    while wx < x + w - 8 {
                        if rnd() > 0.55 {
                            let warm = rnd() > 0.5
                            c.setFillColor((warm
                                ? UIColor(red: 1, green: 0.83, blue: 0.5, alpha: 0.85)
                                : UIColor(red: 0.5, green: 0.8, blue: 1, alpha: 0.85)).cgColor)
                            c.fill(CGRect(x: wx, y: wy, width: 5, height: 3.6))
                        }
                        wx += 12
                    }
                    wy += 10
                }
                x += w + 6 + rnd() * 18
            }
        }
    }

    /// Color swatch canvas for the design easel.
    private static func swatchTexture(accent: UIColor) -> UIImage {
        let size = CGSize(width: 300, height: 240)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            UIColor(white: 0.92, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            let colors: [UIColor] = [accent, UIColor(red: 0.85, green: 0.7, blue: 0.35, alpha: 1),
                                     UIColor(red: 0.35, green: 0.55, blue: 0.8, alpha: 1),
                                     UIColor(red: 0.2, green: 0.3, blue: 0.25, alpha: 1)]
            for (i, col) in colors.enumerated() {
                c.setFillColor(col.cgColor)
                c.fill(CGRect(x: 22 + CGFloat(i % 2) * 135, y: 22 + CGFloat(i / 2) * 105, width: 120, height: 90))
            }
        }
    }

    // MARK: Materials

    private static func pbr(diffuse: UIColor, metalness: CGFloat, roughness: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = diffuse
        m.metalness.contents = metalness
        m.roughness.contents = roughness
        m.lightingModel = .physicallyBased
        return m
    }
    private static func glow(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial(); m.diffuse.contents = color; m.emission.contents = color; m.lightingModel = .constant; return m
    }
    /// Calm an accent into a muted, premium tone for the 3D pods (flat UI keeps the vivid hex).
    private static func muted(_ color: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        return UIColor(hue: h, saturation: s * 0.5, brightness: min(b, 0.7), alpha: a)
    }
}

private extension UIColor {
    convenience init(podHex: String) {
        let clean = podHex.replacingOccurrences(of: "#", with: "")
        let scanner = Scanner(string: clean)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
