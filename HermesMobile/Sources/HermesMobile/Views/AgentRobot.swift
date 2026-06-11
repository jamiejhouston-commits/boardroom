import SceneKit
import UIKit

extension Notification.Name {
    /// Posted when the user gives a robot an order in chat
    /// (userInfo: "agentID" → String, "command" → RobotCommand.RawValue).
    static let hermesRobotCommand = Notification.Name("hermesRobotCommand")
}

/// Orders a robot understands from natural chat text.
enum RobotCommand: String {
    case walk, dance, wave, home

    /// Loose natural-language matching: "get up and walk around the office",
    /// "dance for me", "wave", "go sit back down"…
    static func parse(_ text: String) -> RobotCommand? {
        let t = text.lowercased()
        if ["walk", "stroll", "patrol", "wander", "get up", "stretch your legs"].contains(where: t.contains) { return .walk }
        if ["dance", "spin", "celebrate", "party"].contains(where: t.contains) { return .dance }
        if ["wave", "say hi", "say hello"].contains(where: t.contains) { return .wave }
        if ["sit down", "sit back", "back to work", "back to your desk", "go home"].contains(where: t.contains) { return .home }
        return nil
    }

    /// Tell every visible room hosting this agent's robot to act.
    static func send(_ command: RobotCommand, to agentID: String) {
        NotificationCenter.default.post(name: .hermesRobotCommand, object: nil,
                                        userInfo: ["agentID": agentID, "command": command.rawValue])
    }
}

/// The Hermes agent robot — a real 3D character built in SceneKit, shared by
/// every scene that shows an agent (War Room rooms, Company Floor pods).
///
/// Design language: a friendly unit with a glossy rounded dome head, a dark
/// glass visor with softly glowing eyes, headset earcups, a white chest plate
/// on a muted accent body, and small articulated arms. Each agent gets a
/// personality topper (antenna / stubs / fin / halo) seeded from its name,
/// plus idle life: a gentle bob, slow head sway, eye blinks, and typing hands.
enum AgentRobot {

    /// Build the robot. `color` should already be the muted accent.
    /// Local space: base at y=0, faces +z, stands ~1.3 tall.
    /// Structure: outer `robotRoot` (moved by commands) → `body` (idle bob).
    static func node(for agent: OrgAgent, color: UIColor) -> SCNNode {
        let seed = agent.name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let outer = SCNNode()
        outer.name = "robotRoot"
        let root = SCNNode()
        outer.addChildNode(root)

        // Reference look: glossy WHITE robot; the agent's accent appears only
        // as trim — collar, LEDs, chest emblem, topper. The CEO wears the
        // executive package: gold crown, emerald vest + tie, gold details.
        let isCEO = agent.tier == .ceo
        let bodyMat = pbr(diffuse: UIColor(white: 0.93, alpha: 1), metalness: 0.08, roughness: 0.22)
        let darkMat = pbr(diffuse: UIColor(white: 0.10, alpha: 1), metalness: 0.6, roughness: 0.3)
        let accentMat = pbr(diffuse: color, metalness: 0.2, roughness: 0.35)
        let goldMat = pbr(diffuse: UIColor(red: 0.82, green: 0.67, blue: 0.34, alpha: 1), metalness: 0.9, roughness: 0.25)
        let vestMat = pbr(diffuse: UIColor(red: 0.10, green: 0.42, blue: 0.30, alpha: 1), metalness: 0.15, roughness: 0.4)

        // ── Torso ─────────────────────────────────────────────────────────
        let torso = SCNNode(geometry: SCNSphere(radius: 0.34))
        torso.geometry?.firstMaterial = bodyMat
        torso.scale = SCNVector3(1.0, 0.82, 0.84)
        torso.position = SCNVector3(0, 0.34, 0)
        root.addChildNode(torso)

        if isCEO {
            // Emerald vest panel.
            let vest = SCNNode(geometry: SCNSphere(radius: 0.26))
            vest.geometry?.firstMaterial = vestMat
            vest.scale = SCNVector3(0.85, 0.85, 0.4)
            vest.position = SCNVector3(0, 0.33, 0.17)
            root.addChildNode(vest)

            // Tie.
            let tie = SCNNode(geometry: SCNBox(width: 0.055, height: 0.2, length: 0.02, chamferRadius: 0.01))
            tie.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.07, green: 0.3, blue: 0.22, alpha: 1), metalness: 0.2, roughness: 0.35)
            tie.position = SCNVector3(0, 0.40, 0.295)
            tie.eulerAngles.x = -0.12
            root.addChildNode(tie)

