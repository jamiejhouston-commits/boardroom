import Foundation
import SceneKit
import simd
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Graph data (from the relay's /company/vault/graph)

struct VaultGraph: Codable, Equatable {
    var nodes: [VaultNode]
    var edges: [VaultEdge]
    var vault: String? = nil     // Obsidian vault name, for obsidian:// deep links
    static let empty = VaultGraph(nodes: [], edges: [])
}

struct VaultNode: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var type: String             // agent | meeting | decision | note | obsidian | canvas
    var folder: String? = nil    // "Projects", "wiki", "Inbox", "raw", "Notes", "Boardroom"
    var modified: Double? = nil  // epoch seconds
    var words: Int? = nil
    var tags: [String]? = nil
    var phantom: Bool? = nil     // unresolved wikilink target — no file behind it
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
    var recency = false          // paint by how recently each note was touched
}

// MARK: - The premium palette (muted navy-charcoal + gold — no neon)

enum VaultBrainPalette {
    static let background = UIColor(red: 0.050, green: 0.058, blue: 0.088, alpha: 1)
    static let star = UIColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1)
    static let focusGold = UIColor(red: 0.94, green: 0.79, blue: 0.46, alpha: 1)
    static let phantom = UIColor(red: 0.45, green: 0.48, blue: 0.56, alpha: 1)
    static let caption = UIColor(red: 0.88, green: 0.86, blue: 0.80, alpha: 1)

    /// One family per legend chip; folder-shaped for Obsidian notes.
    static func family(_ node: VaultNode) -> String {
        switch node.type {
        case "agent": return "Agents"
        case "meeting": return "Meetings"
        case "decision": return "Decisions"
        case "canvas": return "Canvas"
        case "note": return "Boardroom"
        default: break
        }
        switch node.folder ?? "Notes" {
        case "wiki": return "Wiki"
        case "raw": return "Raw"
        case let folder: return folder
        }
    }

    static func familyColor(_ family: String) -> UIColor {
        switch family {
        case "Agents": return UIColor(red: 0.97, green: 0.90, blue: 0.72, alpha: 1)   // champagne
        case "Projects": return UIColor(red: 0.87, green: 0.71, blue: 0.42, alpha: 1) // burnished gold
        case "Wiki": return UIColor(red: 0.44, green: 0.75, blue: 0.58, alpha: 1)     // emerald
        case "Notes": return UIColor(red: 0.77, green: 0.74, blue: 0.67, alpha: 1)    // warm cream
        case "Inbox": return UIColor(red: 0.88, green: 0.62, blue: 0.36, alpha: 1)    // amber
        case "Raw": return UIColor(red: 0.56, green: 0.63, blue: 0.78, alpha: 1)      // slate blue
        case "Canvas": return UIColor(red: 0.65, green: 0.57, blue: 0.85, alpha: 1)   // muted violet
        case "Boardroom": return UIColor(red: 0.42, green: 0.66, blue: 0.62, alpha: 1) // sea-glass teal
        case "Meetings": return UIColor(red: 0.42, green: 0.60, blue: 0.72, alpha: 1) // cyan slate
        case "Decisions": return UIColor(red: 0.42, green: 0.78, blue: 0.61, alpha: 1) // emerald
        default: return UIColor(red: 0.70, green: 0.70, blue: 0.72, alpha: 1)
        }
    }

    /// Recency paint: how warm is this memory?
    static func recencyColor(ageDays: Double) -> UIColor {
        switch ageDays {
        case ..<7: return UIColor(red: 0.95, green: 0.80, blue: 0.45, alpha: 1)
        case ..<30: return UIColor(red: 0.85, green: 0.66, blue: 0.42, alpha: 1)
        case ..<90: return UIColor(red: 0.72, green: 0.66, blue: 0.55, alpha: 1)
        default: return UIColor(red: 0.48, green: 0.50, blue: 0.58, alpha: 1)
        }
    }

    static func color(for node: VaultNode, settings: GraphSettings, now: Date) -> UIColor {
        if node.phantom == true { return phantom }
        if settings.recency, let modified = node.modified {
            return recencyColor(ageDays: max(now.timeIntervalSince1970 - modified, 0) / 86_400)
        }
        return familyColor(family(node))
    }
}

