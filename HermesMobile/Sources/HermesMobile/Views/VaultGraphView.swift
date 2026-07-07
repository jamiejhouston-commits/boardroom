import SceneKit
import simd
import SwiftUI
import UIKit

// MARK: - Graph data (from the relay's /company/vault/graph)

struct VaultGraph: Codable, Equatable {
    var nodes: [VaultNode]
    var edges: [VaultEdge]
    static let empty = VaultGraph(nodes: [], edges: [])
}

struct VaultNode: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var type: String   // agent | meeting | decision | note
}

struct VaultEdge: Codable, Equatable {
    var source: String
    var target: String
}

/// Mirrors Obsidian's graph controls.
struct GraphSettings: Equatable {
    var threeD = true
    var rotationSpeed = 0.7
    var nodeSize = 0.5
    var centerForce = 0.05
    var repelForce = 1.8
    var linkForce = 0.45
    var linkDistance = 3.0
    var linkThickness = 0.016
    var glow = true
    var arrows = false
}

// MARK: - Force-directed layout (3D sphere, or flat 2D)

enum GraphLayout {
    static func positions(_ graph: VaultGraph, _ s: GraphSettings, iterations: Int = 70) -> [String: SIMD3<Float>] {
        let ids = orderedIDs(graph)
        guard !ids.isEmpty else { return [:] }
        if !s.threeD { return solar(graph) }
        // O(n²) per iteration — with an Obsidian vault merged in the node
        // count can hit several hundred, so trade layout polish for frames.
        let iterations = ids.count > 200 ? 24 : ids.count > 120 ? 40 : iterations

        // Seed evenly over a sphere, then keep every node pinned to the shell.
        // This makes 3D mode read as a real knowledge ball instead of a flat web.
        let radius: Float = ids.count > 80 ? 4.15 : 3.85
        var pos = [String: SIMD3<Float>]()
        let count = Float(ids.count)
        for (i, id) in ids.enumerated() {
            let k = Float(i) + 0.5
            let phi = acos(1 - 2 * k / count)
            let theta = Float.pi * (1 + sqrt(5)) * k
            pos[id] = SIMD3(radius * sin(phi) * cos(theta),
                            radius * sin(phi) * sin(theta),
                            radius * cos(phi))
        }

        let edges = graph.edges.filter { pos[$0.source] != nil && pos[$0.target] != nil }
        let repel = Float(s.repelForce), linkF = Float(s.linkForce)
        for _ in 0..<iterations {
            var disp = [String: SIMD3<Float>]()
            for id in ids { disp[id] = .zero }
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let d = pos[ids[i]]! - pos[ids[j]]!
                    let dist = max(length(d), 0.05)
                    let push = (d / dist) * (repel / (dist * dist))
                    disp[ids[i]]! += push
                    disp[ids[j]]! -= push
                }
            }
            for e in edges {
                let d = pos[e.target]! - pos[e.source]!
                let dist = max(length(d), 0.05)
                let pull = (d / dist) * ((dist - 1.6) * linkF)
                disp[e.source]! += pull
                disp[e.target]! -= pull
            }
            for id in ids {
                let p = pos[id]! + disp[id]! * 0.016
                pos[id] = p / max(length(p), 0.001) * radius
            }
        }
        return pos
    }

    /// Obsidian-style "Solar" 2D layout: the most-connected note sits at the
    /// centre, its busiest neighbours on an inner ring, everyone else on an
    /// outer ring — evenly spaced, no overlap.
    static func solar(_ graph: VaultGraph) -> [String: SIMD3<Float>] {
        let deg = degreeMap(graph)
        let sorted = graph.nodes.sorted {
            if $0.type == "agent", $1.type != "agent" { return true }
            if $1.type == "agent", $0.type != "agent" { return false }
            return (deg[$0.id] ?? 0) > (deg[$1.id] ?? 0)
        }
        guard let hub = sorted.first else { return [:] }

        var pos = [String: SIMD3<Float>]()
        pos[hub.id] = SIMD3(0, 0, 0)
        let rest = Array(sorted.dropFirst())
        let ringCounts = [min(rest.count, 8), min(max(rest.count - 8, 0), 18), max(rest.count - 26, 0)]
        let radii: [Float] = rest.count > 70 ? [1.75, 3.3, 4.75] : [1.9, 3.45, 4.65]
        var cursor = 0
        for ring in 0..<ringCounts.count {
            let count = ringCounts[ring]
            guard count > 0 else { continue }
            let radius = radii[ring]
            let phase = Float(ring) * 0.31
            for slot in 0..<count {
                let node = rest[cursor]
                let a = (Float(slot) / Float(count)) * 2 * .pi + phase
                // A subtle ellipse leaves room for readable labels on iPhone.
                pos[node.id] = SIMD3(cos(a) * radius, sin(a) * radius * 0.86, 0)
                cursor += 1
            }
        }
        return pos
    }

    private static func orderedIDs(_ graph: VaultGraph) -> [String] {
        let deg = degreeMap(graph)
        return graph.nodes.sorted {
            if $0.type == "agent", $1.type != "agent" { return true }
            if $1.type == "agent", $0.type != "agent" { return false }
            return (deg[$0.id] ?? 0) > (deg[$1.id] ?? 0)
        }.map(\.id)
    }

    private static func degreeMap(_ graph: VaultGraph) -> [String: Int] {
        var deg = [String: Int]()
        for e in graph.edges {
            deg[e.source, default: 0] += 1
            deg[e.target, default: 0] += 1
        }
        return deg
    }
}

