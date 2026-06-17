import SceneKit
import SwiftUI
import UIKit

/// A 3D project room for one initiative — the centerpiece and mood reflect the
/// stage: a planning desk while it's researched/debated, scaffolding around a
/// core that grows with progress while it's built, a spotlit pedestal at Demo
/// Day, a shipped crate + trophy once it ships. Drag to orbit.
struct InitiativeRoomView: View {
    let initiative: CompanyInitiative
    @EnvironmentObject private var org: OrgStore
    @State private var selectedHotspot: InitiativeRoomHotspot?
    @State private var showSchedule = false
    @State private var showMemo = false

    private var accent: Color { Color(hex: InitiativeRoomScene.accentHex(initiative.stage)) }

    var body: some View {
        ZStack {
            InitiativeRoomSceneView(initiative: initiative) { hotspot in
                selectedHotspot = hotspot
            }
                .ignoresSafeArea()

            LinearGradient(colors: [.black.opacity(0.62), .clear, .black.opacity(0.78)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 14) {
                commandHeader
                Spacer(minLength: 0)
                objectCallouts
                commandDock
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .navigationTitle("Project Room")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedHotspot) { hotspot in
            InitiativeHotspotSheet(hotspot: hotspot, initiative: initiative)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSchedule) {
            ScheduleMeetingView(prefillTopic: "Feedback: \(initiative.title)")
        }
        .sheet(isPresented: $showMemo) {
            ComposeMemoView(prefillSubject: "Next steps: \(initiative.title)",
                            prefillRecipientID: org.ceo?.id)
        }
    }

    private var commandHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(initiative.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(initiative.projectPurpose)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    Text("\(Int(initiative.progress * 100))%")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                    Text("COMPLETE")
                        .font(.caption2.weight(.black))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.58))
                }
            }

            HStack(spacing: 8) {
                stagePill
                miniMetric("Lead", initiative.assignedLead)
            }

            ProgressView(value: initiative.progress)
                .tint(accent)

            HStack(alignment: .top, spacing: 10) {
                commandFact(title: "Latest decision", value: initiative.latestDecision)
                commandFact(title: "Next action", value: initiative.nextRequiredAction)
            }
        }
        .padding(14)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accent.opacity(0.34), lineWidth: 1)
        )
        .shadow(color: accent.opacity(0.18), radius: 24, y: 10)
    }

    private var stagePill: some View {
        Label(initiative.stageLabel, systemImage: initiative.stageIcon)
            .font(.caption2.weight(.black))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(accent.opacity(0.9), in: Capsule())
    }

    private func miniMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.48))
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private func commandFact(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.black))
                .tracking(0.6)
                .foregroundStyle(accent.opacity(0.9))
            Text(value)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var objectCallouts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tap the room objects")
                .font(.caption2.weight(.black))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.58))

            HStack(spacing: 8) {
                ForEach(initiative.visibleHotspots) { hotspot in
                    calloutButton(hotspot)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func calloutButton(_ hotspot: InitiativeRoomHotspot) -> some View {
        Button { selectedHotspot = hotspot } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: hotspot.icon)
                    .font(.caption.weight(.bold))
                Text(hotspot.objectLabel(for: initiative))
                    .font(.caption2.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .padding(10)
            .background(accent.opacity(hotspot == initiative.primaryHotspot ? 0.32 : 0.16),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(accent.opacity(hotspot == initiative.primaryHotspot ? 0.58 : 0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var commandDock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { selectedHotspot = .brief } label: {
                    dockButton("Brief", "doc.text.fill")
                }
                Button { showSchedule = true } label: {
                    dockButton("Meeting", "calendar.badge.plus")
                }
                Button { showMemo = true } label: {
                    dockButton("Memo", "envelope.fill")
                }
                Button { selectedHotspot = initiative.primaryHotspot } label: {
                    dockButton("Open", "arrow.up.forward.square.fill")
                }
            }

            if !initiative.artifacts.isEmpty || initiative.repoUrl != nil {
                Button { selectedHotspot = .launch } label: {
                    Label("View \(initiative.artifacts.count) deliverable\(initiative.artifacts.count == 1 ? "" : "s")",
                          systemImage: "shippingbox.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(accent.opacity(0.26), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
    }

    private func dockButton(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
            Text(title)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct InitiativeRoomSceneView: UIViewRepresentable {
    let initiative: CompanyInitiative
    var onHotspot: (InitiativeRoomHotspot) -> Void

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = InitiativeRoomScene.scene(for: initiative)
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 1)
        view.isPlaying = true
        view.rendersContinuously = true
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.onHotspot = onHotspot
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onHotspot: onHotspot)
    }

    final class Coordinator: NSObject {
        var onHotspot: (InitiativeRoomHotspot) -> Void

        init(onHotspot: @escaping (InitiativeRoomHotspot) -> Void) {
            self.onHotspot = onHotspot
        }

        @MainActor
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? SCNView else { return }
            let location = recognizer.location(in: view)
            guard let hit = view.hitTest(location, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]).first,
                  let hotspot = InitiativeRoomHotspot(node: hit.node) else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onHotspot(hotspot)
        }
    }
}

private enum InitiativeRoomHotspot: String, Identifiable, CaseIterable {
    case brief
    case notes
    case build
    case launch
    case archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief: return "Initiative Brief"
        case .notes: return "Research & Minutes"
        case .build: return "Build / QA Status"
        case .launch: return "Launch & Deliverables"
        case .archive: return "Archive Record"
        }
    }

    var icon: String {
        switch self {
        case .brief: return "lightbulb.max.fill"
        case .notes: return "note.text"
        case .build: return "hammer.fill"
        case .launch: return "shippingbox.fill"
        case .archive: return "archivebox.fill"
        }
    }

    init?(node: SCNNode) {
        var current: SCNNode? = node
        while let candidate = current {
            if let name = candidate.name, let hotspot = InitiativeRoomHotspot(rawValue: name) {
                self = hotspot
                return
            }
            current = candidate.parent
        }
        return nil
    }

    func objectLabel(for initiative: CompanyInitiative) -> String {
        switch self {
        case .brief:
            return initiative.stage == "killed" ? "Reason cube" : "Idea / Product core"
        case .notes:
            return "Desk / Notes board"
        case .build:
            return "Scaffold / QA gates"
        case .launch:
            return initiative.stage == "shipped" ? "Trophy / Launch links" : "Demo pedestal"
        case .archive:
            return "Archive cube"
        }
    }
}

private struct InitiativeHotspotSheet: View {
    let hotspot: InitiativeRoomHotspot
    let initiative: CompanyInitiative

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(hotspot.title, systemImage: hotspot.icon)
                            .font(.headline.weight(.bold))
                        Text(initiative.title)
                            .font(.subheadline.weight(.semibold))
                        Text(initiative.projectPurpose)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }

                switch hotspot {
                case .brief:
                    briefSections
                case .notes:
                    notesSections
                case .build:
                    buildSections
                case .launch:
                    launchSections
                case .archive:
                    archiveSections
                }
            }
            .navigationTitle(hotspot.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var briefSections: some View {
        Section("What this is") {
            detailRow("Stage", initiative.stageLabel, systemImage: initiative.stageIcon)
            detailRow("Progress", "\(Int(initiative.progress * 100))%", systemImage: "chart.line.uptrend.xyaxis")
            detailRow("Lead / team", initiative.assignedLead, systemImage: "person.3.fill")
        }

        Section("Purpose") {
            Text(initiative.projectPurpose)
                .font(.subheadline)
        }

        Section("Decision needed") {
            detailRow("Latest owner decision", initiative.latestDecision, systemImage: "checkmark.seal.fill")
            detailRow("Next required action", initiative.nextRequiredAction, systemImage: "arrow.forward.circle.fill")
        }

        if let score = initiative.score {
            Section("Investment read") {
                if let heat = score.heat { scoreRow("Market heat", heat) }
                if let fit = score.fit { scoreRow("Strategic fit", fit) }
                if let effort = score.effort { scoreRow("Effort", effort) }
                if let rationale = score.rationale, !rationale.isEmpty {
                    Text(rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var notesSections: some View {
        Section("Research / boardroom notes") {
            if !initiative.brief.isEmpty {
                Text(initiative.brief)
                    .font(.subheadline)
            } else if !initiative.pitch.isEmpty {
                Text(initiative.pitch)
                    .font(.subheadline)
            } else {
                Text("No research note has been written yet.")
                    .foregroundStyle(.secondary)
            }
        }

        if let minutes = initiative.minutes, !minutes.isEmpty {
            Section("Latest meeting minutes") {
                ForEach(minutes.suffix(6)) { minute in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(minute.role.uppercased())
                                .font(.caption.weight(.bold))
                                .foregroundStyle(HermesTheme.emerald)
                            Spacer()
                            Text(minute.stage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(minute.text)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
            }
        } else {
            Section("Meeting minutes") {
                Text("No minutes available for this initiative yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var buildSections: some View {
        Section("Build track") {
            detailRow("Current phase", initiative.buildPhase, systemImage: "hammer.fill")
            detailRow("QA status", initiative.qaStatus, systemImage: "checklist.checked")
            detailRow("Next build action", initiative.nextRequiredAction, systemImage: "arrow.forward.circle.fill")
        }

        Section("Operational gates") {
            ForEach(initiative.qaGates, id: \.0) { gate in
                Label(gate.0, systemImage: gate.1 ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(gate.1 ? .green : .secondary)
            }
        }

        if !initiative.artifacts.isEmpty {
            Section("Build outputs") {
                artifactRows
            }
        }
    }

    @ViewBuilder
    private var launchSections: some View {
        Section("Launch status") {
            detailRow("Status", initiative.launchStatus, systemImage: "paperplane.fill")
            detailRow("Next action", initiative.nextRequiredAction, systemImage: "arrow.forward.circle.fill")
        }

        if let repoUrl = initiative.repoUrl, !repoUrl.isEmpty {
            Section("Launch link") {
                Link(repoUrl, destination: URL(string: repoUrl) ?? URL(fileURLWithPath: "/"))
                    .font(.caption)
            }
        }

        Section("Deliverables / files") {
            if initiative.artifacts.isEmpty {
                Text("No deliverables are attached yet.")
                    .foregroundStyle(.secondary)
            } else {
                artifactRows
            }
        }
    }

    @ViewBuilder
    private var archiveSections: some View {
        Section("Archive reason") {
            Text(initiative.note.isEmpty ? initiative.latestDecision : initiative.note)
                .font(.subheadline)
        }

        Section("Lessons learned") {
            Text(initiative.brief.isEmpty ? "No lesson note was captured yet." : initiative.brief)
                .font(.subheadline)
        }
    }

    private var artifactRows: some View {
        ForEach(initiative.artifacts, id: \.self) { path in
            Label((path as NSString).lastPathComponent, systemImage: "doc.fill")
                .font(.caption)
        }
    }

    private func detailRow(_ title: String, _ value: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(HermesTheme.emerald)
        }
    }

    private func scoreRow(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.caption.monospacedDigit().weight(.bold))
            }
            ProgressView(value: min(max(value, 0), 1))
                .tint(HermesTheme.emerald)
        }
    }
}

private extension CompanyInitiative {
    var projectPurpose: String {
        let candidates = [pitch, brief, score?.rationale ?? ""]
        let source = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Move this initiative from idea to a clear owner decision."
        return source.oneSentenceFallback
    }

    var latestDecision: String {
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return note.oneSentenceFallback
        }
        if let minute = minutes?.last {
            return "\(minute.role): \(minute.text.oneSentenceFallback)"
        }
        switch stage {
        case "gate1": return "Awaiting your greenlight, revision, or kill decision."
        case "gate2": return "Awaiting your ship / revise / kill decision after Demo Day."
        case "killed": return "Killed before launch."
        case "shipped": return "Approved and shipped."
        default: return "No owner decision recorded yet."
        }
    }

    var nextRequiredAction: String {
        switch stage {
        case "research": return "Review the research notes when the team reaches boardroom debate."
        case "boardroom": return "Read the boardroom notes and prepare for the greenlight gate."
        case "gate1": return "Greenlight, revise, or kill this initiative."
        case "planning": return "Let the CEO turn the approved idea into an execution plan."
        case "execution": return "Track build progress and QA gate markers."
        case "demo_ready": return "Open the demo checklist and prepare your final call."
        case "gate2": return "Ship it, request revision, or kill it."
        case "shipped": return "Review launch links, repo, and deliverables."
        case "killed": return "Review the reason and lessons learned."
        default: return "Review the latest brief and decide the next move."
        }
    }

    var assignedLead: String {
        switch stage {
        case "research": return "Research"
        case "boardroom", "gate1": return "Boardroom"
        case "planning": return "CEO"
        case "execution", "demo_ready", "gate2": return "Builder + QA"
        case "shipped": return "Launch"
        case "killed": return "Archive"
        default: return origin == "owner" ? "Owner-led" : "Company team"
        }
    }

    var stageIcon: String {
        switch stage {
        case "research", "boardroom": return "lightbulb.max.fill"
        case "gate1", "gate2": return "person.crop.circle.badge.questionmark"
        case "planning": return "square.stack.3d.up.fill"
        case "execution": return "hammer.fill"
        case "demo_ready": return "play.rectangle.fill"
        case "shipped": return "shippingbox.fill"
        case "killed": return "archivebox.fill"
        default: return "cube.transparent"
        }
    }

    var primaryHotspot: InitiativeRoomHotspot {
        switch stage {
        case "planning", "execution", "demo_ready": return .build
        case "gate2", "shipped": return .launch
        case "killed": return .archive
        default: return .brief
        }
    }

    var visibleHotspots: [InitiativeRoomHotspot] {
        switch stage {
        case "research", "boardroom", "gate1":
            return [.brief, .notes, .build]
        case "planning", "execution", "demo_ready":
            return [.brief, .build, .notes]
        case "gate2", "shipped":
            return [.brief, .launch, .build]
        case "killed":
            return [.archive, .notes, .brief]
        default:
            return [.brief, .notes, .build]
        }
    }

    var buildPhase: String {
        switch stage {
        case "planning": return "Execution plan being drafted"
        case "execution": return "Build in progress"
        case "demo_ready": return "Demo checklist being prepared"
        case "gate2": return "Build complete; waiting for owner call"
        case "shipped": return "Released"
        case "killed": return "Stopped"
        default: return "Not in build phase yet"
        }
    }

    var qaStatus: String {
        switch stage {
        case "demo_ready", "gate2", "shipped": return "QA gate passed for demo review"
        case "execution": return "QA gate pending"
        case "planning": return "QA criteria being defined"
        case "killed": return "No active QA"
        default: return "QA starts after greenlight"
        }
    }

    var qaGates: [(String, Bool)] {
        [
            ("Brief accepted", progress >= 0.4 || isTerminal),
            ("Execution plan ready", progress >= 0.55 || isTerminal),
            ("Build complete", progress >= 0.85 || stage == "shipped"),
            ("Owner launch call", stage == "shipped")
        ]
    }

    var launchStatus: String {
        switch stage {
        case "shipped": return "Shipped and archived with launch artifacts"
        case "gate2": return "Demo complete; waiting for launch approval"
        case "demo_ready": return "Demo ready; checklist active"
        default: return "Not ready to launch yet"
        }
    }
}

private extension String {
    var oneSentenceFallback: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let separators = CharacterSet(charactersIn: ".!?\n")
        if let range = trimmed.rangeOfCharacter(from: separators) {
            let sentence = String(trimmed[..<range.upperBound])
            return sentence.count > 160 ? String(sentence.prefix(157)) + "..." : sentence
        }
        return trimmed.count > 160 ? String(trimmed.prefix(157)) + "..." : trimmed
    }
}

enum InitiativeRoomScene {

    static func accentHex(_ stage: String) -> String {
        switch stage {
        case "research", "boardroom":      return "3C6FA0"   // steel — thinking
        case "gate1", "demo_ready", "gate2": return "C7A35A" // gold — your call / showcase
        case "planning", "execution":      return "2E9B72"   // emerald — building
        case "shipped":                    return "1C7A55"   // deep emerald — done
        case "killed":                     return "6B7280"   // gray — dead
        default:                           return "3C6FA0"
        }
    }

    static func scene(for initiative: CompanyInitiative) -> SCNScene {
        let scene = SCNScene()
        let accent = uiColor(initiative.stage == "killed" ? "3A3F46" : accentHex(initiative.stage))

        addCamera(to: scene)
        addLights(to: scene, accent: accent, dim: initiative.stage == "killed")
        addRoom(to: scene, accent: accent)

        let centerpiece = buildCenterpiece(for: initiative, accent: accent)
        centerpiece.position = SCNVector3(0, 0, 0)
        // Slow, calm turntable so you see it from all sides.
        centerpiece.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 26)))
        scene.rootNode.addChildNode(centerpiece)

        return scene
    }

    // MARK: Camera & lighting

    private static func addCamera(to scene: SCNScene) {
        let camera = SCNCamera()
        camera.fieldOfView = 48
        camera.wantsHDR = true
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(2.6, 2.2, 3.4)
        let target = SCNNode()
        target.position = SCNVector3(0, 0.7, 0)
        scene.rootNode.addChildNode(target)
        node.constraints = [SCNLookAtConstraint(target: target)]
        scene.rootNode.addChildNode(node)
    }

    private static func addLights(to scene: SCNScene, accent: UIColor, dim: Bool) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = dim ? 120 : 280
        ambient.color = UIColor(white: 0.8, alpha: 1)
        let ambientNode = SCNNode(); ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // A key spotlight from above-front, tinted by the stage accent.
        let key = SCNLight()
        key.type = .spot
        key.intensity = dim ? 500 : 1500
        key.color = accent
        key.spotInnerAngle = 25
        key.spotOuterAngle = 70
        key.castsShadow = true
        let keyNode = SCNNode(); keyNode.light = key
        keyNode.position = SCNVector3(1.6, 4.2, 2.4)
        keyNode.constraints = [SCNLookAtConstraint(target: scene.rootNode)]
        scene.rootNode.addChildNode(keyNode)
    }

    private static func addRoom(to scene: SCNScene, accent: UIColor) {
        let floor = SCNNode(geometry: SCNBox(width: 8, height: 0.2, length: 8, chamferRadius: 0.05))
        floor.position = SCNVector3(0, -0.1, 0)
        floor.geometry?.firstMaterial = pbr(UIColor(red: 0.06, green: 0.08, blue: 0.11, alpha: 1),
                                            metalness: 0.5, roughness: 0.5)
        scene.rootNode.addChildNode(floor)

        // Two back walls forming a corner, with a faint accent wash.
        for (offset, angle) in [(SCNVector3(0, 2, -3.2), Float(0)),
                                (SCNVector3(-3.2, 2, 0), Float.pi / 2)] {
            let wall = SCNNode(geometry: SCNBox(width: 6.4, height: 4, length: 0.15, chamferRadius: 0))
            wall.position = offset
            wall.eulerAngles.y = angle
            let material = pbr(UIColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1),
                               metalness: 0.2, roughness: 0.8)
            material.emission.contents = accent.withAlphaComponent(0.06)
            wall.geometry?.firstMaterial = material
            scene.rootNode.addChildNode(wall)
        }
    }

    // MARK: Stage centerpieces

    private static func buildCenterpiece(for initiative: CompanyInitiative, accent: UIColor) -> SCNNode {
        switch initiative.stage {
        case "research", "boardroom", "gate1":
            return planningDesk(accent: accent)
        case "planning", "execution", "demo_ready":
            return construction(progress: Float(initiative.progress), accent: accent)
        case "gate2":
            return pedestal(accent: accent, glowing: true)
        case "shipped":
            return shipped(accent: accent)
        default:
            return deadCube()
        }
    }

    /// Research / debate — a desk with a whiteboard and a floating idea.
    private static func planningDesk(accent: UIColor) -> SCNNode {
        let root = SCNNode()
        let desk = SCNNode(geometry: SCNBox(width: 1.6, height: 0.1, length: 0.8, chamferRadius: 0.02))
        desk.name = InitiativeRoomHotspot.notes.rawValue
        desk.position = SCNVector3(0, 0.7, 0)
        desk.geometry?.firstMaterial = pbr(UIColor(white: 0.85, alpha: 1), metalness: 0.1, roughness: 0.4)
        root.addChildNode(desk)
        for x in [-0.7, 0.7] {
            for z in [-0.3, 0.3] {
                let leg = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 0.7))
                leg.name = InitiativeRoomHotspot.notes.rawValue
                leg.position = SCNVector3(Float(x), 0.35, Float(z))
                leg.geometry?.firstMaterial = pbr(UIColor(white: 0.2, alpha: 1), metalness: 0.7, roughness: 0.3)
                root.addChildNode(leg)
            }
        }
        // Whiteboard behind the desk.
        let board = SCNNode(geometry: SCNBox(width: 1.4, height: 0.9, length: 0.05, chamferRadius: 0.02))
        board.name = InitiativeRoomHotspot.notes.rawValue
        board.position = SCNVector3(0, 1.5, -0.5)
        let bm = pbr(UIColor(white: 0.95, alpha: 1), metalness: 0, roughness: 0.6)
        bm.emission.contents = accent.withAlphaComponent(0.10)
        board.geometry?.firstMaterial = bm
        root.addChildNode(board)

        for i in 0..<5 {
            let note = SCNNode(geometry: SCNBox(width: 0.18, height: 0.12, length: 0.015, chamferRadius: 0.005))
            note.name = InitiativeRoomHotspot.notes.rawValue
            note.position = SCNVector3(-0.45 + Float(i) * 0.22, 1.55 + Float(i % 2) * 0.16, -0.462)
            note.geometry?.firstMaterial = glow(i.isMultiple(of: 2) ? accent : UIColor(red: 0.82, green: 0.67, blue: 0.34, alpha: 1))
            root.addChildNode(note)
        }

        // A glowing idea hovering over the desk.
        let idea = SCNNode(geometry: SCNSphere(radius: 0.16))
        idea.name = InitiativeRoomHotspot.brief.rawValue
        idea.position = SCNVector3(0, 1.15, 0)
        idea.geometry?.firstMaterial = glow(accent)
        idea.runAction(.repeatForever(.sequence([
            .moveBy(x: 0, y: 0.08, z: 0, duration: 1.4),
            .moveBy(x: 0, y: -0.08, z: 0, duration: 1.4)])))
        root.addChildNode(idea)

        root.addChildNode(label("Brief", at: SCNVector3(0, 1.42, 0.24), color: accent))
        root.addChildNode(label("Notes", at: SCNVector3(0, 2.05, -0.45), color: accent))
        return root
    }

    /// Building — scaffolding around a core that grows with progress.
    private static func construction(progress: Float, accent: UIColor) -> SCNNode {
        let root = SCNNode()
        let height = max(0.3, min(1.8, progress * 2.0))
        let core = SCNNode(geometry: SCNBox(width: 1.0, height: CGFloat(height), length: 1.0, chamferRadius: 0.04))
        core.name = InitiativeRoomHotspot.build.rawValue
        core.position = SCNVector3(0, height / 2, 0)
        let cm = pbr(accent, metalness: 0.3, roughness: 0.4)
        cm.emission.contents = accent.withAlphaComponent(0.25)
        core.geometry?.firstMaterial = cm
        root.addChildNode(core)

        // Scaffold poles at the corners + a crossbeam — "under construction".
        let scaffoldMat = pbr(UIColor(red: 0.82, green: 0.67, blue: 0.34, alpha: 1), metalness: 0.8, roughness: 0.3)
        for x in [-0.7, 0.7] {
            for z in [-0.7, 0.7] {
                let pole = SCNNode(geometry: SCNCylinder(radius: 0.03, height: 2.0))
                pole.name = InitiativeRoomHotspot.build.rawValue
                pole.position = SCNVector3(Float(x), 1.0, Float(z))
                pole.geometry?.firstMaterial = scaffoldMat
                root.addChildNode(pole)
            }
        }
        let beam = SCNNode(geometry: SCNBox(width: 1.6, height: 0.05, length: 0.05, chamferRadius: 0))
        beam.name = InitiativeRoomHotspot.build.rawValue
        beam.position = SCNVector3(0, height + 0.15, 0.7)
        beam.geometry?.firstMaterial = scaffoldMat
        root.addChildNode(beam)

        for i in 0..<4 {
            let block = SCNNode(geometry: SCNBox(width: 0.34, height: 0.16, length: 0.24, chamferRadius: 0.02))
            block.name = InitiativeRoomHotspot.build.rawValue
            block.position = SCNVector3(-0.52 + Float(i) * 0.35, 0.18, -1.08)
            block.geometry?.firstMaterial = pbr(i < Int(progress * 4.0) ? accent : UIColor(white: 0.28, alpha: 1),
                                                metalness: 0.25, roughness: 0.42)
            root.addChildNode(block)
        }

        for i in 0..<3 {
            let marker = SCNNode(geometry: SCNSphere(radius: 0.055))
            marker.name = InitiativeRoomHotspot.build.rawValue
            marker.position = SCNVector3(0.9, 0.45 + Float(i) * 0.38, -0.82)
            marker.geometry?.firstMaterial = i < Int(progress * 3.4)
                ? glow(UIColor(red: 0.25, green: 0.92, blue: 0.62, alpha: 1))
                : pbr(UIColor(white: 0.3, alpha: 1), metalness: 0.2, roughness: 0.7)
            root.addChildNode(marker)
        }

        root.addChildNode(label("Build tasks", at: SCNVector3(0, 0.55, -1.12), color: accent))
        root.addChildNode(label("QA gates", at: SCNVector3(1.05, 1.75, -0.82), color: accent))
        return root
    }

    /// Demo Day — a glowing product cube on a spotlit pedestal.
    private static func pedestal(accent: UIColor, glowing: Bool) -> SCNNode {
        let root = SCNNode()
        let base = SCNNode(geometry: SCNCylinder(radius: 0.8, height: 0.4))
        base.name = InitiativeRoomHotspot.launch.rawValue
        base.position = SCNVector3(0, 0.2, 0)
        base.geometry?.firstMaterial = pbr(UIColor(white: 0.15, alpha: 1), metalness: 0.6, roughness: 0.3)
        root.addChildNode(base)
        let product = SCNNode(geometry: SCNBox(width: 0.7, height: 0.7, length: 0.7, chamferRadius: 0.06))
        product.name = InitiativeRoomHotspot.launch.rawValue
        product.position = SCNVector3(0, 0.95, 0)
        product.geometry?.firstMaterial = glowing ? glow(accent) : pbr(accent, metalness: 0.3, roughness: 0.3)
        product.runAction(.repeatForever(.sequence([
            .moveBy(x: 0, y: 0.1, z: 0, duration: 1.6),
            .moveBy(x: 0, y: -0.1, z: 0, duration: 1.6)])))
        root.addChildNode(product)

        for i in 0..<3 {
            let checklist = SCNNode(geometry: SCNBox(width: 0.12, height: 0.12, length: 0.03, chamferRadius: 0.01))
            checklist.name = InitiativeRoomHotspot.launch.rawValue
            checklist.position = SCNVector3(-0.28 + Float(i) * 0.28, 0.55, 0.92)
            checklist.geometry?.firstMaterial = glow(i < 2 ? accent : UIColor(red: 0.82, green: 0.67, blue: 0.34, alpha: 1))
            root.addChildNode(checklist)
        }

        root.addChildNode(label("Demo / Launch", at: SCNVector3(0, 1.58, 0), color: accent))
        return root
    }

    /// Shipped — a sealed crate with a trophy spire and a ring of confetti.
    private static func shipped(accent: UIColor) -> SCNNode {
        let root = SCNNode()
        let crate = SCNNode(geometry: SCNBox(width: 1.1, height: 1.1, length: 1.1, chamferRadius: 0.05))
        crate.name = InitiativeRoomHotspot.launch.rawValue
        crate.position = SCNVector3(0, 0.65, 0)
        crate.geometry?.firstMaterial = pbr(UIColor(red: 0.45, green: 0.32, blue: 0.18, alpha: 1),
                                            metalness: 0.1, roughness: 0.7)
        root.addChildNode(crate)
        // Trophy spire (cone) on top.
        let trophy = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.28, height: 0.7))
        trophy.name = InitiativeRoomHotspot.launch.rawValue
        trophy.position = SCNVector3(0, 1.55, 0)
        trophy.geometry?.firstMaterial = glow(UIColor(red: 0.82, green: 0.67, blue: 0.34, alpha: 1))
        root.addChildNode(trophy)
        // A ring of small glowing confetti dots.
        for i in 0..<12 {
            let angle = Float(i) / 12 * .pi * 2
            let dot = SCNNode(geometry: SCNSphere(radius: 0.05))
            dot.name = InitiativeRoomHotspot.launch.rawValue
            dot.position = SCNVector3(cos(angle) * 1.3, 1.7, sin(angle) * 1.3)
            dot.geometry?.firstMaterial = glow(accent)
            root.addChildNode(dot)
        }
        root.addChildNode(label("Launch artifacts", at: SCNVector3(0, 2.15, 0), color: accent))
        return root
    }

    private static func deadCube() -> SCNNode {
        let node = SCNNode(geometry: SCNBox(width: 0.9, height: 0.9, length: 0.9, chamferRadius: 0.04))
        node.name = InitiativeRoomHotspot.archive.rawValue
        node.position = SCNVector3(0, 0.5, 0)
        node.geometry?.firstMaterial = pbr(UIColor(white: 0.22, alpha: 1), metalness: 0.2, roughness: 0.9)
        let root = SCNNode()
        root.addChildNode(node)
        root.addChildNode(label("Archive", at: SCNVector3(0, 1.2, 0), color: UIColor(white: 0.72, alpha: 1)))
        return root
    }

    private static func label(_ text: String, at position: SCNVector3, color: UIColor) -> SCNNode {
        let textGeometry = SCNText(string: text, extrusionDepth: 0.006)
        textGeometry.font = .systemFont(ofSize: 0.16, weight: .bold)
        textGeometry.flatness = 0.2
        textGeometry.firstMaterial = glow(color)
        let node = SCNNode(geometry: textGeometry)
        node.position = position
        node.scale = SCNVector3(0.7, 0.7, 0.7)

        let min = node.boundingBox.min
        let max = node.boundingBox.max
        node.pivot = SCNMatrix4MakeTranslation((max.x - min.x) / 2 + min.x, 0, 0)

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = [.Y]
        node.constraints = [billboard]
        return node
    }

    // MARK: Materials

    private static func pbr(_ color: UIColor, metalness: CGFloat, roughness: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metalness
        m.roughness.contents = roughness
        return m
    }

    private static func glow(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.emission.contents = color
        m.metalness.contents = 0.1
        m.roughness.contents = 0.3
        return m
    }

    private static func uiColor(_ hex: String) -> UIColor {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