// MARK: - Layout: label-propagation constellations + free-space force sim

struct BrainLayout {
    var positions: [String: SIMD3<Float>]
    var captions: [(text: String, position: SIMD3<Float>)]
    var clusterCount: Int
}

enum GraphLayout {
    static func compute(_ graph: VaultGraph, _ s: GraphSettings) -> BrainLayout {
        guard !graph.nodes.isEmpty else { return BrainLayout(positions: [:], captions: [], clusterCount: 0) }
        let flat = !s.threeD   // 2D = the same constellations, flattened to a plane

        let nodes = graph.nodes
        let n = nodes.count
        var indexOf = [String: Int](minimumCapacity: n)
        for (i, node) in nodes.enumerated() { indexOf[node.id] = i }

        // Undirected, deduped edge pairs.
        var pairSeen = Set<UInt64>()
        var pairs = [(Int, Int)]()
        for edge in graph.edges {
            guard let a = indexOf[edge.source], let b = indexOf[edge.target], a != b else { continue }
            let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
            if pairSeen.insert(key).inserted { pairs.append((a, b)) }
        }
        var degree = [Int](repeating: 0, count: n)
        var adjacency = [[Int]](repeating: [], count: n)
        for (a, b) in pairs {
            degree[a] += 1; degree[b] += 1
            adjacency[a].append(b); adjacency[b].append(a)
        }

        // Label propagation — deterministic sweep order and tie-breaks.
        var label = Array(0..<n)
        for _ in 0..<8 {
            var changed = false
            for i in 0..<n where !adjacency[i].isEmpty {
                var counts = [Int: Int]()
                for j in adjacency[i] { counts[label[j], default: 0] += 1 }
                let best = counts.min { l, r in
                    l.value != r.value ? l.value > r.value : l.key < r.key
                }!.key
                if best != label[i] { label[i] = best; changed = true }
            }
            if !changed { break }
        }

        // Communities ≥4 become constellations (cap 12); everyone else
        // gathers around their family's anchor.
        var groups = [Int: [Int]]()
        for i in 0..<n { groups[label[i], default: []].append(i) }
        let bigs = groups.values
            .filter { $0.count >= 4 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
            .prefix(12)

        var anchorOf = [Int](repeating: -1, count: n)
        var members: [[Int]] = []
        var captions: [String] = []
        for group in bigs {
            let anchor = members.count
            for i in group { anchorOf[i] = anchor }
            members.append(group)
            let hub = group.max { l, r in
                degree[l] != degree[r] ? degree[l] < degree[r] : nodes[l].id > nodes[r].id
            }!
            captions.append(nodes[hub].label)
        }
        var familyAnchor = [String: Int]()
        for i in 0..<n where anchorOf[i] == -1 {
            let family = VaultBrainPalette.family(nodes[i])
            if let anchor = familyAnchor[family] {
                anchorOf[i] = anchor
                members[anchor].append(i)
            } else {
                let anchor = members.count
                familyAnchor[family] = anchor
                anchorOf[i] = anchor
                members.append([i])
                captions.append(family)
            }
        }

        // Anchors: fibonacci sphere in 3D, sunflower disc in 2D (biggest
        // cluster near the centre). Seeds jittered around them.
        let anchorCount = members.count
        var anchorPos = [SIMD3<Float>]()
        for k in 0..<anchorCount {
            if flat {
                let t = (Float(k) + 0.5) / Float(anchorCount)
                let a = Float.pi * (3 - sqrt(5)) * Float(k)
                anchorPos.append(SIMD3(cos(a), sin(a), 0) * (2.7 * sqrt(t)))
            } else {
                let t = Float(k) + 0.5
                let phi = acos(max(min(1 - 2 * t / Float(anchorCount), 1), -1))
                let theta = Float.pi * (1 + sqrt(5)) * t
                anchorPos.append(SIMD3(sin(phi) * cos(theta), sin(phi) * sin(theta), cos(phi)) * 2.55)
            }
        }
        var pos = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n {
            let spread = 0.4 + 0.09 * sqrt(Float(members[anchorOf[i]].count))
            var seed = jitter(nodes[i].id)
            if flat { seed.z = 0 }
            pos[i] = anchorPos[anchorOf[i]] + seed * spread
        }

        // Free-space force sim: repulsion (with far cutoff), link springs,
        // anchor + center lerp. No shell pinning — clusters are real.
        let iterations = n > 200 ? 30 : n > 120 ? 46 : 70
        let repel = Float(s.repelForce) * 0.9
        let linkF = Float(s.linkForce)
        let rest = Float(s.linkDistance) * 0.45
        let centerPull = Float(s.centerForce)
        for _ in 0..<iterations {
            var disp = [SIMD3<Float>](repeating: .zero, count: n)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let d = pos[i] - pos[j]
                    let dist2 = max(simd_length_squared(d), 0.0025)
                    if dist2 > 36 { continue }
                    let push = d / sqrt(dist2) * (repel / dist2)
                    disp[i] += push
                    disp[j] -= push
                }
            }
            for (a, b) in pairs {
                let d = pos[b] - pos[a]
                let dist = max(simd_length(d), 0.05)
                let pull = d / dist * ((dist - rest) * linkF)
                disp[a] += pull
                disp[b] -= pull
            }
            for i in 0..<n {
                var step = disp[i] * 0.016
                let mag = simd_length(step)
                if mag > 0.3 { step = step / mag * 0.3 }
                pos[i] += step
                pos[i] += (anchorPos[anchorOf[i]] - pos[i]) * 0.045
                pos[i] -= pos[i] * centerPull * 0.02
            }
        }

