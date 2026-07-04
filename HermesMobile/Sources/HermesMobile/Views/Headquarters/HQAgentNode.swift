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
    let isExecutive: Bool
    private let ring: SCNNode
    private let body: SCNNode
    private let usesCharacterAsset: Bool
    private let homeAnchor: SCNVector3
    private let homeYaw: Float
    private(set) var isConversing = false
    private(set) var isInMeeting = false

    init(placement: HQPlacement) {
        self.agentID = placement.agent.id
        self.homeAnchor = placement.anchor
        self.homeYaw = placement.yaw
        self.ring = HQAgentNode.makeRing()

        let isExecutive = placement.archetype == .executive
        self.isExecutive = isExecutive
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

    // MARK: Face-to-face conversation

    /// The owner tapped this agent: stop wandering, turn to face them, wave
    /// (when the rig carries the clip), and hold attention until released.
    func enterConversation(facing worldPoint: SCNVector3) {
        guard !isConversing else { return }
        isConversing = true
        isInMeeting = false
        removeAction(forKey: "stroll")
        removeAction(forKey: "meeting")
        let dx = worldPoint.x - worldPosition.x
        let dz = worldPoint.z - worldPosition.z
        let face = atan2(-dx, -dz)          // model forward is -Z
        runAction(.rotateTo(x: 0, y: CGFloat(face), z: 0, duration: 0.4,
                            usesShortestUnitArc: true), forKey: "converse.turn")
        guard usesCharacterAsset else { return }
        if HQAssetLibrary.hasAnimation(matching: "Wave", under: body) {
            HQAssetLibrary.playAnimation(matching: "Wave", under: body)
            body.runAction(.sequence([
                .wait(duration: 1.7),
                .run { n in HQAssetLibrary.playAnimation(matching: "Idle", under: n) },
            ]), forKey: "wave.reset")
        } else {
            HQAssetLibrary.playAnimation(matching: "Idle", under: body)
        }
    }

    /// Conversation over: face home and resume ambient life.
    func leaveConversation() {
        guard isConversing else { return }
        isConversing = false
        removeAction(forKey: "converse.turn")
        body.removeAction(forKey: "wave.reset")
        if usesCharacterAsset { HQAssetLibrary.playAnimation(matching: "Idle", under: body) }
        runAction(.rotateTo(x: 0, y: CGFloat(homeYaw), z: 0, duration: 0.5,
                            usesShortestUnitArc: true))
        if usesCharacterAsset, !isExecutive, !isInMeeting { startStrolling() }
    }

    // MARK: Live-meeting choreography

    /// A live board meeting pulled this agent in: walk to the dais seat, face
    /// the holo-globe, and stand in the huddle until the meeting ends.
    func joinMeeting(at point: SCNVector3, facing center: SCNVector3) {
        guard !isInMeeting, !isConversing else { return }
        isInMeeting = true
        removeAction(forKey: "stroll")
        let walkYaw = HQAgentNode.yaw(from: position, toward: point)
        let faceYaw = HQAgentNode.yaw(from: point, toward: center)
        let travel = HQAgentNode.travelTime(from: position, to: point)
        let walkOn = SCNAction.run { n in HQAssetLibrary.playAnimation(matching: "Walking", under: n) }
        let idleOn = SCNAction.run { n in HQAssetLibrary.playAnimation(matching: "Idle", under: n) }
        runAction(.sequence([
            .rotateTo(x: 0, y: CGFloat(walkYaw), z: 0, duration: 0.4, usesShortestUnitArc: true),
            walkOn,
            .move(to: point, duration: travel),
            idleOn,
            .rotateTo(x: 0, y: CGFloat(faceYaw), z: 0, duration: 0.4, usesShortestUnitArc: true),
        ]), forKey: "meeting")
    }

    /// Meeting adjourned: walk back to the desk and resume ambient life.
    func leaveMeeting() {
        guard isInMeeting else { return }
        isInMeeting = false
        removeAction(forKey: "meeting")
        let walkYaw = HQAgentNode.yaw(from: position, toward: homeAnchor)
        let travel = HQAgentNode.travelTime(from: position, to: homeAnchor)
        let walkOn = SCNAction.run { n in HQAssetLibrary.playAnimation(matching: "Walking", under: n) }
        let idleOn = SCNAction.run { n in HQAssetLibrary.playAnimation(matching: "Idle", under: n) }
        // The action's node IS this agent — no self capture (Sendable-safe,
        // matching the walkOn/idleOn closures above).
        let resume = SCNAction.run { n in
            guard let agent = n as? HQAgentNode, agent.usesCharacterAsset,
                  !agent.isExecutive, !agent.isInMeeting, !agent.isConversing else { return }
            agent.startStrolling()
        }
        runAction(.sequence([
            .rotateTo(x: 0, y: CGFloat(walkYaw), z: 0, duration: 0.4, usesShortestUnitArc: true),
            walkOn,
            .move(to: homeAnchor, duration: travel),
            idleOn,
            .rotateTo(x: 0, y: CGFloat(homeYaw), z: 0, duration: 0.4, usesShortestUnitArc: true),
            resume,
        ]), forKey: "meeting.return")
    }

    // MARK: Celebration

    /// Something SHIPPED — dance if the rig has the clip, joyful spin if not.
    func celebrate() {
        guard !isConversing else { return }
        if usesCharacterAsset, HQAssetLibrary.hasAnimation(matching: "Dance", under: body) {
            HQAssetLibrary.playAnimation(matching: "Dance", under: body)
            body.runAction(.sequence([
                .wait(duration: 2.8),
                .run { n in HQAssetLibrary.playAnimation(matching: "Idle", under: n) },
            ]), forKey: "celebrate")
        } else {
            let hop = SCNAction.sequence([
                .moveBy(x: 0, y: 0.25, z: 0, duration: 0.18),
                .moveBy(x: 0, y: -0.25, z: 0, duration: 0.22),
            ])
            body.runAction(.sequence([hop, .rotateBy(x: 0, y: .pi * 2, z: 0, duration: 0.9), hop]),
                           forKey: "celebrate")
        }
    }

    private static func yaw(from: SCNVector3, toward: SCNVector3) -> Float {
        atan2(-(toward.x - from.x), -(toward.z - from.z))
    }

    private static func travelTime(from: SCNVector3, to: SCNVector3) -> TimeInterval {
        let dx = to.x - from.x, dz = to.z - from.z
        let distance = Double((dx * dx + dz * dz).squareRoot())
        return min(max(distance / 1.8, 0.8), 4.5)   // walk pace, clamped sane
    }

    // MARK: Ambient life

    /// Every so often, walk a short loop toward the dais and back: turn, play
    /// the walking clip, glide, turn home, idle again. Closures capture nothing
    /// beyond their node parameter (strict-concurrency safe).
    private func startStrolling() {
        let home = homeAnchor
        let homeYaw = self.homeYaw
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
