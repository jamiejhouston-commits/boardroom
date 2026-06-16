import SceneKit
import SwiftUI
import UIKit

/// A 3D project room for one initiative — the centerpiece and mood reflect the
/// stage: a planning desk while it's researched/debated, scaffolding around a
/// core that grows with progress while it's built, a spotlit pedestal at Demo
/// Day, a shipped crate + trophy once it ships. Drag to orbit.
struct InitiativeRoomView: View {
    let initiative: CompanyInitiative

    var body: some View {
        ZStack(alignment: .bottom) {
            InitiativeRoomSceneView(initiative: initiative)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                Text(initiative.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(initiative.stageLabel.uppercased())
                        .font(.caption2.weight(.black)).tracking(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(hex: InitiativeRoomScene.accentHex(initiative.stage)),
                                    in: Capsule())
                    Spacer()
                    Text("\(Int(initiative.progress * 100))%")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                ProgressView(value: initiative.progress)
                    .tint(Color(hex: InitiativeRoomScene.accentHex(initiative.stage)))
            }
            .padding(14)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding()
        }
        .navigationTitle("Project Room")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InitiativeRoomSceneView: UIViewRepresentable {
    let initiative: CompanyInitiative

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = InitiativeRoomScene.scene(for: initiative)
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 1)
        view.isPlaying = true
        view.rendersContinuously = true
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

enum InitiativeRoomScene {

    static func accentHex(_ stage: String) -> String {
        switch stage {
        case "research", "boardroom":      return "3C6FA0"   // steel — thinking
        case "gate1", "demo_ready", "gate2": return "C7A35A" // gold — your call / showcase
        case "planning", "execution":      return "2E9B72"   // emerald — building
        case "shipped":                    return "1C7A55"   // deep emerald — done
        case "killed":                     return "6B7280"   // gray — dead
        default:                           return "3C6FA0"
        }
    }

    static func scene(for initiative: CompanyInitiative) -> SCNScene {
        let scene = SCNScene()
        let accent = uiColor(initiative.stage == "killed" ? "3A3F46" : accentHex(initiative.stage))

        addCamera(to: scene)
        addLights(to: scene, accent: accent, dim: initiative.stage == "killed")
        addRoom(to: scene, accent: accent)

        let centerpiece = buildCenterpiece(for: initiative, accent: accent)
        centerpiece.position = SCNVector3(0, 0, 0)
        // Slow, calm turntable so you see it from all sides.
        centerpiece.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 26)))
        scene.rootNode.addChildNode(centerpiece)

