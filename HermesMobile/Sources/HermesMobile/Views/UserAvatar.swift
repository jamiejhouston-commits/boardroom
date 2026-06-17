import SceneKit
import SwiftUI
import UIKit

/// The human owner who sits at the conference table. Built to represent anyone —
/// skin tone, build, hairstyle + colour, facial hair, and outfit — and persisted
/// so "you" look the same every time you walk into the room.
struct UserAvatar: Codable, Equatable {
    var skinTone: String          // hex
    var build: String             // "slim" | "average" | "broad"
    var hairStyle: String         // "bald" | "buzz" | "short" | "long" | "bun" | "afro"
    var hairColor: String         // hex
    var facialHair: String        // "none" | "stubble" | "beard"
    var outfitStyle: String       // "tee" | "hoodie" | "suit"
    var outfitColor: String       // hex

    static let `default` = UserAvatar(skinTone: "8D5A3C", build: "average",
                                      hairStyle: "bald", hairColor: "2B2118",
                                      facialHair: "beard", outfitStyle: "tee",
                                      outfitColor: "1C7A55")

    // Options the editor offers.
    static let skinTones = ["F1C9A5", "E0A87E", "C68642", "8D5A3C", "5C3A21", "3B2417"]
    static let hairColors = ["111111", "2B2118", "5A3A22", "A9772F", "9A9A9A", "B23A2A"]
    static let outfitColors = ["1C7A55", "23426B", "8C2F39", "C7A35A", "2B2D33", "6B4E9E"]
    static let builds = ["slim", "average", "broad"]
    static let hairStyles = ["bald", "buzz", "short", "long", "bun", "afro"]
    static let facialHairs = ["none", "stubble", "beard"]
    static let outfitStyles = ["tee", "hoodie", "suit"]

    static func buildLabel(_ s: String) -> String {
        switch s { case "slim": return "Slim"; case "broad": return "Broad"; default: return "Average" }
    }
    static func hairLabel(_ s: String) -> String {
        switch s {
        case "buzz": return "Buzz"; case "short": return "Short"; case "long": return "Long"
        case "bun": return "Bun"; case "afro": return "Afro"; default: return "Bald"
        }
    }
    static func facialLabel(_ s: String) -> String {
        switch s { case "stubble": return "Stubble"; case "beard": return "Beard"; default: return "Clean" }
    }
    static func styleLabel(_ s: String) -> String {
        switch s { case "hoodie": return "Hoodie"; case "suit": return "Suit"; default: return "Tee" }
    }

