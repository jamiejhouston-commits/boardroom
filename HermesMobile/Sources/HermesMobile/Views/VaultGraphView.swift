import SceneKit
import simd
import SwiftUI
import UIKit

// MARK: - Obsidian deep link (opens the real note in the Obsidian app)

private func obsidianDeepLink(node: VaultNode, vault: String?) -> URL? {
    guard let vault else { return nil }
    let file: String
    if node.id.hasPrefix("obsidian:") {
        file = String(node.id.dropFirst("obsidian:".count)) + ".md"
    } else if node.id.hasPrefix("canvas:") {
        file = String(node.id.dropFirst("canvas:".count)) + ".canvas"
    } else {
        return nil
    }
    var components = URLComponents()
    components.scheme = "obsidian"
    components.host = "open"
    components.queryItems = [URLQueryItem(name: "vault", value: vault),
                             URLQueryItem(name: "file", value: file)]
    return components.url
}

// MARK: - SceneKit renderer — rebuilds only when the graph or settings change;
// focus is applied in place so the user's camera never resets.

struct VaultGraphSceneView: UIViewRepresentable {
    let graph: VaultGraph
    let settings: GraphSettings
    let focusedID: String?
    var onSelect: (VaultNode?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = VaultBrainPalette.background
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        context.coordinator.onSelect = onSelect
        context.coordinator.rebuildIfNeeded(view: view, graph: graph, settings: settings)
        context.coordinator.applyFocus(focusedID)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.rebuildIfNeeded(view: uiView, graph: graph, settings: settings)
        context.coordinator.applyFocus(focusedID)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onSelect: (VaultNode?) -> Void = { _ in }
        private var handles: BrainSceneHandles?
        private var lastGraph: VaultGraph?
        private var lastSettings: GraphSettings?
        private var focusedID: String?
        private var focusGroup: SCNNode?

        func rebuildIfNeeded(view: SCNView, graph: VaultGraph, settings: GraphSettings) {
            guard handles == nil || lastGraph != graph || lastSettings != settings else { return }
            lastGraph = graph
            lastSettings = settings
            let built = VaultBrainScene.build(graph: graph, settings: settings)
            handles = built
            focusedID = nil
            focusGroup = nil
            view.scene = built.scene
        }

        func applyFocus(_ id: String?) {
            guard focusedID != id, let h = handles else { return }
            focusedID = id
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.35
            focusGroup?.removeFromParentNode()
            focusGroup = nil

            if let id, let center = h.positions[id] {
                let hood = (h.adjacency[id] ?? []).union([id])
                for (nid, node) in h.nodeHandles {
                    node.opacity = hood.contains(nid) ? (h.baseOpacity[nid] ?? 1) : 0.08
                }
                h.webNode?.opacity = 0.12
                h.emphasisNode?.opacity = 0.15
                h.captionsNode?.opacity = 0.2

                let group = SCNNode()
                let neighbors = (h.adjacency[id] ?? []).sorted {
                    let l = h.adjacency[$0]?.count ?? 0
                    let r = h.adjacency[$1]?.count ?? 0
                    return l != r ? l > r : $0 < $1
                }
                for nid in neighbors.prefix(40) {
                    guard let p = h.positions[nid] else { continue }
                    group.addChildNode(VaultBrainScene.link(from: center, to: p,
                                                            radius: 0.016,
                                                            color: VaultBrainPalette.focusGold,
                                                            alpha: 0.45))
                }
                var placed = 0
                for nid in neighbors where placed < 16 {
                    guard !h.labeledIDs.contains(nid),
                          let p = h.positions[nid],
                          let neighbor = h.nodesByID[nid] else { continue }
                    let label = VaultBrainScene.labelNode(text: neighbor.label,
                                                          emphasis: false, billboarded: true)
                    // Alternate above/below so near neighbours don't collide.
                    label.simdPosition = p + SIMD3(0, placed.isMultiple(of: 2) ? -0.28 : 0.30, 0.05)
                    group.addChildNode(label)
                    placed += 1
                }
                h.spinRoot.addChildNode(group)
                focusGroup = group
                h.spinRoot.isPaused = true   // hold the constellation still while reading
            } else {
                for (nid, node) in h.nodeHandles { node.opacity = h.baseOpacity[nid] ?? 1 }
                h.webNode?.opacity = 1
                h.emphasisNode?.opacity = 1
                h.captionsNode?.opacity = 1
                h.spinRoot.isPaused = false
            }
            SCNTransaction.commit()
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? SCNView else { return }
            let point = recognizer.location(in: view)
            if let hit = view.hitTest(point, options: [.boundingBoxOnly: false]).first {
                var current: SCNNode? = hit.node
                while let node = current {
                    if let name = node.name, name.hasPrefix("vault-node:") {
                        let id = String(name.dropFirst("vault-node:".count))
                        if let selected = handles?.nodesByID[id] {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onSelect(selected)
                        }
                        return
                    }
                    current = node.parent
                }
            }
            onSelect(nil)   // empty space — release the focus
        }
    }
}