private struct VaultNodeDetailSheet: View {
    @EnvironmentObject private var runtime: HermesRuntimeController
    let node: VaultNode
    let degree: Int

    @State private var note: VaultNoteContent?
    @State private var noteError: String?
    @State private var loadingNote = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(accent.opacity(0.18))
                                .frame(width: 54, height: 54)
                            Image(systemName: icon)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(accent)
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
                if node.type != "agent" {
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
                }

                Section("Graph position") {
                    LabeledContent("Connections", value: "\(degree)")
                    LabeledContent("Node ID", value: node.id)
                    LabeledContent("Type", value: typeLabel)
                }
            }
            .navigationTitle("Graph Node")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadNote() }
        }
    }

    private func loadNote() async {
        guard node.type != "agent", runtime.relayConfiguration.isConfigured else { return }
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
        case "obsidian": return "Obsidian Note"
        default: return node.type.capitalized
        }
    }

    private var icon: String {
        switch node.type {
        case "agent": return "person.crop.circle.badge.checkmark"
        case "meeting": return "person.3.fill"
        case "decision": return "checkmark.seal.fill"
        case "obsidian": return "book.closed.fill"
        default: return "doc.text.fill"
        }
    }

    private var accent: Color {
        switch node.type {
        case "agent": return HermesTheme.gold
        case "meeting": return .cyan
        case "decision": return HermesTheme.emerald
        case "obsidian": return Color(red: 0.62, green: 0.54, blue: 0.92)
        default: return .blue
        }
    }
}

// MARK: - SceneKit renderer — 3D knowledge ball + 2D solar map

