import SwiftUI
import SceneKit
import UIKit

/// SceneKit host for the headquarters: builds the environment + agents once,
/// pushes live status every update, drives camera modes, and turns taps into
/// agent selections. Mirrors the `UIViewRepresentable` + `Coordinator` pattern
/// used by `AgentRoomSceneView`.
struct HQSceneView: UIViewRepresentable {
    var agents: [OrgAgent]
    var companyState: CompanyState
    var cameraMode: HQCameraMode
    var onSelectAgent: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelectAgent: onSelectAgent) }

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

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.scnView = view

        camera.apply(cameraMode, agentNodes: nodes)
        context.coordinator.lastMode = cameraMode
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Live status — recolor rings, no scene rebuild.
        for placement in HQLayout.placements(for: agents) {
            let status = AgentStatusResolver.status(for: placement.agent, in: companyState)
            context.coordinator.agentNodes[placement.agent.id]?.applyStatus(status)
        }
        // Camera — only re-apply when the mode actually changed.
        if context.coordinator.lastMode != cameraMode {
            context.coordinator.camera?.apply(cameraMode, agentNodes: context.coordinator.agentNodes)
            context.coordinator.lastMode = cameraMode
        }
    }

    final class Coordinator: NSObject {
        var agentNodes: [String: HQAgentNode] = [:]
        var camera: HQCameraController?
        weak var scnView: SCNView?
        var lastMode: HQCameraMode = .overview
        private let onSelectAgent: (String) -> Void

        init(onSelectAgent: @escaping (String) -> Void) {
            self.onSelectAgent = onSelectAgent
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
                    node = current.parent
                }
            }
        }
    }
}