// MARK: - Detail sheet: the note itself, plus hop-through navigation

private struct VaultNodeDetailSheet: View {
    @EnvironmentObject private var runtime: HermesRuntimeController
    let graph: VaultGraph
    @State var node: VaultNode

    @State private var note: VaultNoteContent?
    @State private var noteError: String?
    @State private var loadingNote = false

    private var family: String { VaultBrainPalette.family(node) }
    private var degree: Int {
        graph.edges.reduce(into: 0) { total, edge in
            if edge.source == node.id || edge.target == node.id { total += 1 }
        }
    }
    private var neighbors: [VaultNode] {
        var ids = Set<String>()
        for edge in graph.edges {
            if edge.source == node.id { ids.insert(edge.target) }
            if edge.target == node.id { ids.insert(edge.source) }
        }
        ids.remove(node.id)
        return graph.nodes.filter { ids.contains($0.id) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
    private var hasBody: Bool {
        node.type != "agent" && node.type != "canvas" && node.phantom != true
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color(VaultBrainPalette.familyColor(family)).opacity(0.18))
                                .frame(width: 54, height: 54)
                            Image(systemName: icon)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color(VaultBrainPalette.familyColor(family)))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.label.isEmpty ? node.id : node.label)
                                .font(.headline)
                                .foregroundStyle(HermesTheme.textPrimary)
                            Text(typeLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // The note itself — the second brain, readable in place.
                if hasBody {
                    Section("Note") {
                        if let note {
                            Text(LocalizedStringKey(note.content))
                                .font(.subheadline)
                                .textSelection(.enabled)
                        } else if loadingNote {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Opening the note…").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(noteError ?? "This note isn't readable from the relay yet.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if node.phantom == true {
                    Section("Note") {
                        Text("Unresolved link — a note this name points to hasn't been written yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if node.type == "canvas" {
                    Section("Note") {
                        Text("A visual canvas board — open it in Obsidian to see the full layout.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !neighbors.isEmpty {
                    Section("Linked notes") {
                        ForEach(neighbors.prefix(20)) { neighbor in
                            Button {
                                node = neighbor
                                note = nil
                                noteError = nil
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(Color(VaultBrainPalette.familyColor(VaultBrainPalette.family(neighbor))))
                                        .frame(width: 8, height: 8)
                                    Text(neighbor.label.isEmpty ? neighbor.id : neighbor.label)
                                        .foregroundStyle(HermesTheme.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        if neighbors.count > 20 {
                            Text("+ \(neighbors.count - 20) more")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Details") {
                    LabeledContent("Connections", value: "\(degree)")
                    LabeledContent("Collection", value: family)
                    if let modified = node.modified {
                        LabeledContent("Modified") {
                            Text(Date(timeIntervalSince1970: modified),
                                 format: .dateTime.day().month().year())
                        }
                    }
                    if let words = node.words, words > 0 {
                        LabeledContent("Words", value: "\(words)")
                    }
                    if let tags = node.tags, !tags.isEmpty {
                        LabeledContent("Tags", value: tags.map { "#\($0)" }.joined(separator: "  "))
                    }
                }

                if let url = obsidianDeepLink(node: node, vault: graph.vault) {
                    Section {
                        Link(destination: url) {
                            Label("Open in Obsidian", systemImage: "arrow.up.forward.app")
                        }
                    }
                }
            }
            .navigationTitle("Graph Node")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: node.id) { await loadNote() }
        }
    }

    private func loadNote() async {
        guard hasBody, runtime.relayConfiguration.isConfigured else { return }
        loadingNote = true
        defer { loadingNote = false }
        do {
            note = try await HermesRelayClient(configuration: runtime.relayConfiguration)
                .companyVaultNote(id: node.id)
        } catch {
            noteError = error.localizedDescription
        }
    }

    private var typeLabel: String {
        switch node.type {
        case "agent": return "Agent"
        case "meeting": return "Meeting"
        case "decision": return "Decision"
        case "note": return "Note"
        case "obsidian": return node.phantom == true ? "Unresolved Link" : "Obsidian Note"
        case "canvas": return "Canvas Board"
        default: return node.type.capitalized
        }
    }

    private var icon: String {
        switch node.type {
        case "agent": return "person.crop.circle.badge.checkmark"
        case "meeting": return "person.3.fill"
        case "decision": return "checkmark.seal.fill"
        case "obsidian": return node.phantom == true ? "questionmark.circle.dashed" : "book.closed.fill"
        case "canvas": return "rectangle.3.group.fill"
        default: return "doc.text.fill"
        }
    }
}

// MARK: - Screen

struct VaultGraphView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController
    @State private var graph: VaultGraph = .empty
    @State private var settings = GraphSettings()
    @State private var loading = true
    @State private var error: String?
    @State private var showControls = false
    @State private var selectedNode: VaultNode?
    @State private var focusedNode: VaultNode?
    @State private var searchText = ""
    @State private var hiddenFamilies: Set<String> = []
    @State private var clusterCount = 0

    private var families: [(name: String, count: Int)] {
        var counts = [String: Int]()
        for node in graph.nodes { counts[VaultBrainPalette.family(node), default: 0] += 1 }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (name: $0.key, count: $0.value) }
    }

    /// Chips hide whole collections; search narrows to matches plus their
    /// direct neighbours — the Obsidian "local graph" behaviour.
    private var visibleGraph: VaultGraph {
        var nodes = graph.nodes
        if !hiddenFamilies.isEmpty {
            nodes = nodes.filter { !hiddenFamilies.contains(VaultBrainPalette.family($0)) }
        }
        var kept = Set(nodes.map(\.id))
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            let matched = Set(nodes.filter {
                $0.label.lowercased().contains(query) || $0.id.lowercased().contains(query)
            }.map(\.id))
            guard !matched.isEmpty else { return VaultGraph(nodes: [], edges: [], vault: graph.vault) }
            var expanded = matched
            for edge in graph.edges where matched.contains(edge.source) || matched.contains(edge.target) {
                expanded.insert(edge.source)
                expanded.insert(edge.target)
            }
            kept.formIntersection(expanded)
        }
        return VaultGraph(
            nodes: nodes.filter { kept.contains($0.id) },
            edges: graph.edges.filter { kept.contains($0.source) && kept.contains($0.target) },
            vault: graph.vault
        )
    }

    var body: some View {
        ZStack {
            Color(VaultBrainPalette.background).ignoresSafeArea()

            if !visibleGraph.nodes.isEmpty {
                VaultGraphSceneView(graph: visibleGraph,
                                    settings: settings,
                                    focusedID: focusedNode?.id) { node in
                    if let node {
                        if focusedNode?.id == node.id {
                            selectedNode = node          // second tap — open the note
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) { focusedNode = node }
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) { focusedNode = nil }
                    }
                }
                .ignoresSafeArea()
            } else if !graph.nodes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(HermesTheme.emerald)
                    Text("No notes match “\(searchText)”.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
            } else {
                VStack(spacing: 12) {
                    if loading {
                        ProgressView().tint(HermesTheme.emerald)
                        Text("Building your knowledge graph…").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    } else {
                        Image(systemName: "circle.hexagonpath").font(.largeTitle).foregroundStyle(HermesTheme.emerald)
                        Text(error ?? "Nothing in the vault yet — hold a meeting and it'll appear here.")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center).padding(.horizontal, 30)
                    }
                }
            }

            VStack(spacing: 10) {
                if families.count > 1 { familyChips }
                Spacer()
                if let focused = focusedNode { focusCard(focused) }
                statsBar
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Knowledge Graph")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search your second brain")
        .onChange(of: searchText) { _, _ in focusedNode = nil }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("", selection: $settings.threeD) { Text("3D").tag(true); Text("2D").tag(false) }
                    .pickerStyle(.segmented).frame(width: 96)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showControls = true } label: { Image(systemName: "slider.horizontal.3") }
            }
        }
        .sheet(isPresented: $showControls) { controls }
        .sheet(item: $selectedNode) { node in
            VaultNodeDetailSheet(graph: graph, node: node)
                .presentationDetents([.medium, .large])
        }
        .task { await load() }
    }

    // MARK: overlays

    private var familyChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(families, id: \.name) { family in
                    let hidden = hiddenFamilies.contains(family.name)
                    let tint = Color(VaultBrainPalette.familyColor(family.name))
                    Button {
                        if hidden {
                            hiddenFamilies.remove(family.name)
                        } else {
                            hiddenFamilies.insert(family.name)
                        }
                        focusedNode = nil
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(tint).frame(width: 8, height: 8)
                            Text(family.name).font(.caption.weight(.semibold))
                            Text("\(family.count)").font(.caption2).foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(hidden ? 0.25 : 0.45), in: Capsule())
                        .overlay(Capsule().strokeBorder(tint.opacity(hidden ? 0.15 : 0.5), lineWidth: 1))
                        .opacity(hidden ? 0.45 : 1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal)
        }
    }