        // Fit the whole brain inside the camera's comfortable radius —
        // portrait width is the tight dimension, so 2D fits much smaller
        // (pinch-zoom covers the rest).
        // (With z = 0 seeds every force stays in-plane, so 2D needs no clamp.)
        let fit: Float = flat ? 3.0 : 4.0
        let maxR = pos.map(simd_length).max() ?? 1
        if maxR > fit {
            let scale = fit / maxR
            for i in 0..<n { pos[i] *= scale }
        }

        var positions = [String: SIMD3<Float>](minimumCapacity: n)
        for (i, node) in nodes.enumerated() { positions[node.id] = pos[i] }

        var clusterCaptions = [(text: String, position: SIMD3<Float>)]()
        let captionWorthy = members.enumerated()
            .filter { $0.element.count >= 5 }
            .sorted { $0.element.count > $1.element.count }
            .prefix(10)
        for (anchor, group) in captionWorthy {
            var centroid = SIMD3<Float>.zero
            for i in group { centroid += pos[i] }
            centroid /= Float(group.count)
            clusterCaptions.append((text: captions[anchor], position: centroid * 1.12))
        }
        let clusterCount = members.filter { $0.count >= 4 }.count
        return BrainLayout(positions: positions, captions: clusterCaptions, clusterCount: clusterCount)
    }

    /// A cheap communities-only pass for the HUD stats line — label
    /// propagation without the force sim.
    static func communityCount(_ graph: VaultGraph) -> Int {
        let nodes = graph.nodes
        let n = nodes.count
        guard n > 0 else { return 0 }
        var indexOf = [String: Int](minimumCapacity: n)
        for (i, node) in nodes.enumerated() { indexOf[node.id] = i }
        var adjacency = [[Int]](repeating: [], count: n)
        var pairSeen = Set<UInt64>()
        for edge in graph.edges {
            guard let a = indexOf[edge.source], let b = indexOf[edge.target], a != b else { continue }
            let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
            if pairSeen.insert(key).inserted {
                adjacency[a].append(b)
                adjacency[b].append(a)
            }
        }
        var label = Array(0..<n)
        for _ in 0..<8 {
            var changed = false
            for i in 0..<n where !adjacency[i].isEmpty {
                var counts = [Int: Int]()
                for j in adjacency[i] { counts[label[j], default: 0] += 1 }
                let best = counts.min { l, r in
                    l.value != r.value ? l.value > r.value : l.key < r.key
                }!.key
                if best != label[i] { label[i] = best; changed = true }
            }
            if !changed { break }
        }
        var sizes = [Int: Int]()
        for l in label { sizes[l, default: 0] += 1 }
        return sizes.values.filter { $0 >= 4 }.count
    }

    static func degreeMap(_ graph: VaultGraph) -> [String: Int] {
        var deg = [String: Int]()
        for e in graph.edges {
            deg[e.source, default: 0] += 1
            deg[e.target, default: 0] += 1
        }
        return deg
    }

    /// Deterministic per-note jitter (FNV-1a → three floats in [-1, 1]).
    static func jitter(_ id: String) -> SIMD3<Float> {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        func f(_ shift: UInt64) -> Float { Float((h >> shift) & 0xFFFF) / 32768.0 - 1.0 }
        let v = SIMD3(f(0), f(16), f(32))
        return simd_length(v) < 0.001 ? SIMD3(0.3, 0.3, 0.3) : v
    }
}

