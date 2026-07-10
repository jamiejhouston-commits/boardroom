import SceneKit
import SwiftUI
import UIKit

// MARK: - Company Floor: ONE living scene — every department office on a real floorplan

/// "See the whole company floor" — a single cinematic SceneKit scene laid out
/// as an actual office floor: two rows of open-front department pods flanking
/// a central walkway, the CEO suite up front. Pinch to zoom, drag to move
/// across the floor, tap a pod to glide in, tap again to open the office.
///
/// Replaces the old grid of per-pod `SCNView`s (12+ simultaneous render loops)
/// with one view on the proven cinematic pipeline: HDR + restrained bloom,
/// depth of field, vignette, IBL reflections, one shadow-casting key light —
/// the same rig as `AgentRoomBuilder` / the HQ, lit brighter for a wide floor.
struct CompanyFloorView: View {
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var company: CompanyStore
    @State private var focusedID: String?
    @State private var openAgent: OrgAgent?
    @State private var showAR = false

    private var agents: [OrgAgent] { CompanyFloorBuilder.ordered(org.leadership) }
    private var focusedAgent: OrgAgent? { agents.first { $0.id == focusedID } }

    var body: some View {
        ZStack {
            CompanyFloorSceneView(agents: agents,
                                  companyState: company.state,
                                  focusedID: $focusedID,
                                  onOpenAgent: { id in
                                      openAgent = agents.first { $0.id == id }
                                  })
                .ignoresSafeArea()

            VStack(spacing: 0) {
                statusStrip
                Spacer()
                if let agent = focusedAgent {
                    focusBar(for: agent)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .animation(.spring(duration: 0.35), value: focusedID)
        .navigationTitle("Company Floor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAR = true } label: {
                    Image(systemName: "arkit")
                }
                .accessibilityLabel("View headquarters in AR")
            }
        }
        .fullScreenCover(isPresented: $showAR) { ARHeadquartersView() }
        .navigationDestination(item: $openAgent) { agent in
            OrgAgentDetailView(agent: agent)
        }
    }

    /// Honest live rollup — real statuses from the company engine, never a
    /// hardcoded "All Online".
    private var statusStrip: some View {
        let statuses = agents.map { AgentStatusResolver.status(for: $0, in: company.state) }
        let executing = statuses.filter { $0 == .active }.count
        let waiting = statuses.filter { $0 == .waitingForUser }.count
        let blocked = statuses.filter { $0 == .blocked }.count

        var parts = ["\(agents.count) agents"]
        if executing > 0 { parts.append("\(executing) executing") }
        if waiting > 0 { parts.append("\(waiting) waiting on you") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        if parts.count == 1 { parts.append("floor quiet") }

        return HStack(spacing: 6) {
            Circle()
                .fill(executing > 0 ? HermesTheme.emerald : HermesTheme.silver)
                .frame(width: 7, height: 7)
            Text(parts.joined(separator: " · "))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Frosted info bar for the focused office (Cinema Mobile pattern —
    /// mirrors the Agent Studio bar).
    private func focusBar(for agent: OrgAgent) -> some View {
        let status = AgentStatusResolver.status(for: agent, in: company.state)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(agent.title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Color(hex: agent.accentHex))
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(Color(uiColor: status.tint)).frame(width: 6, height: 6)
                Text(status.label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            Button { openAgent = agent } label: {
                HStack(spacing: 4) {
                    Text("Open office")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(HermesTheme.gold)
            }
            Button { focusedID = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .accessibilityLabel("Back to overview")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - AR access: a pod as a free-standing node

/// Extracts a department pod (room + furniture + seated robot) as a single
/// node for AR placement. Pods are self-contained (no lights/cameras — the
/// AR session provides those), so the builder's node ships as-is.
enum CompanyPod {
    static func node(for agent: OrgAgent) -> SCNNode {
        let pod = CompanyFloorBuilder.pod(for: agent)
        // The AR street was tuned around the old 2.9 m pods; scale the new
        // 3.4 m rooms back to that footprint so the street spacing still fits.
        pod.scale = SCNVector3(0.85, 0.85, 0.85)
        return pod
    }
}

// MARK: - The one SceneKit host

private struct CompanyFloorSceneView: UIViewRepresentable {
    var agents: [OrgAgent]
    var companyState: CompanyState
    @Binding var focusedID: String?
    var onOpenAgent: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFocus: { focusedID = $0 }, onOpen: onOpenAgent)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.012, green: 0.02, blue: 0.035, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        // One ambient scene, 30 fps, render-on-change: the whole floor costs
        // less than one of the old always-rendering grid cards.
        view.preferredFramesPerSecond = 30
        view.isPlaying = true

        context.coordinator.attach(to: view, agents: agents)
        context.coordinator.applyStatuses(agents: agents, state: companyState)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Org edits (rare) rebuild the floor; everything else is in-place.
        if context.coordinator.agentIDs != agents.map(\.id) {
            context.coordinator.attach(to: uiView, agents: agents)
        }
        context.coordinator.applyStatuses(agents: agents, state: companyState)
        context.coordinator.setFocus(focusedID, animated: true)
    }

    // MARK: Coordinator — camera rig + gestures + live status

    @MainActor
    final class Coordinator: NSObject {
        private let onFocus: (String?) -> Void
        private let onOpen: (String) -> Void

        private weak var scnView: SCNView?
        private var cameraNode = SCNNode()
        private var targetNode = SCNNode()
        private var podPositions: [String: simd_float3] = [:]
        private(set) var agentIDs: [String] = []

        // Fixed diagonal view direction — every pod's open corner faces it.
        private let viewDirection = simd_normalize(simd_float3(0.55, 0.85, 0.95))
        private var distance: Float = 14
        private var overviewTarget = simd_float3(0, 0.4, 0)
        private var overviewDistance: Float = 14
        private var focusedID: String?
        private var statusSignature = ""

        init(onFocus: @escaping (String?) -> Void, onOpen: @escaping (String) -> Void) {
            self.onFocus = onFocus
            self.onOpen = onOpen
        }

        func attach(to view: SCNView, agents: [OrgAgent]) {
            scnView = view
            agentIDs = agents.map(\.id)
            statusSignature = ""
            focusedID = nil

            let scene = CompanyFloorBuilder.floorScene(for: agents)
            view.scene = scene

            podPositions = [:]
            for placement in CompanyFloorBuilder.placements(for: agents) {
                let p = placement.position
                podPositions[placement.agent.id] = simd_float3(p.x, p.y, p.z)
            }

            let rows = CompanyFloorBuilder.rowCount(for: agents.count)
            overviewTarget = simd_float3(0, 0.4, -CompanyFloorBuilder.spacing * Float(rows - 1) / 2)
            overviewDistance = min(24, 8.5 + 2.3 * Float(rows))
            distance = overviewDistance

            targetNode.simdPosition = overviewTarget
            scene.rootNode.addChildNode(targetNode)

            let camera = SCNCamera()
            camera.fieldOfView = 35
            camera.wantsHDR = true
            camera.wantsExposureAdaptation = false
            // The HQ post stack, retuned for a bright wide floor: bloom only
            // above pure white so the lifted matte surfaces (and the white
            // robots) never bloom into blobs — only the emissive strips do.
            camera.bloomIntensity = 0.5
            camera.bloomThreshold = 1.0
            camera.bloomBlurRadius = 16
            camera.exposureOffset = 0.25
            camera.wantsDepthOfField = true
            camera.fStop = 5.6
            camera.apertureBladeCount = 6
            camera.focusDistance = CGFloat(distance)
            camera.vignettingPower = 0.8
            camera.vignettingIntensity = 0.45
            camera.contrast = 1.06
            camera.saturation = 1.05
            camera.zFar = 90
            cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.simdPosition = overviewTarget + viewDirection * distance
            let look = SCNLookAtConstraint(target: targetNode)
            look.isGimbalLockEnabled = true
            cameraNode.constraints = [look]
            scene.rootNode.addChildNode(cameraNode)
            view.pointOfView = cameraNode
        }

        /// Move the rig — the look-at constraint carries the rotation.
        private func layout(animated: Bool) {
            let target = targetNode.simdPosition
            let apply = {
                self.cameraNode.simdPosition = target + self.viewDirection * self.distance
                self.cameraNode.camera?.focusDistance = CGFloat(self.distance)
            }
            if animated {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.85
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                apply()
                SCNTransaction.commit()
            } else {
                apply()
            }
        }

        func setFocus(_ id: String?, animated: Bool) {
            guard id != focusedID else { return }
            focusedID = id
            if animated {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.85
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            if let id, let pod = podPositions[id] {
                targetNode.simdPosition = simd_float3(pod.x, 0.9, pod.z)
                distance = 4.6
            } else {
                targetNode.simdPosition = overviewTarget
                distance = overviewDistance
            }
            cameraNode.simdPosition = targetNode.simdPosition + viewDirection * distance
            cameraNode.camera?.focusDistance = CGFloat(distance)
            if animated { SCNTransaction.commit() }
        }

        // MARK: Live status → the floor

        func applyStatuses(agents: [OrgAgent], state: CompanyState) {
            let statuses = agents.map { ($0.id, AgentStatusResolver.status(for: $0, in: state)) }
            let signature = statuses.map { "\($0.0):\($0.1.label)" }.joined(separator: ",")
            guard signature != statusSignature, let root = scnView?.scene?.rootNode else { return }
            statusSignature = signature
            for (id, status) in statuses {
                guard let pod = root.childNode(withName: "pod-\(id)", recursively: false),
                      let ring = pod.childNode(withName: "status-ring", recursively: true)
                else { continue }
                CompanyFloorBuilder.applyStatus(status, to: ring)
            }
        }

        // MARK: Gestures

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = scnView else { return }
            let point = recognizer.location(in: view)
            let hits = view.hitTest(point, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
            ])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name, name.hasPrefix("pod-") {
                        let id = String(name.dropFirst(4))
                        if id == focusedID {
                            onOpen(id)
                        } else {
                            onFocus(id)
                        }
                        return
                    }
                    node = current.parent
                }
            }
            onFocus(nil)   // tapped open floor → back to overview
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = scnView else { return }
            if recognizer.state == .began, focusedID != nil {
                // A drag leaves the focused office but keeps the camera put:
                // clearing our own state first turns the SwiftUI setFocus(nil)
                // echo into a no-op, so no fly-back animation fights the drag.
                focusedID = nil
                onFocus(nil)
            }
            let t = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)

            // Grab-the-floor mapping (the Maps convention): the world follows
            // the finger, so the target moves opposite the drag along the
            // screen axes projected onto the floor. right = up × forward.
            let forward = simd_normalize(simd_float3(-viewDirection.x, 0, -viewDirection.z))
            let right = simd_float3(-forward.z, 0, forward.x)
            let scale = 0.0016 * distance
            var target = targetNode.simdPosition
            target -= right * Float(t.x) * scale
            target += forward * Float(t.y) * scale

            let rows = CompanyFloorBuilder.rowCount(for: agentIDs.count)
            target.x = min(max(target.x, -4.5), 4.5)
            target.z = min(max(target.z, -CompanyFloorBuilder.spacing * Float(rows - 1) - 2), 2.5)
            targetNode.simdPosition = target
            layout(animated: false)
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .changed else { return }
            distance = min(max(distance / Float(recognizer.scale), 3.5), 24)
            recognizer.scale = 1
            layout(animated: false)
        }
    }
}

// MARK: - Floor + pod builder (the cinematic pipeline)

/// Builds the floor scene and its department pods with the app's proven
/// look-dev rules: PBR + IBL, one shadow-casting warm key, muted accents,
/// ONE restrained emission strip per pod — never neon.
enum CompanyFloorBuilder {

    static let spacing: Float = 4.3
    private static let podSize: CGFloat = 3.4        // room footprint
    private static let wallHeight: CGFloat = 2.4
    private static let columnX: Float = 2.6          // pod centers flank the walkway

    // MARK: Layout

    /// CEO first — the suite anchors the front of the floor.
    static func ordered(_ agents: [OrgAgent]) -> [OrgAgent] {
        agents.sorted { a, b in
            if (a.tier == .ceo) != (b.tier == .ceo) { return a.tier == .ceo }
            return a.name < b.name
        }
    }

    static func rowCount(for count: Int) -> Int { max(1, (count + 1) / 2) }

    static func placements(for agents: [OrgAgent]) -> [(agent: OrgAgent, position: SCNVector3)] {
        agents.enumerated().map { i, agent in
            let col = i % 2
            let row = i / 2
            let x = col == 0 ? -columnX : columnX
            return (agent, SCNVector3(x, 0, -Float(row) * spacing))
        }
    }

    // MARK: The whole floor

    static func floorScene(for agents: [OrgAgent]) -> SCNScene {
        let scene = SCNScene()
        let rows = rowCount(for: agents.count)
        let depth = spacing * Float(rows - 1)

        // Environment: IBL for PBR reflections + fog to fade the far end.
        scene.lightingEnvironment.contents = environmentMap()
        scene.lightingEnvironment.intensity = 0.35   // reflections only (bench-proven)
        scene.background.contents = UIColor(red: 0.012, green: 0.02, blue: 0.035, alpha: 1)
        scene.fogStartDistance = 18
        scene.fogEndDistance = 44
        scene.fogColor = UIColor(red: 0.028, green: 0.04, blue: 0.065, alpha: 1)

        addLights(to: scene, depth: depth)

        // Reflective ground under everything — the premium base.
        let floorGeo = SCNFloor()
        floorGeo.reflectivity = 0.26
        floorGeo.reflectionFalloffEnd = 6
        let fm = SCNMaterial()
        fm.diffuse.contents = UIColor(red: 0.02, green: 0.03, blue: 0.045, alpha: 1)
        fm.metalness.contents = 0.7
        fm.roughness.contents = 0.2
        fm.lightingModel = .physicallyBased
        floorGeo.firstMaterial = fm
        scene.rootNode.addChildNode(SCNNode(geometry: floorGeo))

        addWalkway(to: scene, depth: depth)

        for placement in placements(for: agents) {
            let pod = pod(for: placement.agent)
            pod.position = placement.position
            scene.rootNode.addChildNode(pod)
        }
        return scene
    }

    /// The proven rig, floor-sized: tinted ambient + ONE warm shadow-casting
    /// directional key + a distant cool bounce + a gold pool over reception.
    /// No per-pod lights — twelve offices share four lights.
    private static func addLights(to scene: SCNScene, depth: Float) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 600
        ambient.color = UIColor(red: 0.42, green: 0.47, blue: 0.58, alpha: 1)
        let an = SCNNode(); an.light = ambient
        scene.rootNode.addChildNode(an)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 650
        key.color = UIColor(red: 1.0, green: 0.93, blue: 0.82, alpha: 1)
        key.castsShadow = true
        key.shadowRadius = 12
        key.shadowColor = UIColor(white: 0, alpha: 0.55)
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.orthographicScale = 14 + CGFloat(depth) / 2   // shadow frustum covers the floor
        let kn = SCNNode(); kn.light = key
        kn.position = SCNVector3(0, 8, -depth / 2)
        kn.eulerAngles = SCNVector3(-Float.pi / 2.6, 0.5, 0)
        scene.rootNode.addChildNode(kn)

        let bounce = SCNLight()
        bounce.type = .omni
        bounce.intensity = 380
        bounce.color = UIColor(red: 0.72, green: 0.82, blue: 1.0, alpha: 1)
        bounce.attenuationStartDistance = 4
        bounce.attenuationEndDistance = 36
        let bn = SCNNode(); bn.light = bounce
        bn.position = SCNVector3(0, 12, -depth / 2 + 2)
        scene.rootNode.addChildNode(bn)

        let pool = SCNLight()
        pool.type = .omni
        pool.intensity = 150
        pool.color = UIColor(red: 1.0, green: 0.85, blue: 0.6, alpha: 1)
        pool.attenuationStartDistance = 0.5
        pool.attenuationEndDistance = 8
        let pn = SCNNode(); pn.light = pool
        pn.position = SCNVector3(0, 3.4, 1.4)
        scene.rootNode.addChildNode(pn)
    }

    /// The central spine: an emerald runner between the two office rows and a
    /// small reception plinth with the brand mark up front.
    private static func addWalkway(to scene: SCNScene, depth: Float) {
        let length = CGFloat(depth) + podSize + 1.6
        let runner = SCNNode(geometry: SCNBox(width: 1.7, height: 0.02,
                                              length: length, chamferRadius: 0.01))
        runner.position = SCNVector3(0, 0.01, -depth / 2 + 0.4)
        runner.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.06, green: 0.16, blue: 0.12, alpha: 1),
                                             metalness: 0, roughness: 0.95)
        scene.rootNode.addChildNode(runner)

        let plinth = SCNNode(geometry: SCNCylinder(radius: 0.32, height: 0.85))
        plinth.position = SCNVector3(0, 0.425, 2.15)
        plinth.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.09, green: 0.1, blue: 0.12, alpha: 1),
                                             metalness: 0.4, roughness: 0.35)
        scene.rootNode.addChildNode(plinth)
        let mark = SCNNode(geometry: SCNCylinder(radius: 0.26, height: 0.02))
        mark.position = SCNVector3(0, 0.86, 2.15)
        mark.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.82, green: 0.67, blue: 0.34, alpha: 1),
                                           metalness: 0.9, roughness: 0.25)
        scene.rootNode.addChildNode(mark)
        addPlant(to: scene.rootNode, at: SCNVector3(0.75, 0, 2.3), scale: 1.0)
    }

    // MARK: One pod (self-contained: also the AR unit)

    /// Build one department office. Local space: floor slab centered at the
    /// origin, back wall at -z, side wall at -x — the open corner faces the
    /// floor camera's fixed +x/+z diagonal.
    static func pod(for agent: OrgAgent) -> SCNNode {
        let root = SCNNode()
        root.name = "pod-\(agent.id)"
        let accent = muted(UIColor(podHex: agent.accentHex))
        let r = role(for: agent)
        let seed = agent.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }

        addShell(to: root, accent: accent, role: r)
        addWallFeature(to: root, accent: accent, role: r)
        addWorkstation(to: root, agent: agent, accent: accent, role: r)
        addCozy(to: root, accent: accent, role: r, seed: seed)
        addProps(to: root, accent: accent, role: r)
        addStatusRing(to: root)
        return root
    }

    enum Role {
        case executive, finance, marketing, legal, research, engineering, operations, people, design, generic
    }

    static func role(for agent: OrgAgent) -> Role {
        if agent.tier == .ceo { return .executive }
        let s = (agent.title + " " + agent.name + " " + agent.summary).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }
        if has(["cfo", "financ", "account", "payroll", "procure", "budget"]) { return .finance }
        if has(["design", "creative", "art"]) { return .design }
        if has(["market", "content", "seo", "ads", "growth", "community", "brand"]) { return .marketing }
        if has(["legal", "lawyer", "complianc", "contract", "policy"]) { return .legal }
        if has(["research", "intelligence", "analyst"]) { return .research }
        if has(["build", "develop", "engineer", "cto", "devops", "qa", "command"]) { return .engineering }
        if has(["ops", "operation", "coo", "workflow", "task", "deliver"]) { return .operations }
        if has(["resource", "recruit", "training", "skills", "people", "hr"]) { return .people }
        return .generic
    }

    // MARK: Shell — slab, walls, ONE light cove

    private static func addShell(to root: SCNNode, accent: UIColor, role: Role) {
        let floorMat: SCNMaterial
        switch role {
        case .executive:
            floorMat = pbr(diffuse: UIColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1), metalness: 0.3, roughness: 0.12) // polished marble
        case .legal:
            floorMat = pbr(diffuse: UIColor(red: 0.16, green: 0.115, blue: 0.08, alpha: 1), metalness: 0.05, roughness: 0.35) // walnut
        case .engineering, .operations:
            floorMat = pbr(diffuse: UIColor(red: 0.10, green: 0.115, blue: 0.135, alpha: 1), metalness: 0.7, roughness: 0.3) // tech plate
        case .design, .marketing:
            floorMat = pbr(diffuse: UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1), metalness: 0.2, roughness: 0.6)   // studio concrete
        default:
            floorMat = pbr(diffuse: UIColor(red: 0.09, green: 0.12, blue: 0.16, alpha: 1), metalness: 0.6, roughness: 0.3)   // dark glass
        }
        let slab = SCNNode(geometry: SCNBox(width: podSize, height: 0.1, length: podSize, chamferRadius: 0.03))
        slab.position = SCNVector3(0, 0.05, 0)
        slab.geometry?.firstMaterial = floorMat
        root.addChildNode(slab)
        // Furniture below sits on y=0; lift the room contents onto the slab.
        let contentsNode = SCNNode()
        contentsNode.name = "contents"
        contentsNode.position = SCNVector3(0, 0.1, 0)
        root.addChildNode(contentsNode)

        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        accent.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let wall = pbr(diffuse: UIColor(hue: h, saturation: s * 0.25, brightness: 0.30, alpha: 1),
                       metalness: 0.3, roughness: 0.6)

        let half = Float(podSize / 2)
        let back = SCNNode(geometry: SCNBox(width: podSize, height: wallHeight, length: 0.1, chamferRadius: 0))
        back.position = SCNVector3(0, Float(wallHeight / 2), -half + 0.05)
        back.geometry?.firstMaterial = wall
        contentsNode.addChildNode(back)

        let side = SCNNode(geometry: SCNBox(width: 0.1, height: wallHeight, length: podSize, chamferRadius: 0))
        side.position = SCNVector3(-half + 0.05, Float(wallHeight / 2), 0)
        side.geometry?.firstMaterial = wall
        contentsNode.addChildNode(side)

        // THE one emission accent (the HQ strip pattern): a soft cove line
        // where the walls meet the ceiling — gold for the suite, accent-muted
        // for everyone else. Replaces all the old neon trim.
        let coveColor = role == .executive
            ? UIColor(red: 0.85, green: 0.7, blue: 0.4, alpha: 0.5)
            : accent.withAlphaComponent(0.45)
        let coveBack = SCNNode(geometry: SCNBox(width: podSize - 0.1, height: 0.025, length: 0.04, chamferRadius: 0))
        coveBack.position = SCNVector3(0, Float(wallHeight) - 0.06, -half + 0.12)
        coveBack.geometry?.firstMaterial = glow(coveColor)
        contentsNode.addChildNode(coveBack)
        let coveSide = SCNNode(geometry: SCNBox(width: 0.04, height: 0.025, length: podSize - 0.1, chamferRadius: 0))
        coveSide.position = SCNVector3(-half + 0.12, Float(wallHeight) - 0.06, 0)
        coveSide.geometry?.firstMaterial = glow(coveColor)
        contentsNode.addChildNode(coveSide)
    }

    private static func contents(of root: SCNNode) -> SCNNode {
        root.childNode(withName: "contents", recursively: false) ?? root
    }

    // MARK: Wall feature — the department's signature view

    private static func addWallFeature(to root: SCNNode, accent: UIColor, role: Role) {
        let node = contents(of: root)
        let backZ = -Float(podSize / 2) + 0.11
        if role == .executive {
            // Floor-to-ceiling night skyline behind champagne-gold mullions —
            // on the SIDE (-x) wall. The suite sits front-left on the floor,
            // so that wall is the building's outer edge; the back wall is a
            // partition with another office behind it, no window there.
            let sideX = -Float(podSize / 2) + 0.115
            let midY = Float((wallHeight - 0.45) / 2) + 0.2
            let window = SCNNode(geometry: SCNPlane(width: podSize - 0.6, height: wallHeight - 0.45))
            window.position = SCNVector3(sideX, midY, 0.1)
            window.eulerAngles.y = .pi / 2
            let m = SCNMaterial()
            let sky = skylineMini()
            m.diffuse.contents = sky
            m.emission.contents = sky
            m.emission.intensity = 0.6
            m.lightingModel = .constant
            window.geometry?.firstMaterial = m
            node.addChildNode(window)

            let gold = pbr(diffuse: UIColor(red: 0.62, green: 0.52, blue: 0.34, alpha: 1), metalness: 0.9, roughness: 0.25)
            for z in [Float(-1.05), -0.3, 0.55, 1.4] {
                let mull = SCNNode(geometry: SCNBox(width: 0.025, height: wallHeight - 0.45, length: 0.03, chamferRadius: 0))
                mull.position = SCNVector3(sideX + 0.015, midY, z)
                mull.geometry?.firstMaterial = gold
                node.addChildNode(mull)
            }
        } else {
            // The department's wall dashboard in a dark metal frame.
            let frame = SCNNode(geometry: SCNBox(width: 1.32, height: 0.86, length: 0.03, chamferRadius: 0.01))
            frame.position = SCNVector3(0.4, 1.35, backZ)
            frame.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.08, alpha: 1), metalness: 0.8, roughness: 0.3)
            node.addChildNode(frame)

            let panel = SCNNode(geometry: SCNPlane(width: 1.24, height: 0.78))
            panel.position = SCNVector3(0.4, 1.35, backZ + 0.02)
            let m = SCNMaterial()
            let tex = wallTexture(role: role, accent: accent)
            m.diffuse.contents = tex
            m.emission.contents = tex
            m.emission.intensity = 0.75
            m.lightingModel = .constant
            panel.geometry?.firstMaterial = m
            node.addChildNode(panel)
        }
    }

    // MARK: Workstation — desk, chair, monitor, the robot at work

    private static func addWorkstation(to root: SCNNode, agent: OrgAgent, accent: UIColor, role: Role) {
        let deskMat: SCNMaterial
        switch role {
        case .executive, .legal:
            deskMat = pbr(diffuse: UIColor(red: 0.13, green: 0.09, blue: 0.065, alpha: 1), metalness: 0.05, roughness: 0.35)
        default:
            deskMat = pbr(diffuse: UIColor(red: 0.08, green: 0.1, blue: 0.13, alpha: 1), metalness: 0.6, roughness: 0.3)
        }
        let dark = pbr(diffuse: UIColor(white: 0.09, alpha: 1), metalness: 0.6, roughness: 0.35)

        let station = SCNNode()
        station.position = SCNVector3(-0.18, 0, -0.05)
        station.eulerAngles.y = 0.82          // face the floor camera's diagonal

        let top = SCNNode(geometry: SCNBox(width: 1.15, height: 0.06, length: 0.46, chamferRadius: 0.02))
        top.position = SCNVector3(0, 0.52, 0.22)
        top.geometry?.firstMaterial = deskMat
        station.addChildNode(top)
        for x in [Float(-0.5), 0.5] {
            let leg = SCNNode(geometry: SCNBox(width: 0.05, height: 0.52, length: 0.4, chamferRadius: 0.01))
            leg.position = SCNVector3(x, 0.26, 0.22)
            leg.geometry?.firstMaterial = deskMat
            station.addChildNode(leg)
        }

        // Monitor, screen toward the robot (back to camera).
        let bezel = SCNNode(geometry: SCNBox(width: 0.5, height: 0.32, length: 0.025, chamferRadius: 0.01))
        bezel.position = SCNVector3(0, 0.78, 0.28)
        bezel.geometry?.firstMaterial = dark
        station.addChildNode(bezel)
        let stand = SCNNode(geometry: SCNCylinder(radius: 0.02, height: 0.14))
        stand.position = SCNVector3(0, 0.6, 0.28)
        stand.geometry?.firstMaterial = dark
        station.addChildNode(stand)
        // Soft screen-light spill on the robot — dim, not neon.
        let spill = SCNNode(geometry: SCNPlane(width: 0.46, height: 0.28))
        spill.position = SCNVector3(0, 0.78, 0.265)
        spill.eulerAngles.y = .pi
        let sm = SCNMaterial()
        sm.diffuse.contents = UIColor(red: 0.04, green: 0.08, blue: 0.1, alpha: 1)
        sm.emission.contents = accent.withAlphaComponent(0.4)
        sm.lightingModel = .constant
        spill.geometry?.firstMaterial = sm
        station.addChildNode(spill)

        // Desk clutter: mug + papers.
        let mug = SCNNode(geometry: SCNCylinder(radius: 0.035, height: 0.08))
        mug.position = SCNVector3(0.4, 0.59, 0.16)
        mug.geometry?.firstMaterial = pbr(diffuse: accent, metalness: 0.1, roughness: 0.4)
        station.addChildNode(mug)
        let papers = SCNNode(geometry: SCNBox(width: 0.16, height: 0.006, length: 0.22, chamferRadius: 0))
        papers.position = SCNVector3(-0.38, 0.555, 0.2)
        papers.eulerAngles.y = -0.2
        papers.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.85, alpha: 1), metalness: 0, roughness: 0.9)
        station.addChildNode(papers)

        // The chair — and the robot at it.
        let chair = SCNNode()
        chair.position = SCNVector3(0, 0, -0.28)
        let seat = SCNNode(geometry: SCNCylinder(radius: 0.21, height: 0.06))
        seat.position = SCNVector3(0, 0.27, 0)
        seat.geometry?.firstMaterial = dark
        chair.addChildNode(seat)
        let backRest = SCNNode(geometry: SCNBox(width: 0.36, height: 0.42, length: 0.05, chamferRadius: 0.05))
        backRest.position = SCNVector3(0, 0.52, -0.2)
        backRest.eulerAngles.x = -0.08
        backRest.geometry?.firstMaterial = dark
        chair.addChildNode(backRest)
        let post = SCNNode(geometry: SCNCylinder(radius: 0.03, height: 0.24))
        post.position = SCNVector3(0, 0.12, 0)
        post.geometry?.firstMaterial = dark
        chair.addChildNode(post)
        for k in 0..<5 {
            let a = Float(k) / 5 * .pi * 2
            let footLeg = SCNNode(geometry: SCNBox(width: 0.03, height: 0.02, length: 0.18, chamferRadius: 0.01))
            footLeg.position = SCNVector3(sin(a) * 0.1, 0.02, cos(a) * 0.1)
            footLeg.eulerAngles.y = a
            footLeg.geometry?.firstMaterial = dark
            chair.addChildNode(footLeg)
        }
        station.addChildNode(chair)

        // 0.62: the rigged character is slimmer than the old chunky primitive.
        let robot = AgentRobot.node(for: agent, color: accent)
        robot.scale = SCNVector3(0.62, 0.62, 0.62)
        robot.position = SCNVector3(0, 0.14, -0.28)
        station.addChildNode(robot)

        contents(of: root).addChildNode(station)
    }

    /// Live-status halo on the floor around the workstation — tint + pulse
    /// come from `AgentStatusResolver`, never a hardcoded "online".
    private static func addStatusRing(to root: SCNNode) {
        let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.62, pipeRadius: 0.014))
        ring.name = "status-ring"
        ring.position = SCNVector3(-0.18, 0.03, -0.05)
        ring.geometry?.firstMaterial = glow(UIColor(red: 0.68, green: 0.72, blue: 0.78, alpha: 0.5))
        ring.opacity = 0.6
        contents(of: root).addChildNode(ring)
    }

    static func applyStatus(_ status: HQAgentStatus, to ring: SCNNode) {
        let color = status.tint.withAlphaComponent(0.75)
        ring.geometry?.firstMaterial?.diffuse.contents = color
        ring.geometry?.firstMaterial?.emission.contents = color
        ring.removeAction(forKey: "pulse")
        ring.runAction(.repeatForever(.sequence([
            .fadeOpacity(to: 0.75, duration: status.pulse),
            .fadeOpacity(to: 0.3, duration: status.pulse),
        ])), forKey: "pulse")
    }

    // MARK: Cozy layer — rug, pendant, sofa, plant, wall art

    private static func addCozy(to root: SCNNode, accent: UIColor, role: Role, seed: Int) {
        let node = contents(of: root)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        accent.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // Rug under the workstation.
        let rug = SCNNode(geometry: SCNCylinder(radius: 0.82, height: 0.012))
        rug.position = SCNVector3(-0.18, 0.012, -0.05)
        rug.geometry?.firstMaterial = pbr(diffuse: UIColor(hue: h, saturation: s * 0.35, brightness: 0.22, alpha: 1),
                                          metalness: 0, roughness: 0.95)
        node.addChildNode(rug)

        // Pendant lamp over the desk — warm emissive bulb, NO SCNLight:
        // twelve pods share the four scene lights (SceneKit's per-draw light
        // budget), and the global rig already pools warmth where it matters.
        let cord = SCNNode(geometry: SCNCylinder(radius: 0.008, height: 0.5))
        cord.position = SCNVector3(-0.18, Float(wallHeight) - 0.31, -0.05)
        cord.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.1, alpha: 1), metalness: 0.5, roughness: 0.4)
        node.addChildNode(cord)
        let shade = SCNNode(geometry: SCNCone(topRadius: 0.035, bottomRadius: 0.12, height: 0.1))
        shade.position = SCNVector3(-0.18, Float(wallHeight) - 0.6, -0.05)
        shade.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.12, alpha: 1), metalness: 0.4, roughness: 0.4)
        node.addChildNode(shade)
        let bulb = SCNNode(geometry: SCNSphere(radius: 0.032))
        bulb.position = SCNVector3(-0.18, Float(wallHeight) - 0.63, -0.05)
        bulb.geometry?.firstMaterial = glow(UIColor(red: 1, green: 0.85, blue: 0.6, alpha: 0.9))
        node.addChildNode(bulb)

        // Lounge seating against the back wall.
        if role == .executive {
            node.addChildNode(executiveLounge(h: h, s: s))
        } else if [Role.marketing, .people, .design, .generic, .research].contains(role) {
            let sofa = SCNNode()
            sofa.position = SCNVector3(0.95, 0, -1.35)
            let base = SCNNode(geometry: SCNBox(width: 0.62, height: 0.18, length: 0.3, chamferRadius: 0.04))
            base.position = SCNVector3(0, 0.13, 0)
            base.geometry?.firstMaterial = pbr(diffuse: UIColor(hue: h, saturation: s * 0.4, brightness: 0.3, alpha: 1),
                                               metalness: 0, roughness: 0.8)
            sofa.addChildNode(base)
            let backCushion = SCNNode(geometry: SCNBox(width: 0.62, height: 0.26, length: 0.08, chamferRadius: 0.04))
            backCushion.position = SCNVector3(0, 0.31, -0.11)
            backCushion.geometry?.firstMaterial = base.geometry?.firstMaterial
            sofa.addChildNode(backCushion)
            for dx in [Float(-0.155), 0.155] {
                let cushion = SCNNode(geometry: SCNBox(width: 0.28, height: 0.07, length: 0.26, chamferRadius: 0.03))
                cushion.position = SCNVector3(dx, 0.25, 0.01)
                cushion.geometry?.firstMaterial = pbr(diffuse: UIColor(hue: h, saturation: s * 0.3, brightness: 0.38, alpha: 1),
                                                      metalness: 0, roughness: 0.85)
                sofa.addChildNode(cushion)
            }
            node.addChildNode(sofa)
        }

        // Every office gets a plant — size and spot vary per agent.
        let plantX: Float = seed % 2 == 0 ? -1.05 : 1.1
        let plantZ: Float = seed % 2 == 0 ? 0.95 : 0.7
        addPlant(to: node, at: SCNVector3(plantX, 0, plantZ), scale: 0.8 + Float(seed % 5) / 10)

        // A piece of wall art beside the dashboard — matte, gallery-lit by the
        // room, not self-glowing.
        let art = SCNNode(geometry: SCNPlane(width: 0.3, height: 0.38))
        art.position = SCNVector3(-0.85, 1.35, -Float(podSize / 2) + 0.12)
        art.geometry?.firstMaterial = pbr(diffuse: UIColor(hue: h, saturation: s * 0.45, brightness: 0.42, alpha: 1),
                                          metalness: 0.05, roughness: 0.8)
        node.addChildNode(art)
        let artFrame = SCNNode(geometry: SCNBox(width: 0.34, height: 0.42, length: 0.015, chamferRadius: 0.005))
        artFrame.position = SCNVector3(-0.85, 1.35, -Float(podSize / 2) + 0.1)
        artFrame.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.55, green: 0.45, blue: 0.3, alpha: 1), metalness: 0.7, roughness: 0.35)
        node.addChildNode(artFrame)
    }

    private static func addPlant(to node: SCNNode, at pos: SCNVector3, scale: Float) {
        let pot = SCNNode(geometry: SCNCylinder(radius: 0.1, height: 0.16))
        pot.position = SCNVector3(pos.x, pos.y + 0.08, pos.z)
        pot.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.14, green: 0.12, blue: 0.1, alpha: 1), metalness: 0.1, roughness: 0.8)
        node.addChildNode(pot)
        let green = pbr(diffuse: UIColor(red: 0.12, green: 0.4, blue: 0.21, alpha: 1), metalness: 0, roughness: 0.75)
        for (dx, dh, dz) in [(Float(0), Float(0.34), Float(0)), (-0.07, 0.26, 0.05), (0.07, 0.28, -0.05), (0.03, 0.2, 0.08)] {
            let leaf = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.085, height: CGFloat(dh * scale)))
            leaf.position = SCNVector3(pos.x + dx, pos.y + 0.16 + dh * scale / 2, pos.z + dz)
            leaf.geometry?.firstMaterial = green
            node.addChildNode(leaf)
        }
    }

    /// The suite's lounge — leather sofa with gold feet + glass coffee table.
    private static func executiveLounge(h: CGFloat, s: CGFloat) -> SCNNode {
        let lounge = SCNNode()
        lounge.position = SCNVector3(0.8, 0, -1.22)
        let leather = pbr(diffuse: UIColor(red: 0.18, green: 0.13, blue: 0.10, alpha: 1), metalness: 0.1, roughness: 0.5)
        let gold = pbr(diffuse: UIColor(red: 0.82, green: 0.67, blue: 0.34, alpha: 1), metalness: 0.9, roughness: 0.25)

        let base = SCNNode(geometry: SCNBox(width: 1.0, height: 0.2, length: 0.42, chamferRadius: 0.05))
        base.position = SCNVector3(0, 0.16, 0)
        base.geometry?.firstMaterial = leather
        lounge.addChildNode(base)
        let backRest = SCNNode(geometry: SCNBox(width: 1.0, height: 0.34, length: 0.1, chamferRadius: 0.05))
        backRest.position = SCNVector3(0, 0.4, -0.16)
        backRest.geometry?.firstMaterial = leather
        lounge.addChildNode(backRest)
        for dx in [Float(-0.46), 0.46] {
            let arm = SCNNode(geometry: SCNBox(width: 0.1, height: 0.28, length: 0.42, chamferRadius: 0.05))
            arm.position = SCNVector3(dx, 0.34, 0)
            arm.geometry?.firstMaterial = leather
            lounge.addChildNode(arm)
        }
        let cushionMat = pbr(diffuse: UIColor(hue: h, saturation: s * 0.25, brightness: 0.22, alpha: 1),
                             metalness: 0.1, roughness: 0.6)
        for dx in [Float(-0.3), 0, 0.3] {
            let cushion = SCNNode(geometry: SCNBox(width: 0.3, height: 0.08, length: 0.38, chamferRadius: 0.04))
            cushion.position = SCNVector3(dx, 0.3, 0.01)
            cushion.geometry?.firstMaterial = cushionMat
            lounge.addChildNode(cushion)
        }
        for dx in [Float(-0.44), 0.44] {
            for dz in [Float(-0.16), 0.16] {
                let foot = SCNNode(geometry: SCNCylinder(radius: 0.022, height: 0.08))
                foot.position = SCNVector3(dx, 0.04, dz)
                foot.geometry?.firstMaterial = gold
                lounge.addChildNode(foot)
            }
        }
        let table = SCNNode()
        table.position = SCNVector3(0, 0, 0.5)
        let glass = SCNNode(geometry: SCNBox(width: 0.6, height: 0.03, length: 0.34, chamferRadius: 0.02))
        glass.position = SCNVector3(0, 0.3, 0)
        glass.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.1, green: 0.14, blue: 0.16, alpha: 1), metalness: 0.3, roughness: 0.1)
        table.addChildNode(glass)
        for dx in [Float(-0.26), 0.26] {
            for dz in [Float(-0.13), 0.13] {
                let leg = SCNNode(geometry: SCNCylinder(radius: 0.012, height: 0.3))
                leg.position = SCNVector3(dx, 0.15, dz)
                leg.geometry?.firstMaterial = gold
                table.addChildNode(leg)
            }
        }
        lounge.addChildNode(table)
        return lounge
    }

    // MARK: Role props — identity WITHOUT the clip-art

    private static func addProps(to root: SCNNode, accent: UIColor, role: Role) {
        let node = contents(of: root)
        let gold = pbr(diffuse: UIColor(red: 0.82, green: 0.67, blue: 0.34, alpha: 1), metalness: 0.9, roughness: 0.25)
        let dark = pbr(diffuse: UIColor(white: 0.1, alpha: 1), metalness: 0.6, roughness: 0.35)
        let walnut = pbr(diffuse: UIColor(red: 0.13, green: 0.09, blue: 0.065, alpha: 1), metalness: 0.05, roughness: 0.35)
        let sideX = -Float(podSize / 2) + 0.12

        switch role {
        case .executive:
            // Globe on a gold stand + low credenza.
            let credenza = SCNNode(geometry: SCNBox(width: 0.7, height: 0.32, length: 0.3, chamferRadius: 0.02))
            credenza.position = SCNVector3(-1.0, 0.16, -1.1)
            credenza.geometry?.firstMaterial = walnut
            node.addChildNode(credenza)
            let globe = SCNNode(geometry: SCNSphere(radius: 0.12))
            globe.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.1, green: 0.25, blue: 0.4, alpha: 1), metalness: 0.3, roughness: 0.4)
            globe.position = SCNVector3(1.0, 0.7, 0.65)
            node.addChildNode(globe)
            let stand = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 0.58))
            stand.geometry?.firstMaterial = gold
            stand.position = SCNVector3(1.0, 0.29, 0.65)
            node.addChildNode(stand)

        case .finance:
            // A proper records credenza with standing ledgers and a brass
            // banker's lamp — the coin stacks and cartoon safe are gone.
            let credenza = SCNNode(geometry: SCNBox(width: 0.85, height: 0.36, length: 0.3, chamferRadius: 0.02))
            credenza.position = SCNVector3(-0.95, 0.18, -1.1)
            credenza.geometry?.firstMaterial = walnut
            node.addChildNode(credenza)
            let ledgerColors = [accent, UIColor(red: 0.2, green: 0.28, blue: 0.4, alpha: 1), UIColor(white: 0.55, alpha: 1)]
            for i in 0..<5 {
                let ledger = SCNNode(geometry: SCNBox(width: 0.045, height: 0.22 - CGFloat(i % 3) * 0.015, length: 0.16, chamferRadius: 0.004))
                ledger.position = SCNVector3(-1.2 + Float(i) * 0.06, 0.36 + 0.11, -1.1)
                ledger.eulerAngles.z = i == 4 ? 0.14 : 0
                ledger.geometry?.firstMaterial = pbr(diffuse: ledgerColors[i % 3], metalness: 0.05, roughness: 0.6)
                node.addChildNode(ledger)
            }
            let lampStem = SCNNode(geometry: SCNCylinder(radius: 0.012, height: 0.16))
            lampStem.position = SCNVector3(-0.72, 0.36 + 0.08, -1.1)
            lampStem.geometry?.firstMaterial = gold
            node.addChildNode(lampStem)
            let lampShade = SCNNode(geometry: SCNBox(width: 0.16, height: 0.05, length: 0.09, chamferRadius: 0.02))
            lampShade.position = SCNVector3(-0.72, 0.36 + 0.17, -1.1)
            lampShade.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.08, green: 0.3, blue: 0.2, alpha: 1), metalness: 0.2, roughness: 0.35)
            node.addChildNode(lampShade)

        case .engineering:
            // Server rack — matte panels with two faint status slits instead
            // of the old wall of glowing LED spheres.
            let rack = SCNNode(geometry: SCNBox(width: 0.45, height: 1.15, length: 0.4, chamferRadius: 0.02))
            rack.position = SCNVector3(-0.95, 0.575, -1.0)
            rack.geometry?.firstMaterial = dark
            node.addChildNode(rack)
            for (i, y) in [Float(0.42), 0.78].enumerated() {
                let slit = SCNNode(geometry: SCNBox(width: 0.3, height: 0.012, length: 0.01, chamferRadius: 0))
                slit.position = SCNVector3(-0.95, y, -0.79)
                let color = i == 0 ? UIColor(red: 0.3, green: 0.75, blue: 0.5, alpha: 0.4) : accent.withAlphaComponent(0.35)
                slit.geometry?.firstMaterial = glow(color)
                node.addChildNode(slit)
            }
            for y in [Float(0.25), 0.6, 0.95] {
                let vent = SCNNode(geometry: SCNBox(width: 0.36, height: 0.05, length: 0.005, chamferRadius: 0.002))
                vent.position = SCNVector3(-0.95, y, -0.795)
                vent.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.16, alpha: 1), metalness: 0.7, roughness: 0.4)
                node.addChildNode(vent)
            }

        case .operations:
            // Kanban board on the side wall — drawn texture, not neon notes.
            let frame = SCNNode(geometry: SCNBox(width: 0.03, height: 0.72, length: 1.05, chamferRadius: 0.01))
            frame.position = SCNVector3(sideX, 1.15, 0.2)
            frame.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.08, alpha: 1), metalness: 0.8, roughness: 0.3)
            node.addChildNode(frame)
            let board = SCNNode(geometry: SCNPlane(width: 0.98, height: 0.64))
            board.position = SCNVector3(sideX + 0.03, 1.15, 0.2)
            board.eulerAngles.y = .pi / 2
            let m = SCNMaterial()
            let tex = wallTexture(role: .operations, accent: accent)
            m.diffuse.contents = tex
            m.emission.contents = tex
            m.emission.intensity = 0.6
            m.lightingModel = .constant
            board.geometry?.firstMaterial = m
            node.addChildNode(board)
            let crate = SCNNode(geometry: SCNBox(width: 0.32, height: 0.32, length: 0.32, chamferRadius: 0.02))
            crate.position = SCNVector3(1.05, 0.16, 0.7)
            crate.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.35, green: 0.27, blue: 0.18, alpha: 1), metalness: 0.05, roughness: 0.7)
            node.addChildNode(crate)

        case .marketing:
            // A campaign wall: two framed prints on the side wall — the
            // megaphone-on-a-tripod and neon billboard strip are retired.
            for (i, size) in [(CGSize(width: 0.62, height: 0.44)), CGSize(width: 0.4, height: 0.5)].enumerated() {
                let z: Float = i == 0 ? 0.05 : 0.75
                let y: Float = i == 0 ? 1.25 : 1.1
                let frame = SCNNode(geometry: SCNBox(width: 0.025, height: size.height + 0.06, length: size.width + 0.06, chamferRadius: 0.005))
                frame.position = SCNVector3(sideX, y, z)
                frame.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.55, green: 0.45, blue: 0.3, alpha: 1), metalness: 0.7, roughness: 0.35)
                node.addChildNode(frame)
                let print = SCNNode(geometry: SCNPlane(width: size.width, height: size.height))
                print.position = SCNVector3(sideX + 0.025, y, z)
                print.eulerAngles.y = .pi / 2
                let m = SCNMaterial()
                if i == 0 {
                    let tex = wallTexture(role: .marketing, accent: accent)
                    m.diffuse.contents = tex
                    m.emission.contents = tex
                    m.emission.intensity = 0.55
                    m.lightingModel = .constant
                } else {
                    m.diffuse.contents = swatchTexture(accent: accent)
                    m.lightingModel = .physicallyBased
                    m.roughness.contents = 0.8
                }
                print.geometry?.firstMaterial = m
                node.addChildNode(print)
            }

        case .legal:
            // Bookshelf with rows of books + brass scales on a side table.
            let shelf = SCNNode(geometry: SCNBox(width: 0.5, height: 1.2, length: 0.3, chamferRadius: 0.01))
            shelf.position = SCNVector3(-0.95, 0.6, -1.0)
            shelf.geometry?.firstMaterial = walnut
            node.addChildNode(shelf)
            let bookColors = [accent, UIColor(red: 0.5, green: 0.42, blue: 0.3, alpha: 1), UIColor(white: 0.55, alpha: 1)]
            for row in 0..<3 {
                for slot in 0..<4 {
                    let book = SCNNode(geometry: SCNBox(width: 0.055, height: 0.18, length: 0.12, chamferRadius: 0.004))
                    book.geometry?.firstMaterial = pbr(diffuse: bookColors[(row + slot) % 3], metalness: 0.05, roughness: 0.6)
                    book.position = SCNVector3(-1.06 + Float(slot) * 0.075, 0.32 + Float(row) * 0.34, -0.8)
                    node.addChildNode(book)
                }
            }
            let post = SCNNode(geometry: SCNCylinder(radius: 0.012, height: 0.26))
            post.geometry?.firstMaterial = gold
            post.position = SCNVector3(1.0, 0.13, 0.65)
            node.addChildNode(post)
            let beam = SCNNode(geometry: SCNBox(width: 0.22, height: 0.012, length: 0.012, chamferRadius: 0))
            beam.geometry?.firstMaterial = gold
            beam.position = SCNVector3(1.0, 0.26, 0.65)
            node.addChildNode(beam)
            for dx in [Float(-0.1), 0.1] {
                let pan = SCNNode(geometry: SCNCylinder(radius: 0.045, height: 0.01))
                pan.geometry?.firstMaterial = gold
                pan.position = SCNVector3(1.0 + dx, 0.21, 0.65)
                node.addChildNode(pan)
            }

        case .research:
            // Whiteboard on the side wall — the scatter plot lives in the
            // drawn texture now, not as floating glow-spheres.
            let board = SCNNode(geometry: SCNPlane(width: 0.98, height: 0.64))
            board.position = SCNVector3(sideX + 0.03, 1.15, 0.2)
            board.eulerAngles.y = .pi / 2
            let m = SCNMaterial()
            m.diffuse.contents = whiteboardTexture(accent: accent)
            m.lightingModel = .physicallyBased
            m.roughness.contents = 0.55
            board.geometry?.firstMaterial = m
            node.addChildNode(board)
            let tray = SCNNode(geometry: SCNBox(width: 0.02, height: 0.02, length: 0.9, chamferRadius: 0.005))
            tray.position = SCNVector3(sideX + 0.04, 0.81, 0.2)
            tray.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.7, alpha: 1), metalness: 0.9, roughness: 0.25)
            node.addChildNode(tray)
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.07, pipeRadius: 0.013))
            ring.geometry?.firstMaterial = pbr(diffuse: UIColor(white: 0.7, alpha: 1), metalness: 0.9, roughness: 0.25)
            ring.position = SCNVector3(1.0, 0.1, 0.65)
            ring.eulerAngles.x = .pi / 2.5
            node.addChildNode(ring)

        case .people:
            // A meeting corner: two guest chairs facing each other.
            for (x, rot) in [(Float(0.95), Float.pi / 2), (0.95, -.pi / 2)] {
                let chair = SCNNode()
                let seat = SCNNode(geometry: SCNBox(width: 0.26, height: 0.05, length: 0.26, chamferRadius: 0.03))
                seat.position = SCNVector3(0, 0.22, 0)
                seat.geometry?.firstMaterial = pbr(diffuse: accent, metalness: 0.1, roughness: 0.5)
                chair.addChildNode(seat)
                let back = SCNNode(geometry: SCNBox(width: 0.26, height: 0.3, length: 0.04, chamferRadius: 0.03))
                back.position = SCNVector3(0, 0.38, 0.12)
                back.geometry?.firstMaterial = pbr(diffuse: accent, metalness: 0.1, roughness: 0.5)
                chair.addChildNode(back)
                let post = SCNNode(geometry: SCNCylinder(radius: 0.025, height: 0.2))
                post.position = SCNVector3(0, 0.1, 0)
                post.geometry?.firstMaterial = dark
                chair.addChildNode(post)
                chair.position = SCNVector3(x, 0, rot > 0 ? 0.35 : 0.95)
                chair.eulerAngles.y = rot > 0 ? 0 : .pi
                node.addChildNode(chair)
            }

        case .design:
            // Easel with a color-swatch canvas.
            let canvas = SCNNode(geometry: SCNPlane(width: 0.5, height: 0.4))
            canvas.position = SCNVector3(0.95, 0.75, 0.65)
            canvas.eulerAngles = SCNVector3(-0.15, .pi / 4, 0)
            let cm = SCNMaterial()
            cm.diffuse.contents = swatchTexture(accent: accent)
            cm.lightingModel = .physicallyBased
            cm.roughness.contents = 0.8
            canvas.geometry?.firstMaterial = cm
            node.addChildNode(canvas)
            for dx in [Float(-0.18), 0.18] {
                let legNode = SCNNode(geometry: SCNCylinder(radius: 0.015, height: 0.8))
                legNode.geometry?.firstMaterial = pbr(diffuse: UIColor(red: 0.35, green: 0.27, blue: 0.18, alpha: 1), metalness: 0.05, roughness: 0.6)
                legNode.position = SCNVector3(0.95 + dx, 0.4, 0.65 + abs(dx) * 0.4)
                legNode.eulerAngles.x = 0.18
                node.addChildNode(legNode)
            }

        case .generic:
            break   // the cozy layer (sofa, plant, art) furnishes this one
        }
    }

    // MARK: Drawn textures

    /// Compact role dashboard used on the wall panel.
    private static func wallTexture(role: Role, accent: UIColor) -> UIImage {
        let size = CGSize(width: 460, height: 290)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            UIColor(red: 0.015, green: 0.035, blue: 0.05, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            c.setStrokeColor(accent.withAlphaComponent(0.5).cgColor)
            c.setLineWidth(3)
            c.stroke(CGRect(x: 4, y: 4, width: size.width - 8, height: size.height - 8))

            switch role {
            case .finance:
                let vals: [CGFloat] = [0.3, 0.42, 0.38, 0.55, 0.5, 0.72, 0.88]
                let rect = CGRect(x: 30, y: 40, width: 400, height: 210)
                let pts = vals.enumerated().map { i, v in
                    CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(vals.count - 1), y: rect.maxY - rect.height * v)
                }
                c.setStrokeColor(UIColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1).cgColor)
                c.setLineWidth(7); c.setLineJoin(.round)
                c.move(to: pts[0]); pts.dropFirst().forEach { c.addLine(to: $0) }; c.strokePath()
            case .engineering:
                var seed: UInt64 = 11
                func rnd() -> CGFloat { seed = seed &* 2862933555777941757 &+ 3037000493; return CGFloat((seed >> 33) % 1000) / 1000 }
                for i in 0..<7 {
                    c.setFillColor((i % 3 == 0 ? accent : UIColor(white: 0.55, alpha: 1)).withAlphaComponent(0.85).cgColor)
                    c.fill(CGRect(x: 26 + CGFloat(Int(rnd() * 3)) * 26, y: 30 + CGFloat(i) * 35, width: 90 + rnd() * 240, height: 13))
                }
            case .operations:
                for col in 0..<3 {
                    let x = 26 + CGFloat(col) * 142
                    c.setFillColor(UIColor(white: 1, alpha: 0.07).cgColor)
                    c.fill(CGRect(x: x, y: 28, width: 126, height: 234))
                    for card in 0..<(3 - col % 2) {
                        c.setFillColor(accent.withAlphaComponent(0.6).cgColor)
                        c.fill(CGRect(x: x + 10, y: 40 + CGFloat(card) * 58, width: 106, height: 44))
                    }
                }
            case .marketing:
                for (i, v) in [CGFloat(0.45), 0.75, 0.55, 0.9].enumerated() {
                    let h: CGFloat = 190 * v
                    c.setFillColor(accent.withAlphaComponent(0.85).cgColor)
                    c.fill(CGRect(x: 40 + CGFloat(i) * 105, y: 250 - h, width: 60, height: h))
                }
            case .legal:
                for i in 0..<6 {
                    c.setFillColor(UIColor(white: 0.8, alpha: i == 0 ? 0.9 : 0.35).cgColor)
                    c.fill(CGRect(x: 28, y: 34 + CGFloat(i) * 40, width: i == 0 ? 200 : 330 - CGFloat(i % 3) * 50, height: i == 0 ? 18 : 10))
                }
                c.setStrokeColor(accent.cgColor); c.setLineWidth(4)
                c.strokeEllipse(in: CGRect(x: 360, y: 190, width: 64, height: 64))
            case .research:
                var seed: UInt64 = 31
                func rnd() -> CGFloat { seed = seed &* 2862933555777941757 &+ 3037000493; return CGFloat((seed >> 33) % 1000) / 1000 }
                for _ in 0..<26 {
                    c.setFillColor(accent.withAlphaComponent(0.35 + rnd() * 0.6).cgColor)
                    c.fillEllipse(in: CGRect(x: 30 + rnd() * 390, y: 36 + rnd() * 215, width: 9, height: 9))
                }
            case .people:
                let centers = [(110, 90), (240, 60), (350, 110), (170, 200), (310, 210)]
                c.setStrokeColor(accent.withAlphaComponent(0.5).cgColor); c.setLineWidth(2.5)
                for i in 0..<centers.count {
                    for j in (i + 1)..<centers.count where (i + j) % 2 == 0 {
                        c.move(to: CGPoint(x: centers[i].0, y: centers[i].1))
                        c.addLine(to: CGPoint(x: centers[j].0, y: centers[j].1))
                    }
                }
                c.strokePath()
                for (x, y) in centers {
                    c.setFillColor(accent.cgColor)
                    c.fillEllipse(in: CGRect(x: x - 15, y: y - 15, width: 30, height: 30))
                }
            case .design:
                let colors: [UIColor] = [accent, UIColor(red: 0.85, green: 0.7, blue: 0.35, alpha: 1),
                                         UIColor(red: 0.35, green: 0.55, blue: 0.8, alpha: 1), UIColor(white: 0.75, alpha: 1)]
                for (i, col) in colors.enumerated() {
                    c.setFillColor(col.cgColor)
                    c.fill(CGRect(x: 28 + CGFloat(i % 2) * 210, y: 28 + CGFloat(i / 2) * 120, width: 195, height: 105))
                }
            case .executive, .generic:
                c.setFillColor(accent.withAlphaComponent(0.9).cgColor)
                c.fill(CGRect(x: 185, y: 32, width: 90, height: 38))
                c.setStrokeColor(accent.withAlphaComponent(0.6).cgColor); c.setLineWidth(2.5)
                for i in 0..<3 {
                    let x = 70 + CGFloat(i) * 125
                    c.move(to: CGPoint(x: 230, y: 70)); c.addLine(to: CGPoint(x: x + 45, y: 150)); c.strokePath()
                    c.setFillColor(UIColor(white: 1, alpha: 0.15).cgColor)
                    c.fill(CGRect(x: x, y: 150, width: 90, height: 36))
                }
            }
        }
    }

    /// Night skyline for the executive window.
    private static func skylineMini() -> UIImage {
        let size = CGSize(width: 600, height: 470)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let sky = CGGradient(colorsSpace: space, colors: [
                UIColor(red: 0.03, green: 0.07, blue: 0.18, alpha: 1).cgColor,
                UIColor(red: 0.01, green: 0.02, blue: 0.06, alpha: 1).cgColor
            ] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

            var x: CGFloat = -8
            var k: UInt64 = 17
            func rnd() -> CGFloat { k = k &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((k >> 33) % 1000) / 1000 }
            while x < size.width {
                let w = 45 + rnd() * 70
                let h = 130 + rnd() * 270
                c.setFillColor(UIColor(red: 0.02 + rnd() * 0.012, green: 0.035, blue: 0.07, alpha: 1).cgColor)
                c.fill(CGRect(x: x, y: size.height - h, width: w, height: h))
                var wy = size.height - h + 10
                while wy < size.height - 12 {
                    var wx = x + 6
                    while wx < x + w - 8 {
                        if rnd() > 0.55 {
                            let warm = rnd() > 0.5
                            c.setFillColor((warm
                                ? UIColor(red: 1, green: 0.83, blue: 0.5, alpha: 0.85)
                                : UIColor(red: 0.5, green: 0.8, blue: 1, alpha: 0.85)).cgColor)
                            c.fill(CGRect(x: wx, y: wy, width: 5, height: 3.6))
                        }
                        wx += 12
                    }
                    wy += 10
                }
                x += w + 6 + rnd() * 18
            }
        }
    }

    /// Color swatch canvas for the design easel / marketing print.
    private static func swatchTexture(accent: UIColor) -> UIImage {
        let size = CGSize(width: 300, height: 240)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            UIColor(white: 0.92, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            let colors: [UIColor] = [accent, UIColor(red: 0.85, green: 0.7, blue: 0.35, alpha: 1),
                                     UIColor(red: 0.35, green: 0.55, blue: 0.8, alpha: 1),
                                     UIColor(red: 0.2, green: 0.3, blue: 0.25, alpha: 1)]
            for (i, col) in colors.enumerated() {
                c.setFillColor(col.cgColor)
                c.fill(CGRect(x: 22 + CGFloat(i % 2) * 135, y: 22 + CGFloat(i / 2) * 105, width: 120, height: 90))
            }
        }
    }

    /// Research whiteboard: scatter + a trend line, drawn on the board itself.
    private static func whiteboardTexture(accent: UIColor) -> UIImage {
        let size = CGSize(width: 460, height: 300)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            UIColor(white: 0.9, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            var seed: UInt64 = 41
            func rnd() -> CGFloat { seed = seed &* 2862933555777941757 &+ 3037000493; return CGFloat((seed >> 33) % 1000) / 1000 }
            for _ in 0..<18 {
                c.setFillColor(accent.withAlphaComponent(0.5 + rnd() * 0.4).cgColor)
                c.fillEllipse(in: CGRect(x: 40 + rnd() * 380, y: 40 + rnd() * 200, width: 11, height: 11))
            }
            c.setStrokeColor(UIColor(red: 0.2, green: 0.3, blue: 0.45, alpha: 0.8).cgColor)
            c.setLineWidth(4)
            c.move(to: CGPoint(x: 40, y: 240))
            c.addCurve(to: CGPoint(x: 420, y: 70),
                       control1: CGPoint(x: 180, y: 230), control2: CGPoint(x: 300, y: 120))
            c.strokePath()
        }
    }

    /// Tinted studio environment so PBR materials have something to reflect.
    private static func environmentMap() -> UIImage {
        let size = CGSize(width: 512, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let base = CGGradient(colorsSpace: space, colors: [
                UIColor(red: 0.06, green: 0.1, blue: 0.18, alpha: 1).cgColor,
                UIColor(red: 0.01, green: 0.015, blue: 0.035, alpha: 1).cgColor
            ] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            let blobs: [(CGFloat, CGFloat, CGFloat, UIColor)] = [
                (120, 55, 85, UIColor(red: 1.0, green: 0.85, blue: 0.6, alpha: 1)),
                (330, 60, 100, UIColor(red: 0.3, green: 0.65, blue: 0.8, alpha: 1)),
                (450, 85, 55, .white)
            ]
            for (x, y, r, col) in blobs {
                let g = CGGradient(colorsSpace: space, colors: [
                    col.withAlphaComponent(0.8).cgColor, col.withAlphaComponent(0).cgColor
                ] as CFArray, locations: [0, 1])!
                c.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                     endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
            }
        }
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
        let m = SCNMaterial(); m.diffuse.contents = color; m.emission.contents = color; m.lightingModel = .constant; return m
    }
    /// Calm an accent into a muted, premium tone (flat UI keeps the vivid hex).
    private static func muted(_ color: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        return UIColor(hue: h, saturation: s * 0.5, brightness: min(b, 0.7), alpha: a)
    }
}

private extension UIColor {
    convenience init(podHex: String) {
        let clean = podHex.replacingOccurrences(of: "#", with: "")
        let scanner = Scanner(string: clean)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