    private var statsBar: some View {
        HStack {
            Text(statsText)
            Spacer()
            Text("drag · pinch · tap to focus")
        }
        .font(.caption2).foregroundStyle(.white.opacity(0.55))
        .padding(10)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    private var statsText: String {
        var text = "\(visibleGraph.nodes.count) notes · \(visibleGraph.edges.count) links"
        if clusterCount > 1 { text += " · \(clusterCount) clusters" }
        return text
    }

    private func focusCard(_ node: VaultNode) -> some View {
        let family = VaultBrainPalette.family(node)
        let tint = Color(VaultBrainPalette.familyColor(family))
        let degree = graph.edges.reduce(into: 0) { total, edge in
            if edge.source == node.id || edge.target == node.id { total += 1 }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 10, height: 10)
                Text(node.label.isEmpty ? node.id : node.label)
                    .font(.headline).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { focusedNode = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            HStack(spacing: 12) {
                Text(family)
                Text("\(degree) links")
                if let modified = node.modified {
                    Text(Date(timeIntervalSince1970: modified), style: .relative) + Text(" ago")
                }
                if node.phantom == true { Text("unresolved").italic() }
            }
            .font(.caption).foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 10) {
                Button {
                    selectedNode = node
                } label: {
                    Label("Read note", systemImage: "book.fill").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(HermesTheme.emerald)
                if let url = obsidianDeepLink(node: node, vault: graph.vault) {
                    Link(destination: url) {
                        Label("Obsidian", systemImage: "arrow.up.forward.app").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.7))
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: controls

    private var controls: some View {
        NavigationStack {
            Form {
                Section("Motion") { slider("Rotation speed", $settings.rotationSpeed, 0...2) }
                Section("Nodes & links") {
                    slider("Node size", $settings.nodeSize, 0.2...1.0)
                    slider("Link thickness", $settings.linkThickness, 0.004...0.06)
                    Toggle("Glow", isOn: $settings.glow).tint(HermesTheme.emerald)
                    Toggle("Paint by recency", isOn: $settings.recency).tint(HermesTheme.emerald)
                }
                Section("Forces") {
                    slider("Center force", $settings.centerForce, 0...0.2)
                    slider("Repel force", $settings.repelForce, 0.3...4)
                    slider("Link force", $settings.linkForce, 0...1.5)
                    slider("Link distance", $settings.linkDistance, 1...6)
                }
            }
            .navigationTitle("Graph Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showControls = false } } }
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range).tint(HermesTheme.emerald)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard runtime.relayConfiguration.isConfigured else {
            error = "Connect your relay first (Settings → Mac Relay)."
            return
        }
        do {
            graph = try await HermesRelayClient(configuration: runtime.relayConfiguration).companyVaultGraph()
            error = graph.nodes.isEmpty ? "Nothing in the vault yet — hold a meeting and it'll appear here." : nil
            focusedNode = nil
            clusterCount = GraphLayout.communityCount(graph)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
