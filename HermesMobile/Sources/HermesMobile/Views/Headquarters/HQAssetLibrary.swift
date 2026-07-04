import SceneKit
import UIKit

/// Loads the bundled HQ USDZ assets (converted from the Quaternius packs),
/// normalizes their size, and pulls every material into the dark-premium
/// Hermes palette. Source scenes are cached; each placement gets a deep copy
/// so per-instance recolors never bleed through shared materials.
///
/// Palette notes proven on the Mac look-dev rig (same SceneKit engine):
/// - Blender's USD export writes a non-black EMISSION on every material —
///   props self-glow and defeat any diffuse remap unless it is stripped.
/// - Materials arrive in *linear* color space: component values run darker
///   than gamma-space (linear 0.2 displays like ~0.5). All remap thresholds
///   below are calibrated for linear values.
enum HQAssetLibrary {

    // MARK: Loading

    // Only touched from main-thread scene building (makeUIView / node init).
    nonisolated(unsafe) private static var sourceCache: [String: SCNNode] = [:]

    /// Loads an asset by name, scaled so its world height is `height`, with the
    /// HQ palette finish applied. Returns nil when the asset is missing from
    /// the bundle so callers can fall back to primitives.
    static func node(named name: String,
                     height: CGFloat,
                     recolorYellowTo accent: UIColor? = nil,
                     isCharacter: Bool = false) -> SCNNode? {
        guard let source = sourceNode(named: name) else { return nil }
        let copy = deepCopy(source)
        normalize(copy, toHeight: height)
        applyPaletteFinish(to: copy, recolorYellowTo: accent, isCharacter: isCharacter)
        let wrapper = SCNNode()
        wrapper.addChildNode(copy)
        return wrapper
    }

    private static func sourceNode(named name: String) -> SCNNode? {
        if let cached = sourceCache[name] { return cached }
        // Folder-reference bundles keep the HQAssets subdirectory; fall back to
        // a flat lookup in case the resources ever get regrouped.
        let url = Bundle.main.url(forResource: name, withExtension: "usdz", subdirectory: "HQAssets")
            ?? Bundle.main.url(forResource: name, withExtension: "usdz")
        guard let url,
              let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else {
            return nil
        }
        let holder = SCNNode()
        for child in scene.rootNode.childNodes { holder.addChildNode(child) }
        sourceCache[name] = holder
        return holder
    }