// MARK: - Scene construction (shared by the app view and the render bench)

/// Everything the coordinator needs to run focus mode without rebuilding.
struct BrainSceneHandles {
    let scene: SCNScene
    let spinRoot: SCNNode
    let nodeHandles: [String: SCNNode]
    let baseOpacity: [String: CGFloat]
    let webNode: SCNNode?
    let emphasisNode: SCNNode?
    let captionsNode: SCNNode?
    let positions: [String: SIMD3<Float>]
    let adjacency: [String: Set<String>]
    let labeledIDs: Set<String>
    let nodesByID: [String: VaultNode]
}

enum VaultBrainScene {
    // ponytail: texture cache keyed by style string — initials only on hubs,
    // so the other ~250 discs collapse into a handful of shared textures.
    nonisolated(unsafe) private static var textureCache = [String: UIImage]()

    static func build(graph: VaultGraph, settings: GraphSettings, now: Date = Date()) -> BrainSceneHandles {
        let scene = SCNScene()
        scene.background.contents = VaultBrainPalette.background

        let camNode = SCNNode()
        let cam = SCNCamera()
        cam.fieldOfView = settings.threeD ? 48 : 43
        cam.wantsHDR = true
        cam.bloomIntensity = settings.glow ? 0.55 : 0
        cam.bloomThreshold = 0.65
        cam.bloomBlurRadius = 14
        cam.wantsExposureAdaptation = false
        cam.zFar = 240
        camNode.camera = cam
        camNode.simdPosition = SIMD3(0, 0, settings.threeD ? 13.4 : 12.8)
        camNode.simdLook(at: SIMD3<Float>(0, 0, 0))
        scene.rootNode.addChildNode(camNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 620
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        if settings.threeD {
            scene.fogStartDistance = 13
            scene.fogEndDistance = 46
            scene.fogColor = VaultBrainPalette.background
        }
        scene.rootNode.addChildNode(starfield(count: 380, radius: 20...34, alpha: 0.45, pointSize: 2.0, seed: 0x9E3779B97F4A7C15))
        scene.rootNode.addChildNode(starfield(count: 64, radius: 18...30, alpha: 0.85, pointSize: 3.2, seed: 0xD1B54A32D192ED03))

        let spinRoot = SCNNode()
        scene.rootNode.addChildNode(spinRoot)

        let layout = GraphLayout.compute(graph, settings)
        let degree = GraphLayout.degreeMap(graph)
        let maxDeg = max(degree.values.max() ?? 1, 1)
        let keyIds = hubIDs(graph, degree: degree, count: settings.threeD ? 10 : 9)

        var nodesByID = [String: VaultNode](minimumCapacity: graph.nodes.count)
        for node in graph.nodes { nodesByID[node.id] = node }
        func colorOf(_ id: String) -> UIColor {
            guard let node = nodesByID[id] else { return VaultBrainPalette.phantom }
            return VaultBrainPalette.color(for: node, settings: settings, now: now)
        }

        // Adjacency (directed edges collapsed) — powers focus mode.
        var adjacency = [String: Set<String>]()
        var pairSeen = Set<String>()
        var webSegments = [(SIMD3<Float>, SIMD3<Float>, UIColor, UIColor)]()
        var emphasisPairs = [(VaultEdge, Int)]()
        for edge in graph.edges {
            guard edge.source != edge.target,
                  let a = layout.positions[edge.source], let b = layout.positions[edge.target] else { continue }
            adjacency[edge.source, default: []].insert(edge.target)
            adjacency[edge.target, default: []].insert(edge.source)
            let key = edge.source < edge.target ? "\(edge.source)|\(edge.target)" : "\(edge.target)|\(edge.source)"
            guard pairSeen.insert(key).inserted else { continue }
            webSegments.append((a, b, colorOf(edge.source), colorOf(edge.target)))
            if keyIds.contains(edge.source) || keyIds.contains(edge.target) {
                emphasisPairs.append((edge, (degree[edge.source] ?? 0) + (degree[edge.target] ?? 0)))
            }
        }

        // Every link, one draw call.
        let webNode = edgeWeb(segments: webSegments, alpha: settings.threeD ? 0.22 : 0.34)
        if let webNode { spinRoot.addChildNode(webNode) }

        // The busiest connections get physical weight.
        let emphasisNode = SCNNode()
        for (edge, _) in emphasisPairs.sorted(by: { $0.1 > $1.1 }).prefix(60) {
            guard let a = layout.positions[edge.source], let b = layout.positions[edge.target] else { continue }
            let hubEnd = (degree[edge.source] ?? 0) >= (degree[edge.target] ?? 0) ? edge.source : edge.target
            emphasisNode.addChildNode(link(from: a, to: b,
                                           radius: CGFloat(settings.linkThickness),
                                           color: colorOf(hubEnd),
                                           alpha: 0.22))
        }
        spinRoot.addChildNode(emphasisNode)

        var nodeHandles = [String: SCNNode]()
        var baseOpacity = [String: CGFloat]()
        var labeledIDs = Set<String>()
        var labeledTexts = Set<String>()

        for node in graph.nodes {
            guard let p = layout.positions[node.id] else { continue }
            let deg = degree[node.id] ?? 0
            let key = keyIds.contains(node.id)
            let color = VaultBrainPalette.color(for: node, settings: settings, now: now)
            let base = CGFloat(settings.nodeSize)
            let degF = CGFloat(log2(Float(1 + deg)) / log2(Float(1 + maxDeg)))
            let width = node.type == "agent" ? base * 1.35
                : key ? base * (1.15 + degF * 0.6) : base * (0.5 + degF * 0.42)

            let phantom = node.phantom == true
            let recent = !settings.recency && !phantom
                && (node.modified.map { now.timeIntervalSince1970 - $0 < 3 * 86_400 } ?? false)
            let texture: UIImage = key
                ? hubTexture(color: color, initials: initials(node))
                : discTexture(color: color,
                              phantom: phantom,
                              recent: recent,
                              rounded: node.type == "canvas",
                              cacheKey: "\(VaultBrainPalette.family(node))|\(phantom)|\(recent)|\(node.type == "canvas")|\(settings.recency ? recencyBucket(node, now: now) : -1)")

            let plane = billboardPlane(texture: texture, width: width, height: width,
                                       glow: settings.glow && key, writesDepth: true)
            plane.simdPosition = p
            plane.name = "vault-node:\(node.id)"
            let opacity: CGFloat = phantom ? 0.55 : 1
            plane.opacity = opacity

            // Agents' initials already name them — a text label would double up.
            if key && node.type != "agent"
                && !node.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let label = labelNode(text: node.label, emphasis: false, billboarded: false)
                label.position = SCNVector3(0, -Double(width) * 0.72, 0.04)
                plane.addChildNode(label)
                labeledIDs.insert(node.id)
                labeledTexts.insert(node.label.lowercased())
            }

            // A gentle breath so the brain reads as alive, phase-varied per note.
            if settings.threeD && settings.rotationSpeed > 0.001 {
                let phase = Double(abs(node.id.hashValue % 100)) / 100.0
                let up = SCNAction.moveBy(x: 0, y: 0.04, z: 0, duration: 1.8 + phase)
                up.timingMode = .easeInEaseOut
                let down = up.reversed()
                down.timingMode = .easeInEaseOut
                plane.runAction(.repeatForever(.sequence([up, down])))
            }

            spinRoot.addChildNode(plane)
            nodeHandles[node.id] = plane
            baseOpacity[node.id] = opacity
        }

        // Constellation captions — quiet small-caps markers over each cluster.
        var captionsNode: SCNNode?
        if !layout.captions.isEmpty {
            let group = SCNNode()
            for caption in layout.captions where !labeledTexts.contains(caption.text.lowercased()) {
                let node = captionNode(text: caption.text)
                node.simdPosition = caption.position + SIMD3(0, 0.35, 0)
                group.addChildNode(node)
            }
            spinRoot.addChildNode(group)
            captionsNode = group
        }

        if settings.rotationSpeed > 0.001 {
            let duration = max(5.0, 42.0 / settings.rotationSpeed)
            let y: CGFloat = settings.threeD ? .pi * 2 : 0
            let z: CGFloat = settings.threeD ? 0 : .pi * 2
            spinRoot.runAction(.repeatForever(.rotateBy(x: 0, y: y, z: z, duration: duration)))
        }

        return BrainSceneHandles(scene: scene,
                                 spinRoot: spinRoot,
                                 nodeHandles: nodeHandles,
                                 baseOpacity: baseOpacity,
                                 webNode: webNode,
                                 emphasisNode: emphasisNode,
                                 captionsNode: captionsNode,
                                 positions: layout.positions,
                                 adjacency: adjacency,
                                 labeledIDs: labeledIDs,
                                 nodesByID: nodesByID)
    }

