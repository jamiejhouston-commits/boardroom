import SwiftUI
import SceneKit
import UIKit

/// Camera modes for the Games Production Room.
enum GamesCameraMode: Equatable { case overview, orbit, roam }

/// SceneKit host for the Games Production Room: builds the environment + robot
/// testers once, pushes live studio state onto the room's surfaces every update,
/// drives the camera (including the per-frame roam walkthrough), and turns taps
/// into fixture openings (cabinet → play, Fun Gate → reasons, boards → sheets).
/// Mirrors `HQSceneView`'s `UIViewRepresentable` + `Coordinator` shape.
struct GamesRoomSceneView: UIViewRepresentable {
    var game: StudioGame?
    var bestScore: Int = 0
    var cameraMode: GamesCameraMode
    let roamControl: RoamController
    var onTap: (GamesRoomBuilder.Tap) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(roamControl: roamControl, onTap: onTap)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.04, green: 0.055, blue: 0.082, alpha: 1)
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = false
        view.preferredFramesPerSecond = 60
        view.isPlaying = true

        let scene = SCNScene()
        GamesRoomBuilder.buildEnvironment(into: scene)

        let camera = GamesRoomCamera()
        camera.attach(to: scene)
        view.pointOfView = camera.cameraNode
        context.coordinator.camera = camera

        // Robot playtesters, clustered in front of the couch facing the screen.
        let accents: [UIColor] = [
            UIColor(red: 0.24, green: 0.44, blue: 0.63, alpha: 1),
            GamesRoomBuilder.emerald,
            UIColor(red: 0.6, green: 0.45, blue: 0.75, alpha: 1),
        ]
        var testers: [GamesRoomTesterNode] = []
        for (i, spot) in GamesRoomBuilder.testerSpots.enumerated() {
            let tester = GamesRoomTesterNode(accent: accents[i % accents.count], facing: 0)
            tester.position = spot
            scene.rootNode.addChildNode(tester)
            testers.append(tester)
        }
        context.coordinator.testers = testers

        view.scene = scene
        view.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        context.coordinator.scnView = view

        camera.apply(cameraMode)
        context.coordinator.lastMode = cameraMode
        context.coordinator.refresh(game: game, bestScore: bestScore)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.lastMode != cameraMode {
            if cameraMode == .roam {
                roamControl.activate()
                coordinator.camera?.enterRoam(roamControl.step(now: CACurrentMediaTime()))
            } else {
                roamControl.deactivate()
                coordinator.camera?.apply(cameraMode)
            }
            coordinator.lastMode = cameraMode
        }
        coordinator.refresh(game: game, bestScore: bestScore)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
        var camera: GamesRoomCamera?
        weak var scnView: SCNView?
        var lastMode: GamesCameraMode = .overview
        var testers: [GamesRoomTesterNode] = []

        private let roamControl: RoamController
        private let onTap: (GamesRoomBuilder.Tap) -> Void
        private var signature = ""

        init(roamControl: RoamController, onTap: @escaping (GamesRoomBuilder.Tap) -> Void) {
            self.roamControl = roamControl
            self.onTap = onTap
        }

        // Roam render loop (render thread — keep it lean).
        nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let state = roamControl.step(now: time) else { return }
            camera?.applyRoamPose(state)
        }

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
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
            ])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let tap = GamesRoomBuilder.tap(forNodeName: current.name) {
                        onTap(tap)
                        return
                    }
                    node = current.parent
                }
            }
        }

        @MainActor
        func refresh(game: StudioGame?, bestScore: Int = 0) {
            let newSig = Self.signatureString(game) + "|best:\(bestScore)"
            guard newSig != signature else { return }
            let hadDecision = signature.contains("APPROVED")
            signature = newSig
            guard let root = scnView?.scene?.rootNode else { return }
            GamesRoomBoards.update(root: root, game: game, bestScore: bestScore)

            // Playtest choreography: when a build lands as fun, the couch reacts.
            if let game, game.funGate.isApproved, !hadDecision {
                for (i, tester) in testers.enumerated() {
                    tester.runAction(.sequence([
                        .wait(duration: Double(i) * 0.18),
                        .run { ($0 as? GamesRoomTesterNode)?.react(delighted: true) },
                    ]))
                }
            }
        }

        private static func signatureString(_ game: StudioGame?) -> String {
            guard let game else { return "none" }
            let dist = game.distributionChannels.map(\.status).joined(separator: ",")
            return "\(game.id)|\(game.stage)|\(game.funGate.verdict)|\(dist)|\(game.pillars.count)"
        }
    }
}

// MARK: - Camera rig

/// Owns the Games Room camera and animates between modes. Overview/roam set the
/// camera pose in world space; orbit rotates a floor-center pivot.
final class GamesRoomCamera {
    let pivot = SCNNode()
    let cameraNode = SCNNode()

    init() {
        let camera = SCNCamera()
        camera.fieldOfView = 60
        camera.zFar = 200
        // The proven cinematic pipeline: HDR + gentle bloom, threshold 0.85 so
        // bright surfaces don't blow out (same values as the HQ rig).
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

    func attach(to scene: SCNScene) { scene.rootNode.addChildNode(pivot) }

    func apply(_ mode: GamesCameraMode) {
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
            pivot.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 40)),
                            forKey: "orbit")
        case .roam:
            pivot.eulerAngles = SCNVector3Zero
        }
    }

    func enterRoam(_ state: RoamState?) {
        pivot.removeAction(forKey: "orbit")
        pivot.eulerAngles = SCNVector3Zero
        guard let state else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.7
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        applyRoamPose(state)
        SCNTransaction.commit()
    }

    func applyRoamPose(_ state: RoamState) {
        cameraNode.position = SCNVector3(state.position.x, state.position.y, state.position.z)
        cameraNode.eulerAngles = SCNVector3(state.pitch, state.yaw, 0)
    }

    private func setOverviewPose() {
        // Elevated framing: cabinet, couch, mega screen, and Fun Gate all read.
        cameraNode.position = SCNVector3(0, 8.5, 12.5)
        cameraNode.look(at: SCNVector3(0, 1.4, -3.5))
    }
}