    static func color(_ hex: String) -> UIColor {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// Loads/saves the avatar to UserDefaults so it persists across launches.
@MainActor
final class UserAvatarStore: ObservableObject {
    @Published var avatar: UserAvatar { didSet { save() } }
    private static let key = "user.avatar.v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(UserAvatar.self, from: data) {
            avatar = decoded
        } else {
            avatar = .default
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(avatar) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - 3D human builder (SceneKit primitives — matches the robots' scale)

enum UserAvatarBuilder {
    /// Local space: base at y=0, faces +z, ~1.5 tall (matches AgentRobot before scaling).
    static func node(for avatar: UserAvatar) -> SCNNode {
        let root = SCNNode()
        root.name = "user-avatar"
        let skin = pbr(UserAvatar.color(avatar.skinTone), roughness: 0.7)
        let outfit = pbr(UserAvatar.color(avatar.outfitColor), roughness: 0.6)
        let hairMat = pbr(UserAvatar.color(avatar.hairColor), roughness: 0.95)
        let dark = pbr(UIColor(white: 0.1, alpha: 1), roughness: 0.8)

        let bw: CGFloat = avatar.build == "slim" ? 0.46 : (avatar.build == "broad" ? 0.6 : 0.52)

        // Torso (the outfit) — width follows build.
        let torso = SCNNode(geometry: SCNBox(width: bw, height: 0.62, length: 0.34, chamferRadius: 0.14))
        torso.position = SCNVector3(0, 0.74, 0)
        torso.geometry?.firstMaterial = outfit
        root.addChildNode(torso)

        // Neck + head.
        let neck = SCNNode(geometry: SCNCylinder(radius: 0.075, height: 0.13))
        neck.position = SCNVector3(0, 1.08, 0)
        neck.geometry?.firstMaterial = skin
        root.addChildNode(neck)

        let head = SCNNode(geometry: SCNSphere(radius: 0.18))
        head.position = SCNVector3(0, 1.30, 0)
        head.geometry?.firstMaterial = skin
        root.addChildNode(head)
        let crownBack = SCNNode(geometry: SCNSphere(radius: 0.185))
        crownBack.position = SCNVector3(0, 1.29, -0.02)
        crownBack.scale = SCNVector3(1.04, 0.94, 0.9)
        crownBack.geometry?.firstMaterial = skin
        root.addChildNode(crownBack)

        // Eyes + brow.
        for dx in [Float(-0.066), 0.066] {
            let eye = SCNNode(geometry: SCNSphere(radius: 0.024))
            eye.position = SCNVector3(dx, 1.32, 0.158)
            eye.geometry?.firstMaterial = pbr(UIColor(white: 0.07, alpha: 1), roughness: 0.3)
            root.addChildNode(eye)
        }
        let brow = SCNNode(geometry: SCNBox(width: 0.2, height: 0.018, length: 0.03, chamferRadius: 0.008))
        brow.position = SCNVector3(0, 1.375, 0.16)
        brow.geometry?.firstMaterial = dark
        root.addChildNode(brow)

        addHair(avatar, to: root, mat: hairMat)
        addFacialHair(avatar, to: root)

        // Arms — bare skin for a tee, sleeved for hoodie/suit. Spread with build.
        let sleeved = avatar.outfitStyle != "tee"
        let armMat = sleeved ? outfit : skin
        let armX = Float(bw) / 2 + 0.055
        for side in [Float(-1), 1] {
            let arm = SCNNode(geometry: SCNCapsule(capRadius: 0.062, height: 0.46))
            arm.position = SCNVector3(side * armX, 0.74, 0.04)
            arm.eulerAngles.z = Float(side) * 0.2
            arm.geometry?.firstMaterial = armMat
            root.addChildNode(arm)
        }

        // Outfit flourishes.
        switch avatar.outfitStyle {
        case "suit":
            let collar = SCNNode(geometry: SCNBox(width: bw - 0.02, height: 0.16, length: 0.36, chamferRadius: 0.1))
            collar.position = SCNVector3(0, 0.98, 0.01)
            collar.geometry?.firstMaterial = pbr(UIColor(white: 0.93, alpha: 1), roughness: 0.5)
            root.addChildNode(collar)
            let tie = SCNNode(geometry: SCNBox(width: 0.07, height: 0.34, length: 0.02, chamferRadius: 0.01))
            tie.position = SCNVector3(0, 0.82, 0.18)
            tie.geometry?.firstMaterial = pbr(UIColor(red: 0.55, green: 0.12, blue: 0.16, alpha: 1), roughness: 0.5)
            root.addChildNode(tie)
        case "hoodie":
            let hood = SCNNode(geometry: SCNTorus(ringRadius: 0.16, pipeRadius: 0.07))
            hood.position = SCNVector3(0, 1.04, -0.08)
            hood.eulerAngles.x = .pi / 2.2
            hood.geometry?.firstMaterial = outfit
            root.addChildNode(hood)
        default:
            let neckline = SCNNode(geometry: SCNTorus(ringRadius: 0.1, pipeRadius: 0.02))
            neckline.position = SCNVector3(0, 1.0, 0.02)
            neckline.eulerAngles.x = .pi / 2
            neckline.geometry?.firstMaterial = pbr(UserAvatar.color(avatar.outfitColor).withAlphaComponent(0.85), roughness: 0.6)
            root.addChildNode(neckline)
        }

        // Seated lap (mostly hidden by the table, grounds the figure).
        let lap = SCNNode(geometry: SCNBox(width: bw - 0.06, height: 0.16, length: 0.4, chamferRadius: 0.08))
        lap.position = SCNVector3(0, 0.46, 0.16)
        lap.geometry?.firstMaterial = pbr(UIColor(white: 0.12, alpha: 1), roughness: 0.7)
        root.addChildNode(lap)

        // Gentle idle breathing.
        head.runAction(.repeatForever(.sequence([
            .moveBy(x: 0, y: 0.012, z: 0, duration: 2.2),
            .moveBy(x: 0, y: -0.012, z: 0, duration: 2.2)
        ])))
        return root
    }

    /// Hair sits on the crown / behind the head — never over the face.
    private static func addHair(_ avatar: UserAvatar, to root: SCNNode, mat: SCNMaterial) {
        func cap(radius: CGFloat, y: Float, scale: SCNVector3, z: Float) {
            let node = SCNNode(geometry: SCNSphere(radius: radius))
            node.position = SCNVector3(0, y, z)
            node.scale = scale
            node.geometry?.firstMaterial = mat
            root.addChildNode(node)
        }
        func backMass(radius: CGFloat, y: Float, z: Float, scale: SCNVector3) {
            let node = SCNNode(geometry: SCNSphere(radius: radius))
            node.position = SCNVector3(0, y, z)
            node.scale = scale
            node.geometry?.firstMaterial = mat
            root.addChildNode(node)
        }
        switch avatar.hairStyle {
        case "buzz":
            cap(radius: 0.176, y: 1.46, scale: SCNVector3(1.05, 0.52, 1.05), z: -0.02)
        case "short":
            cap(radius: 0.186, y: 1.45, scale: SCNVector3(1.07, 0.64, 1.08), z: -0.03)
        case "afro":
            cap(radius: 0.23, y: 1.5, scale: SCNVector3(1.12, 0.9, 1.12), z: -0.04)
        case "long":
            cap(radius: 0.188, y: 1.45, scale: SCNVector3(1.07, 0.66, 1.08), z: -0.03)
            backMass(radius: 0.17, y: 1.12, z: -0.1, scale: SCNVector3(1.05, 1.7, 0.7))
        case "bun":
            cap(radius: 0.184, y: 1.45, scale: SCNVector3(1.05, 0.62, 1.06), z: -0.03)
            let bun = SCNNode(geometry: SCNSphere(radius: 0.075))
            bun.position = SCNVector3(0, 1.52, -0.1)
            bun.geometry?.firstMaterial = mat
            root.addChildNode(bun)
        default:
            break   // bald
        }
    }

    private static func addFacialHair(_ avatar: UserAvatar, to root: SCNNode) {
        guard avatar.facialHair != "none" else { return }
        let full = avatar.facialHair == "beard"
        let base = UserAvatar.color(avatar.hairColor)
        let color = full ? base : base.withAlphaComponent(0.55)
        let mat = pbr(color, roughness: 0.95)

        let beard = SCNNode(geometry: SCNSphere(radius: full ? 0.155 : 0.15))
        beard.position = SCNVector3(0, full ? 1.19 : 1.21, 0.055)
        beard.scale = SCNVector3(1.02, full ? 0.78 : 0.55, full ? 0.95 : 0.9)
        beard.geometry?.firstMaterial = mat
        root.addChildNode(beard)

        let mouth = SCNNode(geometry: SCNBox(width: 0.12, height: 0.02, length: 0.03, chamferRadius: 0.008))
        mouth.position = SCNVector3(0, 1.235, 0.165)
        mouth.geometry?.firstMaterial = mat
        root.addChildNode(mouth)
    }

    private static func pbr(_ color: UIColor, roughness: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = 0.05
        m.roughness.contents = roughness
        return m
    }
}

// MARK: - Customize "you" editor (with a live 3D preview)

struct AvatarCustomizeView: View {
    @ObservedObject var store: UserAvatarStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AvatarPreview(avatar: store.avatar)
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                        .background(Color(red: 0.02, green: 0.03, blue: 0.05))
                }

                Section("Skin tone") {
                    swatches(UserAvatar.skinTones, selected: store.avatar.skinTone) { store.avatar.skinTone = $0 }
                }

                Section("Build") {
                    Picker("Build", selection: $store.avatar.build) {
                        ForEach(UserAvatar.builds, id: \.self) { Text(UserAvatar.buildLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Hair") {
                    Picker("Style", selection: $store.avatar.hairStyle) {
                        ForEach(UserAvatar.hairStyles, id: \.self) { Text(UserAvatar.hairLabel($0)).tag($0) }
                    }
                    if store.avatar.hairStyle != "bald" {
                        swatches(UserAvatar.hairColors, selected: store.avatar.hairColor) { store.avatar.hairColor = $0 }
                    }
                }

                Section("Facial hair") {
                    Picker("Facial hair", selection: $store.avatar.facialHair) {
                        ForEach(UserAvatar.facialHairs, id: \.self) { Text(UserAvatar.facialLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Outfit") {
                    Picker("Style", selection: $store.avatar.outfitStyle) {
                        ForEach(UserAvatar.outfitStyles, id: \.self) { Text(UserAvatar.styleLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    swatches(UserAvatar.outfitColors, selected: store.avatar.outfitColor) { store.avatar.outfitColor = $0 }
                }
            }
            .navigationTitle("Customize You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func swatches(_ hexes: [String], selected: String, pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 12) {
            ForEach(hexes, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(.white, lineWidth: selected == hex ? 3 : 0))
                    .overlay(Circle().strokeBorder(HermesTheme.hairline, lineWidth: 1))
                    .onTapGesture { pick(hex) }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// Small spinning 3D preview of the avatar in the editor.
private struct AvatarPreview: UIViewRepresentable {
    var avatar: UserAvatar

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.scene = Self.scene(for: avatar)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene = Self.scene(for: avatar)
    }

    private static func scene(for avatar: UserAvatar) -> SCNScene {
        let scene = SCNScene()
        let person = UserAvatarBuilder.node(for: avatar)
        person.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 14)))
        scene.rootNode.addChildNode(person)

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 36
        cam.position = SCNVector3(0, 1.15, 2.6)
        cam.look(at: SCNVector3(0, 1.05, 0))
        scene.rootNode.addChildNode(cam)

        let key = SCNLight(); key.type = .omni; key.intensity = 900
        let kn = SCNNode(); kn.light = key; kn.position = SCNVector3(1.5, 2.5, 2.5)
        scene.rootNode.addChildNode(kn)
        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 350
        let an = SCNNode(); an.light = amb; scene.rootNode.addChildNode(an)
        return scene
    }
}