    // MARK: hubs & colors

    static func hubIDs(_ graph: VaultGraph, degree: [String: Int], count: Int) -> Set<String> {
        let agents = graph.nodes.filter { $0.type == "agent" }.map(\.id)
        let busiest = graph.nodes
            .filter { $0.phantom != true }
            .sorted {
                if $0.type == "agent", $1.type != "agent" { return true }
                if $1.type == "agent", $0.type != "agent" { return false }
                return (degree[$0.id] ?? 0) > (degree[$1.id] ?? 0)
            }
            .prefix(count).map(\.id)
        return Set(agents).union(busiest)
    }

    private static func recencyBucket(_ node: VaultNode, now: Date) -> Int {
        guard let modified = node.modified else { return 3 }
        let days = max(now.timeIntervalSince1970 - modified, 0) / 86_400
        return days < 7 ? 0 : days < 30 ? 1 : days < 90 ? 2 : 3
    }

    static func initials(_ node: VaultNode) -> String {
        if node.type == "agent" { return String(node.id.uppercased().prefix(3)) }
        let words = node.label.split(separator: " ").filter { $0.first?.isLetter ?? false }
        let letters = String(words.prefix(2).compactMap(\.first)).uppercased()
        return letters.isEmpty ? String(node.label.uppercased().prefix(2)) : letters
    }