    /// The bundled skyline photograph (neon Pudong band cropped from the
    /// city-night panorama).
    static func skylineImage() -> UIImage? {
        let url = Bundle.main.url(forResource: "skyline_night", withExtension: "jpg", subdirectory: "HQAssets")
            ?? Bundle.main.url(forResource: "skyline_night", withExtension: "jpg")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: Instancing

    /// `SCNNode.clone()` shares geometry and materials — a recolor on one
    /// instance would repaint every other. Copy geometry + materials per node.
    private static func deepCopy(_ node: SCNNode) -> SCNNode {
        let copy = node.clone()
        copy.enumerateHierarchy { n, _ in
            guard let geometry = n.geometry else { return }
            let g = geometry.copy() as! SCNGeometry
            g.materials = geometry.materials.map { $0.copy() as! SCNMaterial }
            n.geometry = g
        }
        return copy
    }

    // MARK: Normalization

    /// Scale from true world bounds across every geometry node — the root
    /// node's own boundingBox lies for skinned/armature assets.
    private static func normalize(_ node: SCNNode, toHeight target: CGFloat) {
        var lo = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var hi = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        node.enumerateHierarchy { n, _ in
            guard n.geometry != nil else { return }
            let (a, b) = n.boundingBox
            for c in [SCNVector3(a.x, a.y, a.z), SCNVector3(b.x, a.y, a.z), SCNVector3(a.x, b.y, a.z),
                      SCNVector3(a.x, a.y, b.z), SCNVector3(b.x, b.y, a.z), SCNVector3(b.x, a.y, b.z),
                      SCNVector3(a.x, b.y, b.z), SCNVector3(b.x, b.y, b.z)] {
                let w = node.convertPosition(n.convertPosition(c, to: node), to: nil)
                lo = SCNVector3(min(lo.x, w.x), min(lo.y, w.y), min(lo.z, w.z))
                hi = SCNVector3(max(hi.x, w.x), max(hi.y, w.y), max(hi.z, w.z))
            }
        }
        let height = CGFloat(hi.y - lo.y)
        guard height > 0 else { return }
        let s = target / height
        node.scale = SCNVector3(s, s, s)
        node.position = SCNVector3(-CGFloat(lo.x + hi.x) / 2 * s,
                                   -CGFloat(lo.y) * s,
                                   -CGFloat(lo.z + hi.z) / 2 * s)
    }

    // MARK: Palette finish

    private static func applyPaletteFinish(to node: SCNNode,
                                           recolorYellowTo accent: UIColor?,
                                           isCharacter: Bool) {
        node.enumerateHierarchy { n, _ in
            for m in n.geometry?.materials ?? [] {
                // Strip the exporter's baked emission; intentional glow is
                // added by the scene, never by the asset.
                m.emission.contents = UIColor.black
                guard let (r, g, b) = linearRGB(of: m.diffuse.contents) else { continue }
                let maxc = max(r, g, b), minc = min(r, g, b)
                let sat = maxc == 0 ? 0 : (maxc - minc) / maxc
                if let accent, r > 0.6, g > 0.3, g < 0.85, b < 0.3 {
                    m.diffuse.contents = accent                    // accent → role color
                } else if isCharacter {
                    // keep body colors, but soften blinding factory whites so
                    // the light rig doesn't bloom the body
                    if sat < 0.25 && maxc > 0.5 {
                        m.diffuse.contents = UIColor(red: 0.60, green: 0.62, blue: 0.66, alpha: 1)
                    }
                } else if sat < 0.25 && maxc > 0.4 {
                    // light/mid greys & whites → dark graphite panels
                    m.diffuse.contents = UIColor(red: 0.16, green: 0.19, blue: 0.24, alpha: 1)
                    m.metalness.contents = 0.45; m.roughness.contents = 0.42
                } else if r > 0.25 && r > g && g > b && sat > 0.15 && sat < 0.6 {
                    // wood browns → charcoal lacquer
                    m.diffuse.contents = UIColor(red: 0.10, green: 0.115, blue: 0.15, alpha: 1)
                    m.metalness.contents = 0.35; m.roughness.contents = 0.4
                } else if b > 0.2 && b > r + 0.05 && sat > 0.3 {
                    // purples (sofa fabric) → deep navy
                    m.diffuse.contents = UIColor(red: 0.13, green: 0.17, blue: 0.28, alpha: 1)
                }
            }
        }
    }

    /// Raw linear components regardless of how the importer wrapped the color.
    private static func linearRGB(of contents: Any?) -> (CGFloat, CGFloat, CGFloat)? {
        var cgColor: CGColor?
        if let ui = contents as? UIColor {
            cgColor = ui.cgColor
        } else if let any = contents, CFGetTypeID(any as CFTypeRef) == CGColor.typeID {
            cgColor = (any as! CGColor)
        }
        guard let src = cgColor,
              let space = CGColorSpace(name: CGColorSpace.linearSRGB),
              let converted = src.converted(to: space, intent: .defaultIntent, options: nil),
              let comps = converted.components, comps.count >= 3 else { return nil }
        return (comps[0], comps[1], comps[2])
    }

    // MARK: Animation control

    /// Whether the asset carries a clip matching `match` — guard optional
    /// clips (Wave/Dance) so a missing clip never strands the rig in T-pose.
    static func hasAnimation(matching match: String, under node: SCNNode) -> Bool {
        var found = false
        node.enumerateHierarchy { n, stop in
            if n.animationKeys.contains(where: { $0.localizedCaseInsensitiveContains(match) }) {
                found = true; stop.pointee = true
            }
        }
        return found
    }

    /// The character USDZs carry all their skeletal clips and SceneKit plays
    /// every one at once on load. Keep only the clip whose key contains
    /// `match` (e.g. "Idle", "Walking"); stop the rest. Safe no-op when the
    /// asset carries no animations.
    static func playAnimation(matching match: String, under node: SCNNode) {
        node.enumerateHierarchy { n, _ in
            for key in n.animationKeys {
                guard let player = n.animationPlayer(forKey: key) else { continue }
                if key.localizedCaseInsensitiveContains(match) {
                    player.animation.usesSceneTimeBase = false
                    player.play()
                } else {
                    player.stop()
                }
            }
        }
    }
}
