import SwiftUI
import SceneKit
import UIKit

/// SceneKit host for the headquarters: builds the environment + agents once,
/// pushes live status/boards every update, drives camera modes (including the
/// per-frame roam walkthrough), and turns taps into agent selections or board
/// openings. Mirrors the `UIViewRepresentable` + `Coordinator` pattern used by
/// `AgentRoomSceneView`.
struct HQSceneView: UIViewRepresentable {
    var agents: [OrgAgent]
    var companyState: CompanyState
    var cameraMode: HQCameraMode
    var conversingAgentID: String?
    let roamControl: HQRoamControl
    var onSelectAgent: (String) -> Void
    var onTapBoard: (HQLiveBoards.Kind) -> Void
    var onEnterGamesStudio: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(roamControl: roamControl,
                    onSelectAgent: onSelectAgent,
                    onTapBoard: onTapBoard,
                    onEnterGamesStudio: onEnterGamesStudio)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.043, green: 0.055, blue: 0.082, alpha: 1)
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = false
        view.preferredFramesPerSecond = 60
        view.isPlaying = true

        let scene = SCNScene()
        HQSceneBuilder.buildEnvironment(into: scene)

        let camera = HQCameraController()
        camera.attach(to: scene)
        view.pointOfView = camera.cameraNode
        context.coordinator.camera = camera

        var nodes: [String: HQAgentNode] = [:]
        for placement in HQLayout.placements(for: agents) {
            let node = HQAgentNode(placement: placement)
            node.applyStatus(AgentStatusResolver.status(for: placement.agent, in: companyState))
            scene.rootNode.addChildNode(node)
            nodes[placement.agent.id] = node
        }
        context.coordinator.agentNodes = nodes

        view.scene = scene
        view.delegate = context.coordinator   // roam walkthrough render loop

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1        // one finger looks; UI stays SwiftUI's
        view.addGestureRecognizer(pan)
        context.coordinator.scnView = view

        camera.apply(cameraMode, agentNodes: nodes)
        context.coordinator.lastMode = cameraMode
        context.coordinator.refreshLiveState(agents: agents, state: companyState)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let coordinator = context.coordinator

        // Live status — recolor rings, no scene rebuild.
        for placement in HQLayout.placements(for: agents) {
            let status = AgentStatusResolver.status(for: placement.agent, in: companyState)
            coordinator.agentNodes[placement.agent.id]?.applyStatus(status)
        }

        // Camera — only re-apply when the mode actually changed.
        if coordinator.lastMode != cameraMode {
            if cameraMode == .roam {
                let start = HQRoamState()
                roamControl.activate(from: start)
                coordinator.camera?.enterRoam(start)
            } else {
                roamControl.deactivate()
                coordinator.camera?.apply(cameraMode, agentNodes: coordinator.agentNodes)
            }
            coordinator.lastMode = cameraMode
        }

        // Face-to-face conversation — the tapped agent turns to the player.
        coordinator.setConversing(conversingAgentID)

        // Boards, meeting huddle, celebrations — gated on a state signature so
        // refresh ticks that change nothing cost nothing.
        coordinator.refreshLiveState(agents: agents, state: companyState)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
        var agentNodes: [String: HQAgentNode] = [:]
        var camera: HQCameraController?
        weak var scnView: SCNView?
        var lastMode: HQCameraMode = .overview

        private let roamControl: HQRoamControl
        private let onSelectAgent: (String) -> Void
        private let onTapBoard: (HQLiveBoards.Kind) -> Void
        private let onEnterGamesStudio: () -> Void
        private var boardsSignature = ""
        private var huddleIDs: Set<String> = []
        private var shippedIDs: Set<String>?
        private var conversingID: String?

        init(roamControl: HQRoamControl,
             onSelectAgent: @escaping (String) -> Void,
             onTapBoard: @escaping (HQLiveBoards.Kind) -> Void,
             onEnterGamesStudio: @escaping () -> Void) {
            self.roamControl = roamControl
            self.onSelectAgent = onSelectAgent
            self.onTapBoard = onTapBoard
            self.onEnterGamesStudio = onEnterGamesStudio
        }

        // MARK: Roam render loop (render thread — keep it lean)

        nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let state = roamControl.step(now: time) else { return }
            camera?.applyRoamPose(state)
        }

        // MARK: Gestures

        @MainActor
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard roamControl.isActive, let view = scnView else { return }
            let t = recognizer.translation(in: view)
            roamControl.addLook(SIMD2(Float(t.x), Float(t.y)))
            recognizer.setTranslation(.zero, in: view)
        }

        @MainActor
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = scnView else { return }
            let point = recognizer.location(in: view)
            let hits = view.hitTest(point, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
            ])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let agentNode = current as? HQAgentNode {
                        onSelectAgent(agentNode.agentID)
                        return
                    }
                    if current.name == HQSceneBuilder.gamesStudioPortalName {
                        onEnterGamesStudio()
                        return
                    }
                    if let kind = HQLiveBoards.kind(forNodeName: current.name) {
                        onTapBoard(kind)
                        return
                    }
                    node = current.parent
                }
            }
        }

        // MARK: Conversation choreography

        @MainActor
        func setConversing(_ id: String?) {
            guard id != conversingID else { return }
            if let previous = conversingID { agentNodes[previous]?.leaveConversation() }
            conversingID = id
            guard let id, let node = agentNodes[id] else { return }
            let cameraPosition = camera?.cameraNode.worldPosition
                ?? SCNVector3(node.worldPosition.x, 1.6, node.worldPosition.z + 4)
            node.enterConversation(facing: cameraPosition)
        }

        // MARK: Live company state → the room

        @MainActor
        func refreshLiveState(agents: [OrgAgent], state: CompanyState) {
            let live = state.meetings?.first(where: { $0.isLive })
            let shipped = Set(state.initiatives.filter { $0.stage == "shipped" }.map(\.id))
            let signature = boardsSignatureString(state: state, liveMeetingID: live?.id)

            if signature != boardsSignature {
                boardsSignature = signature
                if let root = scnView?.scene?.rootNode {
                    HQLiveBoards.update(root: root, state: state)
                    HQSceneBuilder.applyDaylight(
                        root: root, hour: Calendar.current.component(.hour, from: Date()))
                }
                applyMeeting(live, agents: agents)
            }

            // Celebrate NEW ships only (not the backlog present on entry).
            if let known = shippedIDs {
                if !shipped.subtracting(known).isEmpty { celebrateShipping() }
            }
            shippedIDs = shipped
        }

        @MainActor
        private func applyMeeting(_ meeting: CompanyMeeting?, agents: [OrgAgent]) {
            let attendeeRoles = Set(meeting?.attendees ?? [])
            let attendeeIDs = Set(agents.filter {
                guard let role = $0.companyRole else { return false }
                return attendeeRoles.contains(role)
            }.map(\.id))

            let joining = attendeeIDs.subtracting(huddleIDs)
            let leaving = huddleIDs.subtracting(attendeeIDs)
            for id in leaving { agentNodes[id]?.leaveMeeting() }
            for (index, id) in joining.sorted().enumerated() {
                guard let node = agentNodes[id], !node.isExecutive else { continue }
                // Huddle ring just inside the console circle, spread evenly.
                let angle = Float(index) * (2 * .pi / Float(max(joining.count, 3))) - .pi / 3
                let seat = SCNVector3(sin(angle) * 2.9, 0.22, cos(angle) * 2.9)
                node.joinMeeting(at: seat, facing: SCNVector3(0, 0.22, 0))
            }
            huddleIDs = attendeeIDs.intersection(Set(agentNodes.keys))
        }

        /// A ship landed while the owner watched — the floor erupts (briefly,
        /// tastefully: muted gold/emerald, two seconds, then back to work).
        @MainActor
        private func celebrateShipping() {
            for node in agentNodes.values { node.celebrate() }
            guard let root = scnView?.scene?.rootNode else { return }
            let confetti = SCNParticleSystem()
            confetti.birthRate = 500
            confetti.emissionDuration = 0.4
            confetti.loops = false
            confetti.particleLifeSpan = 2.4
            confetti.particleVelocity = 4.5
            confetti.particleVelocityVariation = 2
            confetti.emittingDirection = SCNVector3(0, 1, 0)
            confetti.spreadingAngle = 55
            confetti.particleSize = 0.045
            confetti.particleColor = HQSceneBuilder.gold
            confetti.particleColorVariation = SCNVector4(0.08, 0.25, 0.15, 0)
            confetti.acceleration = SCNVector3(0, -3.4, 0)
            let emitter = SCNNode()
            emitter.position = SCNVector3(0, 2.6, 0)
            emitter.addParticleSystem(confetti)
            root.addChildNode(emitter)
            emitter.runAction(.sequence([.wait(duration: 3.4), .removeFromParentNode()]))
        }

        private func boardsSignatureString(state: CompanyState, liveMeetingID: String?) -> String {
            let inits = state.initiatives.map { "\($0.id):\($0.stage)" }.joined(separator: ",")
            let tasks = (state.tasks ?? []).map { "\($0.id):\($0.status)" }.joined(separator: ",")
            let lastEvent = state.events?.last?.id ?? "-"
            return "\(inits)|\(tasks)|\(lastEvent)|\(liveMeetingID ?? "-")"
        }
    }
}