    // MARK: geometry

    /// ALL edges in one `.line` geometry — a single draw call for the web.
    private static func edgeWeb(segments: [(SIMD3<Float>, SIMD3<Float>, UIColor, UIColor)],
                                alpha: CGFloat) -> SCNNode? {
        guard !segments.isEmpty else { return nil }
        var vertices = [SCNVector3]()
        var colors = [Float]()
        vertices.reserveCapacity(segments.count * 2)
        colors.reserveCapacity(segments.count * 8)
        for (a, b, ca, cb) in segments {
            vertices.append(SCNVector3(CGFloat(a.x), CGFloat(a.y), CGFloat(a.z)))
            vertices.append(SCNVector3(CGFloat(b.x), CGFloat(b.y), CGFloat(b.z)))
            for color in [ca, cb] {
                var r: CGFloat = 1, g: CGFloat = 1, b2: CGFloat = 1, a2: CGFloat = 1
                color.getRed(&r, green: &g, blue: &b2, alpha: &a2)
                colors.append(contentsOf: [Float(r), Float(g), Float(b2), Float(alpha)])
            }
        }
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData,
                                            semantic: .color,
                                            vectorCount: vertices.count,
                                            usesFloatComponents: true,
                                            componentsPerVector: 4,
                                            bytesPerComponent: 4,
                                            dataOffset: 0,
                                            dataStride: 16)
        let indices = (0..<Int32(vertices.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }

    /// A dusting of far stars — one point-primitive geometry per layer.
    private static func starfield(count: Int, radius: ClosedRange<Float>,
                                  alpha: CGFloat, pointSize: CGFloat, seed: UInt64) -> SCNNode {
        var state = seed
        func rnd() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(state % 20_000) / 10_000 - 1
        }
        var vertices = [SCNVector3]()
        for _ in 0..<count {
            var v = SIMD3(rnd(), rnd(), rnd())
            let len = max(simd_length(v), 0.01)
            let r = radius.lowerBound + (radius.upperBound - radius.lowerBound) * abs(rnd())
            v = v / len * r
            vertices.append(SCNVector3(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z)))
        }
        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: (0..<Int32(vertices.count)).map { $0 },
                                         primitiveType: .point)
        element.pointSize = pointSize
        element.minimumPointScreenSpaceRadius = 0.5
        element.maximumPointScreenSpaceRadius = pointSize * 1.4
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = VaultBrainPalette.star.withAlphaComponent(alpha)
        material.emission.contents = VaultBrainPalette.star.withAlphaComponent(alpha * 0.7)
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }

    static func billboardPlane(texture: UIImage, width: CGFloat, height: CGFloat,
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

    static func link(from a: SIMD3<Float>, to b: SIMD3<Float>,
                     radius: CGFloat, color: UIColor, alpha: CGFloat) -> SCNNode {
        let dist = simd_length(b - a)
        let cylinder = SCNCylinder(radius: max(radius, 0.004), height: CGFloat(dist))
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(alpha)
        material.emission.contents = color.withAlphaComponent(alpha * 0.8)
        material.lightingModel = .constant
        material.transparency = alpha
        cylinder.firstMaterial = material
        let bar = SCNNode(geometry: cylinder)
        bar.simdPosition = (a + b) / 2
        bar.simdLook(at: b, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 1, 0))
        return bar
    }

    // MARK: labels

    static func labelNode(text: String, emphasis: Bool, billboarded: Bool) -> SCNNode {
        let width = emphasis ? min(max(CGFloat(text.count) * 0.115, 1.0), 2.4)
            : min(max(CGFloat(text.count) * 0.085, 0.9), 1.8)
        let node = billboardPlane(texture: labelTexture(text, emphasis: emphasis),
                                  width: width, height: width * 0.21,
                                  glow: false, writesDepth: false)
        if !billboarded { node.constraints = nil }
        return node
    }

    static func captionNode(text: String) -> SCNNode {
        let display = text.uppercased()
        let width = min(max(CGFloat(display.count) * 0.14, 1.1), 3.0)
        return billboardPlane(texture: captionTexture(display),
                              width: width, height: width * 0.20,
                              glow: false, writesDepth: false)
    }

    // MARK: textures

    /// Hub node — gradient disc with initials and a bright rim.
    static func hubTexture(color: UIColor, initials: String) -> UIImage {
        let size: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let c = ctx.cgContext
            let rect = CGRect(x: 32, y: 32, width: size - 64, height: size - 64)
            c.saveGState()
            c.setShadow(offset: .zero, blur: 20, color: color.withAlphaComponent(0.6).cgColor)
            c.setFillColor(color.withAlphaComponent(0.22).cgColor)
            c.fillEllipse(in: rect.insetBy(dx: -16, dy: -16))
            c.restoreGState()

            let colors = [
                color.withAlphaComponent(1).cgColor,
                UIColor(red: 0.10, green: 0.09, blue: 0.07, alpha: 1).cgColor
            ] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors, locations: [0, 1])!
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

            let font = UIFont.systemFont(ofSize: initials.count > 2 ? 64 : 86, weight: .heavy)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white.withAlphaComponent(0.95),
                .paragraphStyle: paragraph
            ]
            let string = initials as NSString
            let height = string.size(withAttributes: attrs).height
            string.draw(in: CGRect(x: 0, y: (size - height) / 2, width: size, height: height),
                        withAttributes: attrs)
        }
    }

    /// Everyday note — a quiet glowing disc. Cached by style, not by note.
    static func discTexture(color: UIColor, phantom: Bool, recent: Bool,
                            rounded: Bool, cacheKey: String) -> UIImage {
        if let cached = textureCache[cacheKey] { return cached }
        let size: CGFloat = 128
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: size / 2, y: size / 2)
            let bodyRadius: CGFloat = 30

            // Soft halo.
            let haloColors = [color.withAlphaComponent(phantom ? 0.08 : 0.16).cgColor,
                              color.withAlphaComponent(0).cgColor] as CFArray
            if let halo = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: haloColors, locations: [0, 1]) {
                c.drawRadialGradient(halo, startCenter: center, startRadius: bodyRadius * 0.4,
                                     endCenter: center, endRadius: size / 2, options: [])
            }

            let body = CGRect(x: center.x - bodyRadius, y: center.y - bodyRadius,
                              width: bodyRadius * 2, height: bodyRadius * 2)
            func addBodyPath() {
                if rounded {
                    c.addPath(CGPath(roundedRect: body, cornerWidth: 9, cornerHeight: 9, transform: nil))
                } else {
                    c.addEllipse(in: body)
                }
            }

            if phantom {
                c.saveGState()
                c.setStrokeColor(color.withAlphaComponent(0.75).cgColor)
                c.setLineWidth(2.5)
                c.setLineDash(phase: 0, lengths: [6, 5])
                addBodyPath()
                c.strokePath()
                c.restoreGState()
            } else {
                c.saveGState()
                addBodyPath()
                c.clip()
                let fill = [color.withAlphaComponent(0.95).cgColor,
                            color.withAlphaComponent(0.60).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                             colors: fill, locations: [0, 1]) {
                    c.drawLinearGradient(gradient,
                                         start: CGPoint(x: body.minX, y: body.minY),
                                         end: CGPoint(x: body.maxX, y: body.maxY),
                                         options: [])
                }
                c.restoreGState()
                c.setStrokeColor(UIColor.white.withAlphaComponent(0.26).cgColor)
                c.setLineWidth(2.2)
                addBodyPath()
                c.strokePath()
            }

            if recent {
                c.setStrokeColor(VaultBrainPalette.focusGold.withAlphaComponent(0.55).cgColor)
                c.setLineWidth(2)
                c.strokeEllipse(in: body.insetBy(dx: -8, dy: -8))
            }
        }
        textureCache[cacheKey] = image
        return image
    }

    static func labelTexture(_ name: String, emphasis: Bool) -> UIImage {
        let width: CGFloat = 760
        let height: CGFloat = 150
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { ctx in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let font = UIFont.systemFont(ofSize: emphasis ? 56 : 50, weight: emphasis ? .bold : .semibold)
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 2),
                                    blur: 7,
                                    color: UIColor.black.withAlphaComponent(0.85).cgColor)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: emphasis ? VaultBrainPalette.focusGold : UIColor.white,
                .paragraphStyle: paragraph
            ]
            (name as NSString).draw(in: CGRect(x: 12, y: (height - 70) / 2, width: width - 24, height: 70),
                                    withAttributes: attrs)
        }
    }

    /// Small-caps constellation caption — quiet, letterspaced, warm.
    static func captionTexture(_ text: String) -> UIImage {
        let width: CGFloat = 900
        let height: CGFloat = 170
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { ctx in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 2),
                                    blur: 9,
                                    color: UIColor.black.withAlphaComponent(0.9).cgColor)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 46, weight: .semibold),
                .foregroundColor: VaultBrainPalette.caption.withAlphaComponent(0.78),
                .kern: 7,
                .paragraphStyle: paragraph
            ]
            (text as NSString).draw(in: CGRect(x: 16, y: (height - 66) / 2, width: width - 32, height: 66),
                                    withAttributes: attrs)
        }
    }
}
