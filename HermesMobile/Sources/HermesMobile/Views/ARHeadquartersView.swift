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
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @Environment(\.dismiss) private var dismiss
    @State private var placed = false
    @State private var selectedAgent: OrgAgent?
    private let statusTicker = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if ARWorldTrackingConfiguration.isSupported {
                ARHeadquartersContainer(agents: org.leadership, status: company.snapshot, placed: $placed) { agentID in
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
        .task { await company.refresh(relay: runtime.relayConfiguration) }
        .onReceive(statusTicker) { _ in
            Task { await company.refresh(relay: runtime.relayConfiguration) }
        }
    }
}

// MARK: - ARKit container

private struct ARHeadquartersContainer: UIViewRepresentable {
    let agents: [OrgAgent]
    let status: CompanySnapshot
    @Binding var placed: Bool
    var onSelectAgent: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(agents: agents, status: status, onSelectAgent: onSelectAgent) { placed = $0 }
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

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.updateStatus(status)
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let agents: [OrgAgent]
        private var status: CompanySnapshot
        private let onSelectAgent: (String) -> Void
        private let onPlaced: (Bool) -> Void
        private weak var view: ARSCNView?
        private var companyRoot: SCNNode?

        init(agents: [OrgAgent], status: CompanySnapshot,
             onSelectAgent: @escaping (String) -> Void, onPlaced: @escaping (Bool) -> Void) {
            self.agents = agents
            self.status = status
            self.onSelectAgent = onSelectAgent
            self.onPlaced = onPlaced
        }

        // MARK: Live status board (floats above the HQ, always faces you)

        /// Refresh the board whenever the company snapshot changes.
        func updateStatus(_ snapshot: CompanySnapshot) {
            status = snapshot
            guard let board = companyRoot?.childNode(withName: "status-board", recursively: true),
                  let material = board.geometry?.firstMaterial else { return }
            let image = Self.statusBoardImage(snapshot)
            material.diffuse.contents = image
            material.emission.contents = image
        }

        private func makeStatusBoard() -> SCNNode {
            let plane = SCNPlane(width: 5.4, height: 2.7)
            plane.cornerRadius = 0.18
            let material = SCNMaterial()
            let image = Self.statusBoardImage(status)
            material.diffuse.contents = image
            material.emission.contents = image          // self-lit so it reads in any AR lighting
            material.isDoubleSided = true
            material.lightingModel = .constant
            plane.firstMaterial = material
            let node = SCNNode(geometry: plane)
            node.name = "status-board"
            node.position = SCNVector3(0, 3.6, -1.0)
            node.constraints = [SCNBillboardConstraint()]  // always faces the viewer
            return node
        }

        private static func statusBoardImage(_ s: CompanySnapshot) -> UIImage {
            let size = CGSize(width: 520, height: 260)
            let accent = s.pendingGates > 0
                ? UIColor(red: 0.78, green: 0.64, blue: 0.35, alpha: 1)
                : UIColor(red: 0.11, green: 0.48, blue: 0.33, alpha: 1)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let cg = ctx.cgContext
                let bg = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 26)
                UIColor(red: 0.05, green: 0.08, blue: 0.13, alpha: 0.96).setFill()
                bg.fill()

                ("BOARDROOM" as NSString).draw(at: CGPoint(x: 26, y: 20), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 20, weight: .black),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.65), .kern: 3])
                (s.enabled ? accent : UIColor.gray).setFill()
                cg.fillEllipse(in: CGRect(x: 474, y: 24, width: 18, height: 18))

                (s.statusLine as NSString).draw(at: CGPoint(x: 26, y: 58), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: accent])
                (s.headline as NSString).draw(in: CGRect(x: 26, y: 104, width: 468, height: 66), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 25, weight: .semibold), .foregroundColor: UIColor.white])
                (s.detail as NSString).draw(at: CGPoint(x: 26, y: 174), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 19), .foregroundColor: UIColor.white.withAlphaComponent(0.6)])
                let stats = "To Do \(s.tasksTodo)   ·   Building \(s.tasksDoing)   ·   Done \(s.tasksDone)"
                    + (s.pendingGates > 0 ? "   ·   \(s.pendingGates) waiting" : "")
                (stats as NSString).draw(at: CGPoint(x: 26, y: 214), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.85)])
            }
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

            // Live company status, floating above the HQ.
            root.addChildNode(makeStatusBoard())

            return root
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