            // Gold buttons down the vest.
            for (i, y) in [Float(0.45), 0.37, 0.29].enumerated() {
                let button = SCNNode(geometry: SCNSphere(radius: 0.014))
                button.geometry?.firstMaterial = goldMat
                button.position = SCNVector3(0.07, y, 0.27 - Float(i) * 0.01)
                root.addChildNode(button)
            }
        } else {
            // Accent chest emblem.
            let emblem = SCNNode(geometry: SCNCylinder(radius: 0.055, height: 0.02))
            emblem.geometry?.firstMaterial = accentMat
            emblem.eulerAngles.x = .pi / 2
            emblem.position = SCNVector3(0, 0.40, 0.295)
            root.addChildNode(emblem)
        }

        // Collar where head meets torso — gold for the CEO, accent for the rest.
        let collar = SCNNode(geometry: SCNTorus(ringRadius: 0.155, pipeRadius: 0.035))
        collar.geometry?.firstMaterial = isCEO ? goldMat : accentMat
        collar.position = SCNVector3(0, 0.60, 0)
        root.addChildNode(collar)

        // Dark waist ring grounding the torso.
        let waist = SCNNode(geometry: SCNCylinder(radius: 0.27, height: 0.06))
        waist.geometry?.firstMaterial = darkMat
        waist.position = SCNVector3(0, 0.09, 0)
        root.addChildNode(waist)

        // ── Head group (sways as one) ─────────────────────────────────────
        let head = SCNNode()
        head.position = SCNVector3(0, 0.96, 0)
        root.addChildNode(head)

        let neck = SCNNode(geometry: SCNCylinder(radius: 0.09, height: 0.14))
        neck.geometry?.firstMaterial = darkMat
        neck.position = SCNVector3(0, -0.32, 0)
        head.addChildNode(neck)

        let dome = SCNNode(geometry: SCNSphere(radius: 0.40))
        dome.geometry?.firstMaterial = bodyMat
        dome.scale = SCNVector3(1.0, 0.88, 0.94)
        head.addChildNode(dome)

        // Dark glass visor set into the front of the dome. Constant-lit
        // near-black so it stays DARK from every angle and scale — the
        // face must read even on the small Company Floor pods.
        let visor = SCNNode(geometry: SCNSphere(radius: 0.33))
        let visorDark = SCNMaterial()
        visorDark.diffuse.contents = UIColor(red: 0.02, green: 0.03, blue: 0.045, alpha: 1)
        visorDark.lightingModel = .constant
        visor.geometry?.firstMaterial = visorDark
        visor.scale = SCNVector3(0.94, 0.64, 0.54)
        visor.position = SCNVector3(0, 0.01, 0.16)
        head.addChildNode(visor)

        // Glowing eyes — big, bright, friendly. Sized to survive tiny pods.
        let eyeColor = UIColor(red: 0.55, green: 0.95, blue: 1.0, alpha: 1)
        var eyes: [SCNNode] = []
        for dx in [Float(-0.125), 0.125] {
            let eye = SCNNode(geometry: SCNSphere(radius: 0.095))
            eye.geometry?.firstMaterial = glow(eyeColor)
            eye.scale = SCNVector3(1.0, 1.4, 0.45)
            eye.position = SCNVector3(dx, 0.02, 0.355)
            head.addChildNode(eye)
            eyes.append(eye)
        }

        // Headset: earcups + band over the top.
        for dx in [Float(-0.41), 0.41] {
            let cup = SCNNode(geometry: SCNCylinder(radius: 0.13, height: 0.07))
            cup.geometry?.firstMaterial = darkMat
            cup.eulerAngles.z = .pi / 2
            cup.position = SCNVector3(dx, 0, 0)
            head.addChildNode(cup)

            let led = SCNNode(geometry: SCNSphere(radius: 0.022))
            led.geometry?.firstMaterial = glow(color.withAlphaComponent(0.8))
            led.position = SCNVector3(dx + (dx > 0 ? 0.045 : -0.045), 0, 0)
            head.addChildNode(led)
        }
        let band = SCNNode(geometry: SCNTorus(ringRadius: 0.41, pipeRadius: 0.032))
        band.geometry?.firstMaterial = darkMat
        band.eulerAngles.x = .pi / 2          // arc ear-to-ear over the dome
        band.scale = SCNVector3(1, 1, 0.9)
        head.addChildNode(band)

        if isCEO {
            // The crown — gold band, four spikes, orb tips.
            let crown = SCNNode()
            crown.position = SCNVector3(0, 0.36, 0)
            let bandRing = SCNNode(geometry: SCNCylinder(radius: 0.15, height: 0.055))
            bandRing.geometry?.firstMaterial = goldMat
            crown.addChildNode(bandRing)
            for i in 0..<4 {
                let a = Float(i) / 4 * .pi * 2
                let spike = SCNNode(geometry: SCNCone(topRadius: 0.004, bottomRadius: 0.028, height: 0.09))
                spike.geometry?.firstMaterial = goldMat
                spike.position = SCNVector3(cos(a) * 0.105, 0.07, sin(a) * 0.105)
                crown.addChildNode(spike)
                let orb = SCNNode(geometry: SCNSphere(radius: 0.014))
                orb.geometry?.firstMaterial = goldMat
                orb.position = SCNVector3(cos(a) * 0.105, 0.125, sin(a) * 0.105)
                crown.addChildNode(orb)
            }
            head.addChildNode(crown)
        }

        // ── Arms (typing posture) ─────────────────────────────────────────
        var hands: [SCNNode] = []
        for dx in [Float(-0.38), 0.38] {
            let arm = SCNNode(geometry: SCNCapsule(capRadius: 0.065, height: 0.34))
            arm.geometry?.firstMaterial = bodyMat
            arm.position = SCNVector3(dx, 0.42, 0.10)
            arm.eulerAngles = SCNVector3(-0.55, 0, dx > 0 ? -0.55 : 0.55)
            if dx > 0 { arm.name = "armR" }
            root.addChildNode(arm)

            let hand = SCNNode(geometry: SCNSphere(radius: 0.07))
            hand.geometry?.firstMaterial = darkMat
            hand.position = SCNVector3(dx * 0.78, 0.24, 0.30)
            root.addChildNode(hand)
            hands.append(hand)
        }

        // ── Legs + boots (the reference figure stands) ────────────────────
        // Lift the whole figure to make room for legs beneath.
        let legLift: Float = 0.22
        for child in root.childNodes { child.position.y += legLift }

        for dx in [Float(-0.13), 0.13] {
            let leg = SCNNode(geometry: SCNCapsule(capRadius: 0.07, height: 0.3))
            leg.geometry?.firstMaterial = bodyMat
            leg.position = SCNVector3(dx, 0.2, 0)
            root.addChildNode(leg)

            let boot = SCNNode(geometry: SCNSphere(radius: 0.09))
            boot.geometry?.firstMaterial = bodyMat
            boot.scale = SCNVector3(1.15, 0.6, 1.5)
            boot.position = SCNVector3(dx, 0.055, 0.035)
            root.addChildNode(boot)

            if isCEO {
                // Gold soles for the boss.
                let sole = SCNNode(geometry: SCNCylinder(radius: 0.085, height: 0.018))
                sole.geometry?.firstMaterial = goldMat
                sole.scale = SCNVector3(1.1, 1, 1.5)
                sole.position = SCNVector3(dx, 0.012, 0.035)
                root.addChildNode(sole)
            }
        }

        // ── Personality topper (seeded per agent; the CEO wears a crown) ──
        if !isCEO {
            head.addChildNode(topper(seed: seed, color: color, darkMat: darkMat))
        }

        // ── Idle life ─────────────────────────────────────────────────────
        let bob = SCNAction.sequence([
            .moveBy(x: 0, y: 0.035, z: 0, duration: 1.4),
            .moveBy(x: 0, y: -0.035, z: 0, duration: 1.4)
        ])
        bob.timingMode = .easeInEaseOut
        root.runAction(.repeatForever(bob))

        let sway = SCNAction.sequence([
            .rotateBy(x: 0, y: 0.10, z: 0, duration: 1.9),
            .rotateBy(x: 0, y: -0.10, z: 0, duration: 1.9)
        ])
        sway.timingMode = .easeInEaseOut
        head.runAction(.repeatForever(sway))

        // Eye blinks — quick fade, randomized cadence per agent.
        let blinkWait = 2.4 + Double(seed % 14) / 10.0
        for eye in eyes {
            eye.runAction(.repeatForever(.sequence([
                .wait(duration: blinkWait),
                .fadeOpacity(to: 0.15, duration: 0.06),
                .fadeOpacity(to: 1.0, duration: 0.10)
            ])))
        }

        // Hands typing — alternating taps.
        for (i, hand) in hands.enumerated() {
            let tap = SCNAction.sequence([
                .wait(duration: i == 0 ? 0.0 : 0.14),
                .moveBy(x: 0, y: -0.025, z: 0, duration: 0.12),
                .moveBy(x: 0, y: 0.025, z: 0, duration: 0.12),
                .wait(duration: 0.16)
            ])
            hand.runAction(.repeatForever(tap))
        }

        return outer
    }

    // MARK: Chat-ordered actions ("get up and walk around the office")

    /// Run a command on a robot node (the `robotRoot` returned by `node(for:)`).
    /// Movement happens on the root, so the idle bob keeps running underneath —
    /// the robot glides around the room, faces where it's going, and returns.
    /// `home` is the robot's resting position (where the host scene placed it).
    static func perform(_ command: RobotCommand, on robot: SCNNode, home: SCNVector3) {
        robot.removeAction(forKey: "command")
        let s = CGFloat(max(robot.scale.x, 0.01))   // scale path to room size

        switch command {
        case .walk:
            func leg(_ dx: CGFloat, _ dz: CGFloat, _ dur: TimeInterval) -> SCNAction {
                let face = SCNAction.rotateTo(x: 0, y: atan2(dx, dz), z: 0, duration: 0.3, usesShortestUnitArc: true)
                let move = SCNAction.moveBy(x: dx * s, y: 0, z: dz * s, duration: dur)
                move.timingMode = .easeInEaseOut
                return .sequence([face, move])
            }
            let lift = SCNAction.moveBy(x: 0, y: 0.06 * s, z: 0, duration: 0.35)
            let settle = SCNAction.moveBy(x: 0, y: -0.06 * s, z: 0, duration: 0.35)
            let tour = SCNAction.sequence([
                lift,
                leg(-1.5, -0.2, 2.0),
                leg(0, -1.2, 1.6),
                leg(3.0, 0, 3.2),
                leg(0, 1.2, 1.6),
                leg(-1.5, 0.2, 2.0),
                .rotateTo(x: 0, y: 0, z: 0, duration: 0.4, usesShortestUnitArc: true),
                settle
            ])
            robot.runAction(tour, forKey: "command")

        case .dance:
            let hop = SCNAction.sequence([
                .moveBy(x: 0, y: 0.14 * s, z: 0, duration: 0.18),
                .moveBy(x: 0, y: -0.14 * s, z: 0, duration: 0.22)
            ])
            let spin = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 0.8)
            robot.runAction(.sequence([
                .group([spin, hop]), hop,
                .group([spin.reversed(), hop]),
                .rotateTo(x: 0, y: 0, z: 0, duration: 0.3, usesShortestUnitArc: true)
            ]), forKey: "command")

        case .wave:
            guard let arm = robot.childNode(withName: "armR", recursively: true) else { return }
            let raise = SCNAction.rotateTo(x: -2.4, y: 0, z: -0.5, duration: 0.3, usesShortestUnitArc: true)
            let wig = SCNAction.sequence([
                .rotateBy(x: 0, y: 0, z: 0.45, duration: 0.16),
                .rotateBy(x: 0, y: 0, z: -0.45, duration: 0.16)
            ])
            let lower = SCNAction.rotateTo(x: -0.55, y: 0, z: -0.55, duration: 0.35, usesShortestUnitArc: true)
            arm.runAction(.sequence([raise, wig, wig, wig, lower]), forKey: "command")

        case .home:
            robot.runAction(.group([
                .move(to: home, duration: 1.2),
                .rotateTo(x: 0, y: 0, z: 0, duration: 1.2, usesShortestUnitArc: true)
            ]), forKey: "command")
        }
    }

    // MARK: Toppers — small per-agent identity

    private static func topper(seed: Int, color: UIColor, darkMat: SCNMaterial) -> SCNNode {
        let node = SCNNode()
        switch seed % 4 {
        case 0: // single antenna with glowing tip
            let stem = SCNNode(geometry: SCNCylinder(radius: 0.016, height: 0.2))
            stem.geometry?.firstMaterial = darkMat
            stem.position = SCNVector3(0, 0.45, 0)
            node.addChildNode(stem)
            let tip = SCNNode(geometry: SCNSphere(radius: 0.045))
            tip.geometry?.firstMaterial = glow(color.withAlphaComponent(0.9))
            tip.position = SCNVector3(0, 0.57, 0)
            node.addChildNode(tip)
            tip.runAction(.repeatForever(.sequence([
                .fadeOpacity(to: 0.4, duration: 1.2), .fadeOpacity(to: 1.0, duration: 1.2)
            ])))
        case 1: // twin sensor stubs
            for dx in [Float(-0.15), 0.15] {
                let stub = SCNNode(geometry: SCNCapsule(capRadius: 0.035, height: 0.16))
                stub.geometry?.firstMaterial = darkMat
                stub.position = SCNVector3(dx, 0.42, 0)
                stub.eulerAngles.z = dx > 0 ? -0.25 : 0.25
                node.addChildNode(stub)
            }
        case 2: // dorsal fin
            let fin = SCNNode(geometry: SCNCone(topRadius: 0.005, bottomRadius: 0.07, height: 0.18))
            fin.geometry?.firstMaterial = pbr(diffuse: color, metalness: 0.2, roughness: 0.35)
            fin.position = SCNVector3(0, 0.44, -0.05)
            fin.scale = SCNVector3(0.5, 1, 1.4)
            node.addChildNode(fin)
        default: // floating halo ring
            let halo = SCNNode(geometry: SCNTorus(ringRadius: 0.2, pipeRadius: 0.014))
            halo.geometry?.firstMaterial = glow(color.withAlphaComponent(0.65))
            halo.position = SCNVector3(0, 0.52, 0)
            node.addChildNode(halo)
            halo.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 6)))
        }
        return node
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
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.emission.contents = color
        m.lightingModel = .constant
        return m
    }
}
