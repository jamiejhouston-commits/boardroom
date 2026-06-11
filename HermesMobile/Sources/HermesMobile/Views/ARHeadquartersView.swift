import ARKit
import SceneKit
import SwiftUI

/// AR Headquarters — the whole company placed in the real world.
/// Point at a surface, tap to place the floor of office pods at tabletop
/// scale, walk around it, pinch to resize, rotate with two fingers.
/// Tap a robot → it waves and its chat opens. Chat commands ("walk around
/// the office") animate the AR robots too.
struct ARHeadquartersView: View {
    @EnvironmentObject private var org: OrgStore
    @Environment(\.dismiss) private var dismiss
    @State private var placed = false
    @State private var selectedAgent: OrgAgent?

    var body: some View {
        ZStack {
            if ARWorldTrackingConfiguration.isSupported {
                ARHeadquartersContainer(agents: org.leadership, placed: $placed) { agentID in
                    selectedAgent = org.agent(id: agentID)
                }
                .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "arkit")
                        .font(.largeTitle)
                        .foregroundStyle(HermesTheme.emerald)
                    Text("AR isn't supported on this device.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    Spacer()
                    if placed {
                        HStack(spacing: 6) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("HQ DEPLOYED")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: Capsule())
                    }
                }
                .padding()

                Spacer()

                if !placed {
                    Text("Move your iPhone to find a surface,\nthen tap to place your headquarters")
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.bottom, 40)
                } else {
                    Text("Pinch to resize · two fingers to rotate · tap a robot to talk")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, 30)
                }
            }
        }
        .sheet(item: $selectedAgent) { agent in
            NavigationStack { AgentChatView(agent: agent) }
        }
        .statusBarHidden()
    }
}

// MARK: - ARKit container

private struct ARHeadquartersContainer: UIViewRepresentable {
    let agents: [OrgAgent]
    @Binding var placed: Bool
    var onSelectAgent: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(agents: agents, onSelectAgent: onSelectAgent) { placed = $0 }
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.automaticallyUpdatesLighting = true
        view.autoenablesDefaultLighting = true
        view.scene = SCNScene()

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        view.session.run(config)

        // Coaching overlay guides the user to find a plane.
        let coaching = ARCoachingOverlayView()
        coaching.session = view.session
        coaching.goal = .horizontalPlane
        coaching.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.topAnchor.constraint(equalTo: view.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let agents: [OrgAgent]
        private let onSelectAgent: (String) -> Void
        private let onPlaced: (Bool) -> Void
        private weak var view: ARSCNView?
        private var companyRoot: SCNNode?

        init(agents: [OrgAgent], onSelectAgent: @escaping (String) -> Void, onPlaced: @escaping (Bool) -> Void) {
            self.agents = agents
            self.onSelectAgent = onSelectAgent
            self.onPlaced = onPlaced
        }

        func attach(to view: ARSCNView) {
            self.view = view
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
            view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
            view.addGestureRecognizer(UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:))))
            NotificationCenter.default.addObserver(self, selector: #selector(robotCommand(_:)),
                                                   name: .hermesRobotCommand, object: nil)
        }

        // MARK: Placement + interaction

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let location = gesture.location(in: view)

            if companyRoot == nil {
                // First tap: place the HQ on the detected surface.
                guard let query = view.raycastQuery(from: location, allowing: .estimatedPlane, alignment: .horizontal),
                      let hit = view.session.raycast(query).first else { return }
                let root = buildCompany()
                root.simdTransform = hit.worldTransform
                root.scale = SCNVector3(0.045, 0.045, 0.045)   // tabletop scale
                view.scene.rootNode.addChildNode(root)
                companyRoot = root
                onPlaced(true)
            } else {
                // Tap a robot/pod → wave + open its chat.
                let hits = view.hitTest(location, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
                for hit in hits {
                    var node: SCNNode? = hit.node
                    while let current = node {
                        if let name = current.name, name.hasPrefix("pod-") {
                            let agentID = String(name.dropFirst(4))
                            RobotCommand.send(.wave, to: agentID)
                            onSelectAgent(agentID)
                            return
                        }
                        node = current.parent
                    }
                }
            }
        }

        @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
            guard let root = companyRoot, gesture.state == .changed else { return }
            let s = max(0.012, min(0.2, CGFloat(root.scale.x) * gesture.scale))
            root.scale = SCNVector3(Float(s), Float(s), Float(s))
            gesture.scale = 1
        }

        @objc private func rotated(_ gesture: UIRotationGestureRecognizer) {
            guard let root = companyRoot, gesture.state == .changed else { return }
            root.eulerAngles.y -= Float(gesture.rotation)
            gesture.rotation = 0
        }

        /// Chat orders ("walk around the office") reach the AR robots too.
        @objc private func robotCommand(_ note: Notification) {
            guard let id = note.userInfo?["agentID"] as? String,
                  let raw = note.userInfo?["command"] as? String,
                  let command = RobotCommand(rawValue: raw),
                  let pod = companyRoot?.childNode(withName: "pod-\(id)", recursively: true),
                  let robot = pod.childNode(withName: "robotRoot", recursively: true)
            else { return }
            AgentRobot.perform(command, on: robot, home: robot.position)
        }

        // MARK: Build the HQ — a street of office pods

        private func buildCompany() -> SCNNode {
            let root = SCNNode()
            root.name = "hermes-hq"
            let columns = 2
            let spacing: Float = 3.1

            for (i, agent) in agents.enumerated() {
                let pod = CompanyPod.node(for: agent)
                let col = i % columns
                let row = i / columns
                pod.position = SCNVector3(Float(col) * spacing - spacing / 2,
                                          0,
                                          -Float(row) * spacing)
                // Face the two columns slightly toward each other — a street.
                pod.eulerAngles.y = col == 0 ? 0.35 : -0.35
                root.addChildNode(pod)
            }

            // A soft base plate grounds the whole HQ on the surface.
            let rows = ceil(Float(agents.count) / Float(columns))
            let plate = SCNNode(geometry: SCNBox(width: CGFloat(spacing) * 2.3,
                                                 height: 0.04,
                                                 length: CGFloat(spacing * rows + 1.6),
                                                 chamferRadius: 0.1))
            plate.position = SCNVector3(0, -0.04, -spacing * (rows - 1) / 2)
            let pm = SCNMaterial()
            pm.diffuse.contents = UIColor(red: 0.03, green: 0.045, blue: 0.07, alpha: 1)
            pm.metalness.contents = 0.6
            pm.roughness.contents = 0.35
            pm.lightingModel = .physicallyBased
            plate.geometry?.firstMaterial = pm
            root.addChildNode(plate)

            return root
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
