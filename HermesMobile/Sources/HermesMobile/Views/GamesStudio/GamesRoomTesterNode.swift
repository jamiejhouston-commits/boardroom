import SceneKit
import UIKit

/// A robot playtester gathered in front of the couch, controller in hand, testing
/// the current build on the mega screen. Reuses the bundled `Robot` USDZ (the
/// same character asset as the HQ staff), with a primitive fallback so a missing
/// asset degrades instead of crashing. The scene view drives `react()` off live
/// playtest data so the couch feels alive (playtest choreography).
final class GamesRoomTesterNode: SCNNode {

    private let body: SCNNode
    private let usesCharacterAsset: Bool

    init(accent: UIColor, facing yaw: Float) {
        let height: CGFloat = 1.55
        if let robot = HQAssetLibrary.node(named: "Robot", height: height,
                                           recolorYellowTo: accent, isCharacter: true) {
            HQAssetLibrary.playAnimation(matching: "Idle", under: robot)
            self.body = robot
            self.usesCharacterAsset = true
        } else {
            self.body = GamesRoomTesterNode.primitiveRobot(color: accent, height: height)
            self.usesCharacterAsset = false
        }
        super.init()
        eulerAngles.y = yaw
        addChildNode(body)
        addController(accent: accent)

        if !usesCharacterAsset {
            // Primitive body has no skeleton — keep an idle breathing bob.
            let bob = SCNAction.sequence([
                .moveBy(x: 0, y: 0.04, z: 0, duration: 1.5),
                .moveBy(x: 0, y: -0.04, z: 0, duration: 1.5),
            ])
            bob.timingMode = .easeInEaseOut
            body.runAction(.repeatForever(bob), forKey: "idle")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A small controller held out in front, so the pose reads as "playing".
    private func addController(accent: UIColor) {
        let pad = SCNBox(width: 0.26, height: 0.06, length: 0.16, chamferRadius: 0.03)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1)
        m.metalness.contents = 0.4; m.roughness.contents = 0.4
        pad.materials = [m]
        let node = SCNNode(geometry: pad)
        node.position = SCNVector3(0, 0.95, 0.28)
        // two tiny glowing buttons
        for (i, color) in [GamesRoomBuilder.emerald, GamesRoomBuilder.gold].enumerated() {
            let dot = SCNSphere(radius: 0.014)
            let dm = SCNMaterial(); dm.diffuse.contents = UIColor.black
            dm.emission.contents = color
            dot.materials = [dm]
            let dn = SCNNode(geometry: dot)
            dn.position = SCNVector3(0.05 + Float(i) * 0.04, 0.035, 0.06)
            node.addChildNode(dn)
        }
        addChildNode(node)
    }

    /// A quick reaction — a hop or a celebratory clip — driven by playtest data.
    func react(delighted: Bool) {
        if usesCharacterAsset, delighted,
           HQAssetLibrary.hasAnimation(matching: "Wave", under: body) {
            HQAssetLibrary.playAnimation(matching: "Wave", under: body)
            body.runAction(.sequence([
                .wait(duration: 1.6),
                .run { n in HQAssetLibrary.playAnimation(matching: "Idle", under: n) },
            ]), forKey: "react")
            return
        }
        let hop = SCNAction.sequence([
            .moveBy(x: 0, y: delighted ? 0.16 : 0.07, z: 0, duration: 0.16),
            .moveBy(x: 0, y: delighted ? -0.16 : -0.07, z: 0, duration: 0.2),
        ])
        hop.timingMode = .easeInEaseOut
        body.runAction(hop, forKey: "react")
    }

    private static func primitiveRobot(color: UIColor, height: CGFloat) -> SCNNode {
        let wrapper = SCNNode()
        let torso = SCNCapsule(capRadius: 0.22, height: height * 0.6)
        let tm = SCNMaterial(); tm.lightingModel = .physicallyBased
        tm.diffuse.contents = color; tm.roughness.contents = 0.5
        torso.materials = [tm]
        let torsoNode = SCNNode(geometry: torso)
        torsoNode.position = SCNVector3(0, Float(height * 0.4), 0)
        wrapper.addChildNode(torsoNode)
        let head = SCNSphere(radius: 0.2)
        head.materials = [tm]
        let headNode = SCNNode(geometry: head)
        headNode.position = SCNVector3(0, Float(height * 0.82), 0)
        wrapper.addChildNode(headNode)
        return wrapper
    }
}
