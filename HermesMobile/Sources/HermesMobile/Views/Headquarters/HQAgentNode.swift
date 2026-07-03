import SceneKit
import SwiftUI
import UIKit

/// One agent living on the HQ floor: the bundled robot character (role-tinted,
/// executive scaled up and gold) playing its skeletal idle clip, plus a
/// floating holographic status ring whose color and pulse reflect the agent's
/// live state. Non-executive agents occasionally stroll toward the command
/// dais and back so the floor never sits frozen.
final class HQAgentNode: SCNNode {

    let agentID: String
    private let ring: SCNNode
    private let body: SCNNode
    private let usesCharacterAsset: Bool

    init(placement: HQPlacement) {
        self.agentID = placement.agent.id
        self.ring = HQAgentNode.makeRing()

        let isExecutive = placement.archetype == .executive
        let accent: UIColor = isExecutive
            ? UIColor(red: 0.72, green: 0.55, blue: 0.26, alpha: 1)   // deep gold, never blown
            : UIColor(Color(hex: placement.agent.accentHex))
        let height: CGFloat = isExecutive ? 2.0 : 1.7

        if let robot = HQAssetLibrary.node(named: "Robot", height: height,
                                           recolorYellowTo: accent, isCharacter: true) {
            HQAssetLibrary.playAnimation(matching: "Idle", under: robot)
            self.body = robot
            self.usesCharacterAsset = true
        } else {
            // Bundle missing → the old primitive robot, never a crash.
            self.body = AgentRobot.node(for: placement.agent,
                                        color: UIColor(Color(hex: placement.agent.accentHex)))
            self.usesCharacterAsset = false
        }

        super.init()

        position = placement.anchor
        eulerAngles.y = placement.yaw
        addChildNode(body)

        ring.position = SCNVector3(0, Float(height) + 0.35, 0)
        addChildNode(ring)

        if usesCharacterAsset {
            if !isExecutive { startStrolling() }
        } else {
            // Primitive body has no skeleton — keep the idle breathing bob.
            let bob = SCNAction.sequence([
                .moveBy(x: 0, y: 0.045, z: 0, duration: 1.6),
                .moveBy(x: 0, y: -0.045, z: 0, duration: 1.6),
            ])
            bob.timingMode = .easeInEaseOut
            body.runAction(.repeatForever(bob))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Live status

    /// Recolor + re-pulse the status ring. No allocation beyond material color;
    /// safe to call every state update.
    func applyStatus(_ status: HQAgentStatus) {
        if let material = ring.geometry?.firstMaterial {
            material.diffuse.contents = status.tint
            material.emission.contents = status.tint.withAlphaComponent(0.9)
        }
        ring.removeAllActions()
        let pulse = SCNAction.sequence([
            .fadeOpacity(to: 0.35, duration: status.pulse),
            .fadeOpacity(to: 1.0, duration: status.pulse),
        ])
        pulse.timingMode = .easeInEaseOut
        ring.runAction(.repeatForever(pulse), forKey: "pulse")
        ring.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 9)), forKey: "spin")
    }

    // MARK: Ambient life

    /// Every so often, walk a short loop toward the dais and back: turn, play
    /// the walking clip, glide, turn home, idle again. Closures capture nothing
    /// beyond their node parameter (strict-concurrency safe).
    private func startStrolling() {
        let home = position
        let homeYaw = eulerAngles.y
        let out = SCNVector3(home.x * 0.35, home.y, home.z + 3.2)
        let dx = out.x - home.x, dz = out.z - home.z
        let outYaw = atan2(-dx, -dz)
        let backYaw = atan2(dx, dz)

        let walkOn = SCNAction.run { n in HQAssetLibrary.playAnimation(matching: "Walking", under: n) }
        let idleOn = SCNAction.run { n in HQAssetLibrary.playAnimation(matching: "Idle", under: n) }

        let loop = SCNAction.sequence([
            .wait(duration: 12, withRange: 18),
            .rotateTo(x: 0, y: CGFloat(outYaw), z: 0, duration: 0.5, usesShortestUnitArc: true),
            walkOn,
            .move(to: out, duration: 3.4),
            idleOn,
            .rotateTo(x: 0, y: CGFloat(backYaw), z: 0, duration: 0.5, usesShortestUnitArc: true),
            .wait(duration: 5, withRange: 6),
            walkOn,
            .move(to: home, duration: 3.4),
            idleOn,
            .rotateTo(x: 0, y: CGFloat(homeYaw), z: 0, duration: 0.5, usesShortestUnitArc: true),
        ])
        runAction(.repeatForever(loop), forKey: "stroll")
    }

    private static func makeRing() -> SCNNode {
        let torus = SCNTorus(ringRadius: 0.42, pipeRadius: 0.05)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        material.emission.contents = UIColor.white
        torus.materials = [material]
        let node = SCNNode(geometry: torus)
        node.eulerAngles.x = .pi / 2   // lie flat → halo above the head
        return node
    }
}