struct VaultGraphSceneView: UIViewRepresentable {
    let graph: VaultGraph
    let settings: GraphSettings
    var onSelect: (VaultNode) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = UIColor(red: 0.02, green: 0.035, blue: 0.06, alpha: 1)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        context.coordinator.attach(graph: graph, onSelect: onSelect)
        rebuild(view)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.attach(graph: graph, onSelect: onSelect)
        rebuild(uiView)
    }

    private func rebuild(_ view: SCNView) {
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.02, green: 0.035, blue: 0.06, alpha: 1)

        let camNode = SCNNode()
        let cam = SCNCamera()
        cam.fieldOfView = settings.threeD ? 48 : 43
        cam.wantsHDR = true
        cam.bloomIntensity = settings.glow ? 1.15 : 0
        cam.bloomThreshold = 0.30
        cam.bloomBlurRadius = 13
        cam.wantsExposureAdaptation = false
        cam.zFar = 240
        camNode.camera = cam
        camNode.position = SCNVector3(0, 0, settings.threeD ? 12.2 : 12.8)
        camNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 620
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let keyLight = SCNLight()
        keyLight.type = .omni
        keyLight.intensity = 760
        keyLight.color = UIColor(red: 0.34, green: 0.95, blue: 0.88, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.position = SCNVector3(-2.8, 3.5, 5.0)
        scene.rootNode.addChildNode(keyNode)

        let root = SCNNode()
        scene.rootNode.addChildNode(root)

        let pos = GraphLayout.positions(graph, settings)
        let degree = Self.degreeMap(graph)
        let maxDeg = max(degree.values.max() ?? 1, 1)
        let keyIds = Self.keyIDs(graph, degree: degree, count: settings.threeD ? 6 : 9)

        Self.addBackdrop(to: root, threeD: settings.threeD, nodeCount: graph.nodes.count)

        for edge in Self.visibleEdges(graph, degree: degree, keyIds: keyIds, threeD: settings.threeD) {
            guard let a = pos[edge.source], let b = pos[edge.target] else { continue }
            root.addChildNode(
                Self.link(
                    from: a,
                    to: b,
                    radius: CGFloat(settings.linkThickness),
                    emphasized: keyIds.contains(edge.source) || keyIds.contains(edge.target),
                    threeD: settings.threeD
                )
            )
        }

        for node in graph.nodes {
            guard let p = pos[node.id] else { continue }
            let deg = degree[node.id] ?? 0
            let key = keyIds.contains(node.id)
            let color = Self.color(node.type)
            let base = CGFloat(settings.nodeSize)
            let degF = CGFloat(deg) / CGFloat(maxDeg)
            let width: CGFloat = if settings.threeD {
                key ? base * (1.55 + degF * 0.45) : base * (0.78 + degF * 0.28)
            } else {
                key ? base * (1.75 + degF * 0.52) : base * (0.82 + degF * 0.24)
            }

            let tex = Self.nodeTexture(color: color, initials: Self.initials(node), key: key, threeD: settings.threeD)
            let plane = Self.billboardPlane(texture: tex, width: width, height: width, glow: settings.glow, writesDepth: true)
            plane.position = SCNVector3(p.x, p.y, p.z)
            plane.name = "vault-node:\(node.id)"
            root.addChildNode(plane)

            if key && !node.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let labelWidth = min(max(CGFloat(node.label.count) * 0.13, 1.15), settings.threeD ? 2.6 : 3.1)
                let label = Self.billboardPlane(texture: Self.labelTexture(node.label),
                                                width: labelWidth,
                                                height: labelWidth * 0.21,
                                                glow: false,
                                                writesDepth: false)
                let verticalOffset = Float(settings.threeD ? width * 0.72 : width * 0.86)
                label.position = SCNVector3(p.x, p.y - verticalOffset, p.z + (settings.threeD ? 0.04 : 0.08))
                root.addChildNode(label)
            }
        }

        if settings.rotationSpeed > 0.001 {
            let duration = max(5.0, 42.0 / settings.rotationSpeed)
            let y: CGFloat = settings.threeD ? .pi * 2 : 0
            let z: CGFloat = settings.threeD ? 0 : .pi * 2
            root.runAction(.repeatForever(.rotateBy(x: 0, y: y, z: z, duration: duration)))
        }

        view.scene = scene
    }

    @MainActor
    final class Coordinator: NSObject {
        private var nodesByID: [String: VaultNode] = [:]
        private var onSelect: (VaultNode) -> Void = { _ in }

        func attach(graph: VaultGraph, onSelect: @escaping (VaultNode) -> Void) {
            nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
            self.onSelect = onSelect
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? SCNView else { return }
            let point = recognizer.location(in: view)
            guard let hit = view.hitTest(point, options: [.boundingBoxOnly: false]).first else { return }
            var current: SCNNode? = hit.node
            while let node = current {
                if let name = node.name, name.hasPrefix("vault-node:") {
                    let id = String(name.dropFirst("vault-node:".count))
                    if let selected = nodesByID[id] {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onSelect(selected)
                    }
                    return
                }
                current = node.parent
            }
        }
    }

    // MARK: pieces

    private static func degreeMap(_ graph: VaultGraph) -> [String: Int] {
        var d = [String: Int]()
        for edge in graph.edges {
            d[edge.source, default: 0] += 1
            d[edge.target, default: 0] += 1
        }
        return d
    }

    private static func keyIDs(_ graph: VaultGraph, degree: [String: Int], count: Int) -> Set<String> {
        let agents = graph.nodes.filter { $0.type == "agent" }.map(\.id)
        let busiest = graph.nodes.sorted {
            if $0.type == "agent", $1.type != "agent" { return true }
            if $1.type == "agent", $0.type != "agent" { return false }
            return (degree[$0.id] ?? 0) > (degree[$1.id] ?? 0)
        }.prefix(count).map(\.id)
        return Set(agents).union(busiest)
    }

    private static func visibleEdges(_ graph: VaultGraph,
                                     degree: [String: Int],
                                     keyIds: Set<String>,
                                     threeD: Bool) -> [VaultEdge] {
        let nodeIds = Set(graph.nodes.map(\.id))
        let valid = graph.edges.filter {
            $0.source != $0.target && nodeIds.contains($0.source) && nodeIds.contains($0.target)
        }
        let sorted = valid.sorted {
            let left = (degree[$0.source] ?? 0) + (degree[$0.target] ?? 0)
            let right = (degree[$1.source] ?? 0) + (degree[$1.target] ?? 0)
            return left > right
        }
        if graph.nodes.count <= 55 {
            return Array(sorted.prefix(threeD ? 130 : 90))
        }
        let important = sorted.filter { keyIds.contains($0.source) || keyIds.contains($0.target) }
        return Array(important.prefix(threeD ? 150 : 75))
    }

    private static func initials(_ node: VaultNode) -> String {
        if node.type == "agent" { return String(node.id.uppercased().prefix(3)) }
        let words = node.label.split(separator: " ").filter { $0.first?.isLetter ?? false }
        let letters = String(words.prefix(2).compactMap(\.first)).uppercased()
        return letters.isEmpty ? String(node.label.uppercased().prefix(2)) : letters
    }

    private static func color(_ type: String) -> UIColor {
        switch type {
        case "agent": return UIColor(red: 1.0, green: 0.82, blue: 0.40, alpha: 1)
        case "meeting": return UIColor(red: 0.32, green: 0.86, blue: 0.96, alpha: 1)
        case "decision": return UIColor(red: 0.32, green: 0.95, blue: 0.60, alpha: 1)
        case "obsidian": return UIColor(red: 0.62, green: 0.54, blue: 0.92, alpha: 1)
        default: return UIColor(red: 0.66, green: 0.73, blue: 0.84, alpha: 1)
        }
    }

    private static func addBackdrop(to root: SCNNode, threeD: Bool, nodeCount: Int) {
        let teal = UIColor(red: 0.25, green: 0.86, blue: 0.80, alpha: 1)
        let gold = UIColor(red: 0.95, green: 0.75, blue: 0.34, alpha: 1)
        if threeD {
            let sphere = SCNSphere(radius: nodeCount > 80 ? 4.28 : 3.98)
            sphere.segmentCount = 64
            let material = SCNMaterial()
            material.diffuse.contents = teal.withAlphaComponent(0.10)
            material.emission.contents = teal.withAlphaComponent(0.18)
            material.lightingModel = .constant
            material.fillMode = .lines
            material.isDoubleSided = true
            material.transparency = 0.24
            sphere.firstMaterial = material
            let shell = SCNNode(geometry: sphere)
            shell.opacity = 0.8
            root.addChildNode(shell)

            for (index, radius) in [4.05, 3.1, 2.15].enumerated() {
                let ring = orbitRing(radius: CGFloat(radius),
                                     color: index == 0 ? gold.withAlphaComponent(0.70) : teal.withAlphaComponent(0.46),
                                     thickness: index == 0 ? 0.012 : 0.007)
                ring.eulerAngles = SCNVector3(Float(index) * .pi / 5.0,
                                              Float(index + 1) * .pi / 4.0,
                                              Float(index) * .pi / 7.0)
                root.addChildNode(ring)
            }
        } else {
            for (index, radius) in [1.75, 3.3, 4.75, 5.35].enumerated() {
                let ring = orbitRing(radius: CGFloat(radius),
                                     color: (index == 0 ? gold : teal).withAlphaComponent(index == 3 ? 0.18 : 0.36),
                                     thickness: index == 0 ? 0.010 : 0.006)
                ring.scale.y = 0.86
                root.addChildNode(ring)
            }
        }
    }

    private static func orbitRing(radius: CGFloat, color: UIColor, thickness: CGFloat) -> SCNNode {
        let torus = SCNTorus(ringRadius: radius, pipeRadius: thickness)
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant
        material.transparency = color.cgColor.alpha
        torus.firstMaterial = material
        return SCNNode(geometry: torus)
    }

    private static func billboardPlane(texture: UIImage, width: CGFloat, height: CGFloat,
                                       glow: Bool, writesDepth: Bool) -> SCNNode {
        let plane = SCNPlane(width: width, height: height)
        let material = SCNMaterial()
        material.diffuse.contents = texture
        material.emission.contents = glow ? texture : nil
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.blendMode = .alpha
        material.writesToDepthBuffer = writesDepth
        plane.firstMaterial = material
        let node = SCNNode(geometry: plane)
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    private static func link(from a: SIMD3<Float>,
                             to b: SIMD3<Float>,
                             radius: CGFloat,
                             emphasized: Bool,
                             threeD: Bool) -> SCNNode {
        let pa = SCNVector3(a.x, a.y, a.z)
        let pb = SCNVector3(b.x, b.y, b.z)
        let dist = length(b - a)
        let cylinder = SCNCylinder(radius: max(radius, 0.004), height: CGFloat(dist))
        let teal = UIColor(red: 0.30, green: 0.88, blue: 0.82, alpha: emphasized ? 0.68 : 0.24)
        let material = SCNMaterial()
        material.diffuse.contents = teal
        material.emission.contents = teal.withAlphaComponent(emphasized ? 0.60 : 0.28)
        material.lightingModel = .constant
        material.transparency = threeD ? (emphasized ? 0.50 : 0.22) : (emphasized ? 0.32 : 0.14)
        cylinder.firstMaterial = material
        let bar = SCNNode(geometry: cylinder)
        bar.position = SCNVector3((pa.x + pb.x) / 2, (pa.y + pb.y) / 2, (pa.z + pb.z) / 2)
        bar.look(at: pb, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
        return bar
    }

    // MARK: textures

    private static func nodeTexture(color: UIColor, initials: String, key: Bool, threeD: Bool) -> UIImage {
        let size: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let c = ctx.cgContext
            let rect = CGRect(x: key ? 32 : 43,
                              y: key ? 32 : 43,
                              width: key ? size - 64 : size - 86,
                              height: key ? size - 64 : size - 86)
            c.saveGState()
            c.setShadow(offset: .zero, blur: key ? 24 : 16, color: color.withAlphaComponent(key ? 0.82 : 0.55).cgColor)
            c.setFillColor(color.withAlphaComponent(key ? 0.28 : 0.14).cgColor)
            c.fillEllipse(in: rect.insetBy(dx: key ? -18 : -12, dy: key ? -18 : -12))
            c.restoreGState()

            if key {
                let colors = [
                    color.withAlphaComponent(1).cgColor,
                    UIColor(red: 0.10, green: 0.09, blue: 0.06, alpha: 1).cgColor
                ] as CFArray
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
                c.saveGState()
                c.addEllipse(in: rect)
                c.clip()
                c.drawLinearGradient(gradient,
                                     start: CGPoint(x: rect.midX - 45, y: rect.minY),
                                     end: CGPoint(x: rect.midX + 36, y: rect.maxY),
                                     options: [])
                c.restoreGState()
                c.setStrokeColor(UIColor.white.withAlphaComponent(0.38).cgColor)
                c.setLineWidth(5)
                c.strokeEllipse(in: rect.insetBy(dx: 5, dy: 5))
            } else {
                c.setFillColor(UIColor(red: 0.018, green: 0.045, blue: 0.055, alpha: threeD ? 0.86 : 0.94).cgColor)
                c.fillEllipse(in: rect)
                c.saveGState()
                c.setShadow(offset: .zero, blur: 8, color: color.withAlphaComponent(0.70).cgColor)
                c.setStrokeColor(color.withAlphaComponent(0.88).cgColor)
                c.setLineWidth(10)
                c.strokeEllipse(in: rect.insetBy(dx: 7, dy: 7))
                c.restoreGState()
            }

            let textColor = key ? UIColor.white.withAlphaComponent(0.95) : color.withAlphaComponent(0.95)
            let font = UIFont.systemFont(ofSize: initials.count > 2 ? 64 : 86, weight: .heavy)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]
            let string = initials as NSString
            let height = string.size(withAttributes: attrs).height
            string.draw(in: CGRect(x: 0, y: (size - height) / 2, width: size, height: height), withAttributes: attrs)
        }
    }

    private static func labelTexture(_ name: String) -> UIImage {
        let width: CGFloat = 760
        let height: CGFloat = 150
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { ctx in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let font = UIFont.systemFont(ofSize: 52, weight: .semibold)
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 2),
                                    blur: 7,
                                    color: UIColor.black.withAlphaComponent(0.85).cgColor)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            (name as NSString).draw(in: CGRect(x: 12, y: (height - 70) / 2, width: width - 24, height: 70),
                                    withAttributes: attrs)
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
    @State private var searchText = ""

    /// Search narrows the graph to matching notes plus their direct
    /// neighbours — the Obsidian "local graph" behaviour.
    private var visibleGraph: VaultGraph {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return graph }
        let matched = Set(graph.nodes.filter {
            $0.label.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }.map(\.id))
        guard !matched.isEmpty else { return .empty }
        var kept = matched
        for edge in graph.edges where matched.contains(edge.source) || matched.contains(edge.target) {
            kept.insert(edge.source)
            kept.insert(edge.target)
        }
        return VaultGraph(
            nodes: graph.nodes.filter { kept.contains($0.id) },
            edges: graph.edges.filter { kept.contains($0.source) && kept.contains($0.target) }
        )
    }

    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.035, blue: 0.06).ignoresSafeArea()

            if !visibleGraph.nodes.isEmpty {
                VaultGraphSceneView(graph: visibleGraph, settings: settings) { node in
                    selectedNode = node
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

            VStack {
                Spacer()
                HStack(spacing: 14) {
                    legendDot("Agents", Color(red: 1.0, green: 0.82, blue: 0.40))
                    legendDot("Meetings", Color(red: 0.32, green: 0.86, blue: 0.96))
                    legendDot("Decisions", Color(red: 0.32, green: 0.95, blue: 0.60))
                    if graph.nodes.contains(where: { $0.type == "obsidian" }) {
                        legendDot("Obsidian", Color(red: 0.62, green: 0.54, blue: 0.92))
                    }
                    Spacer()
                    Text("\(visibleGraph.nodes.count) notes · \(visibleGraph.edges.count) links · drag · pinch")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
                .padding(10)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding()
        }
        .navigationTitle("Knowledge Graph")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search your second brain")
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
            VaultNodeDetailSheet(node: node, degree: degree(for: node))
                .presentationDetents([.medium])
        }
        .task { await load() }
    }

    private func legendDot(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).font(.caption2).foregroundStyle(.white.opacity(0.8))
        }
    }

    private var controls: some View {
        NavigationStack {
            Form {
                Section("Motion") { slider("Rotation speed", $settings.rotationSpeed, 0...2) }
                Section("Nodes & links") {
                    slider("Node size", $settings.nodeSize, 0.2...1.0)
                    slider("Link thickness", $settings.linkThickness, 0.004...0.06)
                    Toggle("Glow", isOn: $settings.glow).tint(HermesTheme.emerald)
                    Toggle("Arrows", isOn: $settings.arrows).tint(HermesTheme.emerald)
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

    private func degree(for node: VaultNode) -> Int {
        graph.edges.reduce(into: 0) { total, edge in
            if edge.source == node.id || edge.target == node.id {
                total += 1
            }
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
        } catch {
            self.error = error.localizedDescription
        }
    }
}
