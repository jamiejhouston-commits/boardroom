import SceneKit
import UIKit

/// The HQ camera modes.
enum HQCameraMode: Equatable {
    case overview                 // elevated wide framing of the whole floor
    case orbit                    // slow continuous cinematic sweep
    case inspect(agentID: String) // glide to one agent's workstation
    case roam                     // first-person walkthrough (joystick + pan)
}

/// Owns the camera rig and animates smoothly between modes. Orbit rotates a
/// pivot at floor-center; overview/inspect set the camera pose in world space.
final class HQCameraController {

    /// Pivot at floor center; rotating it orbits the camera.
    let pivot = SCNNode()
    /// The actual camera node — set as the `SCNView.pointOfView`.
    let cameraNode = SCNNode()

    init() {
        let camera = SCNCamera()
        camera.fieldOfView = 58
        camera.zFar = 220
        // The proven cinematic pipeline from the look-dev rig: HDR + gentle
        // bloom, fixed exposure. Threshold 0.85 — lower blooms the characters'
        // bright bodies into blobs.
        camera.wantsHDR = true
        camera.bloomIntensity = 0.5
        camera.bloomThreshold = 0.85
        camera.bloomBlurRadius = 16
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = 0.05
        cameraNode.camera = camera
        pivot.addChildNode(cameraNode)
        setOverviewPose()
    }

    func attach(to scene: SCNScene) {
        scene.rootNode.addChildNode(pivot)
    }

    func apply(_ mode: HQCameraMode, agentNodes: [String: HQAgentNode]) {
        pivot.removeAction(forKey: "orbit")

        switch mode {
        case .overview:
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.8
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pivot.eulerAngles = SCNVector3Zero
            setOverviewPose()
            SCNTransaction.commit()

        case .orbit:
            pivot.eulerAngles = SCNVector3Zero
            setOverviewPose()
            pivot.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 44)),
                            forKey: "orbit")

        case .inspect(let agentID):
            guard let target = agentNodes[agentID] else { return }
            pivot.eulerAngles = SCNVector3Zero
            let p = target.worldPosition
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.8
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cameraNode.worldPosition = SCNVector3(p.x, p.y + 1.9, p.z + 4.4)
            cameraNode.look(at: SCNVector3(p.x, p.y + 1.2, p.z))
            SCNTransaction.commit()

        case .roam:
            // Pose is driven per-frame by the roam loop; `enterRoam` glides in.
            pivot.eulerAngles = SCNVector3Zero
        }
    }

    /// Glide into the walkthrough at `state`, then hand control to the render loop.
    func enterRoam(_ state: HQRoamState) {
        pivot.removeAction(forKey: "orbit")
        pivot.eulerAngles = SCNVector3Zero
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.7
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        applyRoamPose(state)
        SCNTransaction.commit()
    }

    /// Per-frame walkthrough pose — called from the SceneKit render loop, so it
    /// must stay allocation-free and immediate (no transactions).
    func applyRoamPose(_ state: HQRoamState) {
        cameraNode.position = SCNVector3(state.position.x, state.position.y, state.position.z)
        cameraNode.eulerAngles = SCNVector3(state.pitch, state.yaw, 0)
    }

    private func setOverviewPose() {
        // The v13 look-dev framing: elevated god-view, pods + exec + lounge all read.
        cameraNode.position = SCNVector3(0, 15, 20)
        cameraNode.look(at: SCNVector3(0, 0.2, -2))
    }
}