        return scene
    }

    // MARK: Camera & lighting

    private static func addCamera(to scene: SCNScene) {
        let camera = SCNCamera()
        camera.fieldOfView = 48
        camera.wantsHDR = true
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(2.6, 2.2, 3.4)
        let target = SCNNode()
        target.position = SCNVector3(0, 0.7, 0)
        scene.rootNode.addChildNode(target)
        node.constraints = [SCNLookAtConstraint(target: target)]
        scene.rootNode.addChildNode(node)
    }

    private static func addLights(to scene: SCNScene, accent: UIColor, dim: Bool) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = dim ? 120 : 280
        ambient.color = UIColor(white: 0.8, alpha: 1)
        let ambientNode = SCNNode(); ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // A key spotlight from above-front, tinted by the stage accent.
        let key = SCNLight()
        key.type = .spot
        key.intensity = dim ? 500 : 1500
        key.color = accent
        key.spotInnerAngle = 25
        key.spotOuterAngle = 70
        key.castsShadow = true
        let keyNode = SCNNode(); keyNode.light = key
        keyNode.position = SCNVector3(1.6, 4.2, 2.4)
        keyNode.constraints = [SCNLookAtConstraint(target: scene.rootNode)]
        scene.rootNode.addChildNode(keyNode)
    }

    private static func addRoom(to scene: SCNScene, accent: UIColor) {
        let floor = SCNNode(geometry: SCNBox(width: 8, height: 0.2, length: 8, chamferRadius: 0.05))
        floor.position = SCNVector3(0, -0.1, 0)
        floor.geometry?.firstMaterial = pbr(UIColor(red: 0.06, green: 0.08, blue: 0.11, alpha: 1),
                                            metalness: 0.5, roughness: 0.5)
        scene.rootNode.addChildNode(floor)

        // Two back walls forming a corner, with a faint accent wash.
        for (offset, angle) in [(SCNVector3(0, 2, -3.2), Float(0)),
                                (SCNVector3(-3.2, 2, 0), Float.pi / 2)] {
            let wall = SCNNode(geometry: SCNBox(width: 6.4, height: 4, length: 0.15, chamferRadius: 0))
            wall.position = offset
            wall.eulerAngles.y = angle
            let material = pbr(UIColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1),
                               metalness: 0.2, roughness: 0.8)
            material.emission.contents = accent.withAlphaComponent(0.06)
            wall.geometry?.firstMaterial = material
            scene.rootNode.addChildNode(wall)
        }
    }

    // MARK: Stage centerpieces

    private static func buildCenterpiece(for initiative: CompanyInitiative, accent: UIColor) -> SCNNode {
        switch initiative.stage {
        case "research", "boardroom", "gate1":
            return planningDesk(accent: accent)
        case "planning", "execution", "demo_ready":
            return construction(progress: Float(initiative.progress), accent: accent)
        case "gate2":
            return pedestal(accent: accent, glowing: true)
        case "shipped":
            return shipped(accent: accent)
        default:
            return deadCube()
        }
    }

    /// Research / debate — a desk with a whiteboard and a floating idea.
    private static func planningDesk(accent: UIColor) -> SCNNode {
        let root = SCNNode()
        let desk = SCNNode(geometry: SCNBox(width: 1.6, height: 0.1, length: 0.8, chamferRadius: 0.02))
        desk.position = SCNVector3(0, 0.7, 0)
        desk.geometry?.firstMaterial = pbr(UIColor(white: 0.85, alpha: 1), metalness: 0.1, roughness: 0.4)
        root.addChildNode(desk)
        for x in [-0.7, 0.7] {
            for z in [-0.3, 0.3] {
                let leg = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 0.7))
                leg.position = SCNVector3(Float(x), 0.35, Float(z))
                leg.geometry?.firstMaterial = pbr(UIColor(white: 0.2, alpha: 1), metalness: 0.7, roughness: 0.3)
                root.addChildNode(leg)
            }
        }
        // Whiteboard behind the desk.
        let board = SCNNode(geometry: SCNBox(width: 1.4, height: 0.9, length: 0.05, chamferRadius: 0.02))
        board.position = SCNVector3(0, 1.5, -0.5)
        let bm = pbr(UIColor(white: 0.95, alpha: 1), metalness: 0, roughness: 0.6)
        bm.emission.contents = accent.withAlphaComponent(0.10)
        board.geometry?.firstMaterial = bm
        root.addChildNode(board)
        // A glowing idea hovering over the desk.
        let idea = SCNNode(geometry: SCNSphere(radius: 0.16))
        idea.position = SCNVector3(0, 1.15, 0)
        idea.geometry?.firstMaterial = glow(accent)
        idea.runAction(.repeatForever(.sequence([
            .moveBy(x: 0, y: 0.08, z: 0, duration: 1.4),
            .moveBy(x: 0, y: -0.08, z: 0, duration: 1.4)])))
        root.addChildNode(idea)
        return root
    }

    /// Building — scaffolding around a core that grows with progress.
    private static func construction(progress: Float, accent: UIColor) -> SCNNode {
        let root = SCNNode()
        let height = max(0.3, min(1.8, progress * 2.0))
        let core = SCNNode(geometry: SCNBox(width: 1.0, height: CGFloat(height), length: 1.0, chamferRadius: 0.04))
        core.position = SCNVector3(0, height / 2, 0)
        let cm = pbr(accent, metalness: 0.3, roughness: 0.4)
        cm.emission.contents = accent.withAlphaComponent(0.25)
        core.geometry?.firstMaterial = cm
        root.addChildNode(core)

        // Scaffold poles at the corners + a crossbeam — "under construction".
        let scaffoldMat = pbr(UIColor(red: 0.82, green: 0.67, blue: 0.34, alpha: 1), metalness: 0.8, roughness: 0.3)
        for x in [-0.7, 0.7] {
            for z in [-0.7, 0.7] {
                let pole = SCNNode(geometry: SCNCylinder(radius: 0.03, height: 2.0))
                pole.position = SCNVector3(Float(x), 1.0, Float(z))
                pole.geometry?.firstMaterial = scaffoldMat
                root.addChildNode(pole)
            }
        }
        let beam = SCNNode(geometry: SCNBox(width: 1.6, height: 0.05, length: 0.05, chamferRadius: 0))
        beam.position = SCNVector3(0, height + 0.15, 0.7)
        beam.geometry?.firstMaterial = scaffoldMat
        root.addChildNode(beam)
        return root
    }

    /// Demo Day — a glowing product cube on a spotlit pedestal.
    private static func pedestal(accent: UIColor, glowing: Bool) -> SCNNode {
        let root = SCNNode()
        let base = SCNNode(geometry: SCNCylinder(radius: 0.8, height: 0.4))
        base.position = SCNVector3(0, 0.2, 0)
        base.geometry?.firstMaterial = pbr(UIColor(white: 0.15, alpha: 1), metalness: 0.6, roughness: 0.3)
        root.addChildNode(base)
        let product = SCNNode(geometry: SCNBox(width: 0.7, height: 0.7, length: 0.7, chamferRadius: 0.06))
        product.position = SCNVector3(0, 0.95, 0)
        product.geometry?.firstMaterial = glowing ? glow(accent) : pbr(accent, metalness: 0.3, roughness: 0.3)
        product.runAction(.repeatForever(.sequence([
            .moveBy(x: 0, y: 0.1, z: 0, duration: 1.6),
            .moveBy(x: 0, y: -0.1, z: 0, duration: 1.6)])))
        root.addChildNode(product)
        return root
    }

    /// Shipped — a sealed crate with a trophy spire and a ring of confetti.
    private static func shipped(accent: UIColor) -> SCNNode {
        let root = SCNNode()
        let crate = SCNNode(geometry: SCNBox(width: 1.1, height: 1.1, length: 1.1, chamferRadius: 0.05))
        crate.position = SCNVector3(0, 0.65, 0)
        crate.geometry?.firstMaterial = pbr(UIColor(red: 0.45, green: 0.32, blue: 0.18, alpha: 1),
                                            metalness: 0.1, roughness: 0.7)
        root.addChildNode(crate)
        // Trophy spire (cone) on top.
        let trophy = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.28, height: 0.7))
        trophy.position = SCNVector3(0, 1.55, 0)
        trophy.geometry?.firstMaterial = glow(UIColor(red: 0.82, green: 0.67, blue: 0.34, alpha: 1))
        root.addChildNode(trophy)
        // A ring of small glowing confetti dots.
        for i in 0..<12 {
            let angle = Float(i) / 12 * .pi * 2
            let dot = SCNNode(geometry: SCNSphere(radius: 0.05))
            dot.position = SCNVector3(cos(angle) * 1.3, 1.7, sin(angle) * 1.3)
            dot.geometry?.firstMaterial = glow(accent)
            root.addChildNode(dot)
        }
        return root
    }

    private static func deadCube() -> SCNNode {
        let node = SCNNode(geometry: SCNBox(width: 0.9, height: 0.9, length: 0.9, chamferRadius: 0.04))
        node.position = SCNVector3(0, 0.5, 0)
        node.geometry?.firstMaterial = pbr(UIColor(white: 0.22, alpha: 1), metalness: 0.2, roughness: 0.9)
        return node
    }

    // MARK: Materials

    private static func pbr(_ color: UIColor, metalness: CGFloat, roughness: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metalness
        m.roughness.contents = roughness
        return m
    }

    private static func glow(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.emission.contents = color
        m.metalness.contents = 0.1
        m.roughness.contents = 0.3
        return m
    }

    private static func uiColor(_ hex: String) -> UIColor {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
