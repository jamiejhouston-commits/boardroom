import SceneKit
import SwiftUI
import UIKit

// MARK: - The seven divisions

/// The client-services divisions housed on the Divisions Floor (floor 2).
/// Each owns a production bay upstairs; tapping a bay's board opens the
/// division sheet — mission, honest status, and a commission field that
/// routes through the same directive flow the Boardroom uses.
/// Raw values match the relay's `division` tags on initiatives.
enum HQDivision: String, CaseIterable, Identifiable {
    case webapps, saas, ecommerce, automations, consulting, accounting, legal, growth

    var id: String { rawValue }

    var name: String {
        switch self {
        case .webapps:     "Webapps"
        case .saas:        "SaaS"
        case .ecommerce:   "E-Commerce"
        case .automations: "Workflow Automations"
        case .consulting:  "Business Consulting"
        case .accounting:  "Accounting"
        case .legal:       "Legal"
        case .growth:      "Growth"
        }
    }

    /// One-line mission shown at the top of the bay sheet.
    var mission: String {
        switch self {
        case .webapps:     "Ship polished web apps clients can put in front of customers on day one."
        case .saas:        "Build subscription products that earn recurring revenue while we sleep."
        case .ecommerce:   "Stand up storefronts that turn browsers into buyers."
        case .automations: "Automate the repetitive work out of a client's week."
        case .consulting:  "Turn a founder's fog into a plan with numbers attached."
        case .accounting:  "Keep the books clean, the taxes filed, and the cash visible."
        case .legal:       "Write the privacy policies, terms, and compliance docs our own products ship with."
        case .growth:      "Build the launch kits that sell what we ship — copy, landing pages, post drafts you approve."
        }
    }

    /// Glyph plate beside the bay sign (same treatment as the 🎮 downstairs).
    var glyph: String {
        switch self {
        case .webapps:     "🌐"
        case .saas:        "☁️"
        case .ecommerce:   "🛒"
        case .automations: "⚙️"
        case .consulting:  "📈"
        case .accounting:  "🧾"
        case .legal:       "⚖️"
        case .growth:      "📣"
        }
    }

    /// Lowercased fragments that count an initiative as this division's work.
    /// ponytail: substring match on title+pitch — the honest, cheap heuristic;
    /// only claims LEGACY initiatives the relay never tagged (see `owns`).
    var keywords: [String] {
        switch self {
        case .webapps:     ["webapp", "web app", "website", "web site", "web-app"]
        case .saas:        ["saas", "subscription"]
        case .ecommerce:   ["e-commerce", "ecommerce", "storefront", "online store", "shopify", "online shop"]
        case .automations: ["workflow", "automation", "automate"]
        case .consulting:  ["consulting", "consultan", "advisory"]
        case .accounting:  ["accounting", "bookkeep", "ledger", "payroll"]
        case .legal:       ["legal", "privacy", "terms", "policy", "compliance", "license"]
        case .growth:      ["launch kit", "marketing", "app store copy", "landing page", "aso"]
        }
    }

    /// Honest match: the initiative's title or pitch mentions the division.
    func matches(_ initiative: CompanyInitiative) -> Bool {
        let haystack = (initiative.title + " " + initiative.pitch).lowercased()
        return keywords.contains { haystack.contains($0) }
    }

    /// Real ownership: the relay's `division` tag wins; the keyword heuristic
    /// is the fallback only for legacy initiatives that were never tagged.
    func owns(_ initiative: CompanyInitiative) -> Bool {
        if let tagged = initiative.division, !tagged.isEmpty {
            return tagged == rawValue
        }
        return matches(initiative)
    }

    // MARK: Tap routing

    static let tapPrefix = "hq.tap.division."
    var tapName: String { Self.tapPrefix + rawValue }

    static func division(forNodeName name: String?) -> HQDivision? {
        guard let name, name.hasPrefix(tapPrefix) else { return nil }
        return HQDivision(rawValue: String(name.dropFirst(tapPrefix.count)))
    }
}

// MARK: - Scene builder

/// Builds the Divisions Floor — a second storey stacked on +Y above the HQ
/// (elevation from `HQRoamMath.divisionsElevation`, the single source the
/// roam clamps also use) — plus the elevator markers on both floors. Travel
/// is a teleport of the player rig; the whole storey is one node the scene
/// view hides except while roaming upstairs, so the overview/orbit cameras
/// keep their proven ground-floor framing.
enum HQDivisionsFloor {

    /// Root node of the storey — HQSceneView toggles its visibility on travel.
    static let floorNodeName = "hq.floor2"
    /// Tap-routing names for the elevator markers.
    static let elevatorUpName = "hq.tap.elevator.up"
    static let elevatorDownName = "hq.tap.elevator.down"

    static func build(into root: SCNNode) {
        let up = zoneCenter(HQRoamMath.groundElevatorZone)
        addElevator(to: root, name: elevatorUpName, label: "DIVISIONS ↑",
                    at: SCNVector3(up.x, 0, up.z))

        let storey = SCNNode()
        storey.name = floorNodeName
        storey.position = SCNVector3(0, HQRoamMath.divisionsElevation, 0)
        storey.isHidden = true                    // shown only while roaming upstairs
        root.addChildNode(storey)

        addShell(to: storey)
        addLights(to: storey)
        let down = zoneCenter(HQRoamMath.divisionsElevatorZone)
        addElevator(to: storey, name: elevatorDownName, label: "LOBBY ↓",
                    at: SCNVector3(down.x, 0, down.z))

        // Eight bays: four against the north wall, four against the south,
        // fronts (local +Z, like the Production Bay's) turned toward the
        // center aisle. Accents alternate emerald/steel down each wall.
        let north: [HQDivision] = [.webapps, .saas, .ecommerce, .automations]
        let south: [HQDivision] = [.consulting, .accounting, .legal, .growth]
        for (i, division) in north.enumerated() {
            addBay(division, at: (Float(i) - 1.5) * 8.0, z: -10.55, yaw: 0,
                   accent: i.isMultiple(of: 2) ? HQSceneBuilder.emerald : HQSceneBuilder.steel,
                   to: storey)
        }
        for (i, division) in south.enumerated() {
            addBay(division, at: (Float(i) - 1.5) * 8.0, z: 10.55, yaw: .pi,
                   accent: i.isMultiple(of: 2) ? HQSceneBuilder.emerald : HQSceneBuilder.steel,
                   to: storey)
        }
    }

    private static func zoneCenter(_ z: (minX: Float, maxX: Float, minZ: Float, maxZ: Float))
        -> (x: Float, z: Float) {
        ((z.minX + z.maxX) / 2, (z.minZ + z.maxZ) / 2)
    }

    // MARK: Shell — slab, walls, trim, ceiling (ground floor's proven recipe)

    private static func addShell(to storey: SCNNode) {
        let slab = SCNBox(width: 33, height: 0.3, length: 23, chamferRadius: 0)
        let slabMat = SCNMaterial()
        slabMat.lightingModel = .physicallyBased
        slabMat.diffuse.contents = UIColor(red: 0.03, green: 0.038, blue: 0.055, alpha: 1)
        slabMat.metalness.contents = 0.2
        slabMat.roughness.contents = 0.55
        slab.materials = [slabMat]
        let slabNode = SCNNode(geometry: slab)
        slabNode.position = SCNVector3(0, -0.15, 0)
        storey.addChildNode(slabNode)

        // Emerald aisle seams down the middle, like the lobby's grid.
        for z in [Float(-3.4), 3.4] {
            let seam = SCNBox(width: 30, height: 0.015, length: 0.09, chamferRadius: 0)
            let m = SCNMaterial()
            m.diffuse.contents = UIColor.black
            m.emission.contents = HQSceneBuilder.emerald
            seam.materials = [m]
            let n = SCNNode(geometry: seam)
            n.position = SCNVector3(0, 0.012, z)
            n.opacity = 0.75
            storey.addChildNode(n)
        }

        let wallMat = SCNMaterial()
        wallMat.lightingModel = .physicallyBased
        wallMat.diffuse.contents = UIColor(red: 0.045, green: 0.055, blue: 0.08, alpha: 1)
        wallMat.metalness.contents = 0.15
        wallMat.roughness.contents = 0.6

        for z in [Float(-11), 11] {
            let wall = SCNBox(width: 32.4, height: 4.6, length: 0.4, chamferRadius: 0)
            wall.materials = [wallMat]
            let n = SCNNode(geometry: wall)
            n.position = SCNVector3(0, 2.3, z)
            storey.addChildNode(n)

            // The emission-strip trick — a thin emerald line riding each wall.
            let trim = SCNBox(width: 32.4, height: 0.05, length: 0.42, chamferRadius: 0)
            let tm = SCNMaterial()
            tm.diffuse.contents = UIColor.black
            tm.emission.contents = HQSceneBuilder.emerald
            trim.materials = [tm]
            let tn = SCNNode(geometry: trim)
            tn.position = SCNVector3(0, 1.15, z)
            tn.opacity = 0.8
            storey.addChildNode(tn)
        }
        for x in [Float(-16), 16] {
            let wall = SCNBox(width: 0.4, height: 4.6, length: 22.4, chamferRadius: 0)
            wall.materials = [wallMat]
            let n = SCNNode(geometry: wall)
            n.position = SCNVector3(x, 2.3, 0)
            storey.addChildNode(n)
        }

        // Lit ceiling panels — single-sided, facing DOWN only (double-sided
        // tops read as floating slabs from any elevated camera).
        for gx in [Float(-8), 0, 8] {
            for gz in [Float(-5), 5] {
                let p = SCNPlane(width: 2.4, height: 2.4)
                let m = SCNMaterial()
                m.diffuse.contents = UIColor.black
                m.emission.contents = UIColor(red: 0.75, green: 0.85, blue: 1.0, alpha: 1)
                m.emission.intensity = 1.1
                m.isDoubleSided = false
                p.materials = [m]
                let n = SCNNode(geometry: p)
                n.position = SCNVector3(gx, 4.5, gz)
                n.eulerAngles.x = .pi / 2   // +Z normal → −Y (down)
                storey.addChildNode(n)
            }
        }
    }

    // MARK: Lights (emissives don't illuminate — three real omnis do)

    private static func addLights(to storey: SCNNode) {
        for gx in [Float(-8), 0, 8] {
            let light = SCNLight()
            light.type = .omni
            light.color = UIColor(red: 0.72, green: 0.82, blue: 1.0, alpha: 1)
            light.intensity = 240
            light.attenuationStartDistance = 2
            light.attenuationEndDistance = 16
            let node = SCNNode()
            node.light = light
            node.position = SCNVector3(gx, 4.0, 0)
            storey.addChildNode(node)
        }
    }

    // MARK: Elevator markers — walk in (or tap) to ride between floors

    private static func addElevator(to parent: SCNNode, name: String, label: String,
                                    at position: SCNVector3) {
        let marker = SCNNode()
        marker.name = name                       // children route taps via parent-walk
        marker.position = position

        let pad = SCNCylinder(radius: 1.0, height: 0.12)
        let pm = SCNMaterial()
        pm.lightingModel = .physicallyBased
        pm.diffuse.contents = UIColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1)
        pm.metalness.contents = 0.5
        pm.roughness.contents = 0.35
        pad.materials = [pm]
        let padNode = SCNNode(geometry: pad)
        padNode.position = SCNVector3(0, 0.06, 0)
        marker.addChildNode(padNode)

        let ring = SCNTorus(ringRadius: 1.0, pipeRadius: 0.03)
        let rm = SCNMaterial()
        rm.diffuse.contents = UIColor.black
        rm.emission.contents = HQSceneBuilder.gold
        rm.emission.intensity = 0.9
        ring.materials = [rm]
        let ringNode = SCNNode(geometry: ring)
        ringNode.position = SCNVector3(0, 0.13, 0)
        marker.addChildNode(ringNode)

        // A soft emerald shaft so the lift reads as a way through — gentle
        // pulse, same restraint as the Games Studio threshold.
        let shaft = SCNCylinder(radius: 0.85, height: 3.0)
        let sm = SCNMaterial()
        sm.diffuse.contents = UIColor.black
        sm.emission.contents = HQSceneBuilder.emerald
        sm.emission.intensity = 0.4
        sm.transparency = 0.22
        sm.isDoubleSided = true
        shaft.materials = [sm]
        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.position = SCNVector3(0, 1.62, 0)
        let pulse = SCNAction.sequence([
            .customAction(duration: 1.6) { n, t in
                n.geometry?.firstMaterial?.emission.intensity = 0.25 + 0.3 * (t / 1.6)
            },
            .customAction(duration: 1.6) { n, t in
                n.geometry?.firstMaterial?.emission.intensity = 0.55 - 0.3 * (t / 1.6)
            },
        ])
        shaftNode.runAction(.repeatForever(pulse))
        marker.addChildNode(shaftNode)

        // Destination sign, billboarded so it reads from any approach.
        let sign = SCNText(string: label, extrusionDepth: 0.4)
        sign.font = UIFont.systemFont(ofSize: 5, weight: .bold)
        sign.flatness = 0.15
        let signMat = SCNMaterial()
        signMat.diffuse.contents = UIColor.black
        signMat.emission.contents = HQSceneBuilder.gold
        signMat.emission.intensity = 1.0
        sign.materials = [signMat]
        let signNode = SCNNode(geometry: sign)
        signNode.scale = SCNVector3(0.055, 0.055, 0.055)
        let (lo, hi) = signNode.boundingBox
        signNode.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, 0, 0)
        signNode.position = SCNVector3(0, 3.35, 0)
        signNode.constraints = [SCNBillboardConstraint()]
        marker.addChildNode(signNode)

        // A soft real light so the lift casts into the room.
        let light = SCNLight()
        light.type = .omni
        light.color = HQSceneBuilder.emerald
        light.intensity = 220
        light.attenuationEndDistance = 6
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(0, 1.8, 0)
        marker.addChildNode(lightNode)

        parent.addChildNode(marker)
    }

    // MARK: Production bays — signage, board, desk vignette

    /// One division bay: a wall slab carrying the gold sign + glyph, a framed
    /// accent board (the tap target — the whole bay routes to the sheet), and
    /// a staffed-looking desk vignette in the division's accent.
    private static func addBay(_ division: HQDivision, at x: Float, z: Float, yaw: Float,
                               accent: UIColor, to storey: SCNNode) {
        let bay = SCNNode()
        bay.name = division.tapName
        bay.position = SCNVector3(x, 0, z)
        bay.eulerAngles.y = yaw

        // Backdrop slab against the wall — same treatment as the pod totems.
        let slab = SCNBox(width: 7.2, height: 3.4, length: 0.18, chamferRadius: 0.03)
        let slabMat = SCNMaterial()
        slabMat.lightingModel = .physicallyBased
        slabMat.diffuse.contents = UIColor(red: 0.07, green: 0.085, blue: 0.115, alpha: 1)
        slabMat.metalness.contents = 0.4
        slabMat.roughness.contents = 0.4
        slab.materials = [slabMat]
        let slabNode = SCNNode(geometry: slab)
        slabNode.position = SCNVector3(0, 1.7, 0)
        bay.addChildNode(slabNode)

        // Division sign in gold, centered above the board.
        let sign = SCNText(string: division.name.uppercased(), extrusionDepth: 0.4)
        sign.font = UIFont.systemFont(ofSize: 5, weight: .bold)
        sign.flatness = 0.15
        let signMat = SCNMaterial()
        signMat.diffuse.contents = UIColor.black
        signMat.emission.contents = HQSceneBuilder.gold
        signMat.emission.intensity = 1.0
        sign.materials = [signMat]
        let signNode = SCNNode(geometry: sign)
        signNode.scale = SCNVector3(0.042, 0.042, 0.042)
        let (lo, hi) = signNode.boundingBox
        signNode.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, 0, 0)
        signNode.position = SCNVector3(0, 2.85, 0.12)
        bay.addChildNode(signNode)

        // Glyph plate beside the sign so the bay reads at a glance.
        let glyph = SCNText(string: division.glyph, extrusionDepth: 0.2)
        glyph.font = UIFont.systemFont(ofSize: 5)
        glyph.flatness = 0.2
        let glyphNode = SCNNode(geometry: glyph)
        glyphNode.scale = SCNVector3(0.04, 0.04, 0.04)
        glyphNode.position = SCNVector3(-3.35, 2.82, 0.12)
        bay.addChildNode(glyphNode)

        // The board: gold-framed accent panel — the visual tap target.
        let frame = SCNBox(width: 3.9, height: 1.85, length: 0.1, chamferRadius: 0.03)
        let frameMat = SCNMaterial()
        frameMat.lightingModel = .physicallyBased
        frameMat.diffuse.contents = UIColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1)
        frameMat.metalness.contents = 0.55
        frameMat.roughness.contents = 0.35
        frame.materials = [frameMat]
        let frameNode = SCNNode(geometry: frame)
        frameNode.position = SCNVector3(0, 1.55, 0.1)
        bay.addChildNode(frameNode)

        let board = SCNPlane(width: 3.6, height: 1.55)
        let bm = SCNMaterial()
        bm.diffuse.contents = UIColor.black
        bm.emission.contents = accent
        bm.emission.intensity = 0.55           // readable, never neon
        board.materials = [bm]
        let boardNode = SCNNode(geometry: board)
        boardNode.position = SCNVector3(0, 1.55, 0.16)
        bay.addChildNode(boardNode)

        let hint = SCNText(string: "TAP FOR STATUS", extrusionDepth: 0.2)
        hint.font = UIFont.systemFont(ofSize: 5, weight: .semibold)
        hint.flatness = 0.2
        let hintMat = SCNMaterial()
        hintMat.diffuse.contents = UIColor.black
        hintMat.emission.contents = UIColor(red: 0.68, green: 0.72, blue: 0.78, alpha: 1)
        hintMat.emission.intensity = 0.8
        hint.materials = [hintMat]
        let hintNode = SCNNode(geometry: hint)
        hintNode.scale = SCNVector3(0.02, 0.02, 0.02)
        let (hlo, hhi) = hintNode.boundingBox
        hintNode.pivot = SCNMatrix4MakeTranslation((hlo.x + hhi.x) / 2, 0, 0)
        hintNode.position = SCNVector3(0, 0.92, 0.17)
        bay.addChildNode(hintNode)

        // Desk vignette in front of the board — asset with primitive fallback.
        HQSceneBuilder.placeAsset("Desk", height: 1.0, accent: accent, at: (0, 1.8), in: bay)
        HQSceneBuilder.placeAsset("Computer", height: 0.55, accent: accent, at: (0, 1.8), in: bay)
        HQSceneBuilder.placeAsset("OfficeChair", height: 1.15, accent: accent,
                                  at: (0, 0.95), rotY: .pi, in: bay)
        addFlavorProp(for: division, accent: accent, to: bay)

        storey.addChildNode(bay)
    }

    /// One prop in the division's flavor so the bays don't read identical.
    private static func addFlavorProp(for division: HQDivision, accent: UIColor, to bay: SCNNode) {
        switch division {
        case .webapps:
            HQSceneBuilder.placeAsset("ComputerLarge", height: 1.4, accent: accent,
                                      at: (2.4, 1.2), in: bay)
        case .saas:
            // A slim server tower with an accent status strip.
            let tower = SCNBox(width: 0.6, height: 1.7, length: 0.6, chamferRadius: 0.04)
            let tm = SCNMaterial()
            tm.lightingModel = .physicallyBased
            tm.diffuse.contents = UIColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1)
            tm.metalness.contents = 0.5
            tm.roughness.contents = 0.35
            tower.materials = [tm]
            let towerNode = SCNNode(geometry: tower)
            towerNode.position = SCNVector3(2.4, 0.85, 1.2)
            bay.addChildNode(towerNode)
            let strip = SCNBox(width: 0.04, height: 1.3, length: 0.02, chamferRadius: 0)
            let sm = SCNMaterial()
            sm.diffuse.contents = UIColor.black
            sm.emission.contents = accent
            strip.materials = [sm]
            let stripNode = SCNNode(geometry: strip)
            stripNode.position = SCNVector3(2.2, 0.85, 1.51)
            bay.addChildNode(stripNode)
        case .ecommerce:
            // A short stack of parcel crates by the desk.
            for (i, size) in [CGFloat(0.7), 0.55].enumerated() {
                let crate = HQSceneBuilder.fallbackBox(
                    w: size, h: size * 0.8, l: size,
                    color: UIColor(red: 0.10, green: 0.09, blue: 0.075, alpha: 1))
                crate.position = SCNVector3(2.4, Float(i) * 0.56, 1.4)
                crate.eulerAngles.y = Float(i) * 0.5
                bay.addChildNode(crate)
            }
        case .automations:
            // A slowly turning cog ring — the line, always in motion.
            let cog = SCNTorus(ringRadius: 0.5, pipeRadius: 0.09)
            let cm = SCNMaterial()
            cm.lightingModel = .physicallyBased
            cm.diffuse.contents = UIColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1)
            cm.metalness.contents = 0.6
            cm.roughness.contents = 0.35
            cog.materials = [cm]
            let cogNode = SCNNode(geometry: cog)
            cogNode.position = SCNVector3(2.4, 1.1, 1.2)
            cogNode.eulerAngles.x = .pi / 2
            cogNode.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: .pi * 2, duration: 18)))
            bay.addChildNode(cogNode)
        case .consulting:
            HQSceneBuilder.placeAsset("Sofa", height: 0.95, accent: accent,
                                      at: (2.6, 1.4), rotY: -.pi / 2, in: bay)
        case .accounting:
            HQSceneBuilder.placeAsset("BookcaseBooks", height: 2.0, accent: nil,
                                      at: (2.7, 0.6), in: bay)
        case .legal:
            // A courthouse column with a square capital — muted stone, no glow.
            let stone = UIColor(red: 0.42, green: 0.44, blue: 0.48, alpha: 1)
            let column = SCNCylinder(radius: 0.22, height: 1.6)
            let cm = SCNMaterial()
            cm.lightingModel = .physicallyBased
            cm.diffuse.contents = stone
            cm.metalness.contents = 0.1
            cm.roughness.contents = 0.55
            column.materials = [cm]
            let columnNode = SCNNode(geometry: column)
            columnNode.position = SCNVector3(2.4, 0.8, 1.2)
            bay.addChildNode(columnNode)
            let cap = HQSceneBuilder.fallbackBox(w: 0.62, h: 0.14, l: 0.62, color: stone)
            cap.position = SCNVector3(2.4, 1.6, 1.2)
            bay.addChildNode(cap)
        case .growth:
            // A megaphone read as pure geometry: a tilted cone on a stand —
            // muted brass, no glow (palette rule).
            let brass = UIColor(red: 0.45, green: 0.38, blue: 0.24, alpha: 1)
            let horn = SCNCone(topRadius: 0.3, bottomRadius: 0.06, height: 0.7)
            let hm = SCNMaterial()
            hm.lightingModel = .physicallyBased
            hm.diffuse.contents = brass
            hm.metalness.contents = 0.55
            hm.roughness.contents = 0.4
            horn.materials = [hm]
            let hornNode = SCNNode(geometry: horn)
            hornNode.position = SCNVector3(2.4, 1.15, 1.2)
            hornNode.eulerAngles.z = -.pi / 3
            bay.addChildNode(hornNode)
            let stand = HQSceneBuilder.fallbackBox(
                w: 0.5, h: 0.8, l: 0.5,
                color: UIColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1))
            stand.position = SCNVector3(2.4, 0.4, 1.2)
            bay.addChildNode(stand)
        }
    }
}

// MARK: - Division sheet (mission, honest status, commission work)

/// Opened by tapping a bay's board upstairs. Status is computed live from
/// the same `CompanyStore` state the boards render — no new endpoints; the
/// commission button reuses the Boardroom's directive flow with a division
/// prefix so the CEO knows which bay asked.
struct HQDivisionSheet: View {
    let division: HQDivision

    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @Environment(\.dismiss) private var dismiss
    @State private var directive = ""
    @State private var sending = false

    private var matching: [CompanyInitiative] {
        company.state.initiatives.filter(division.owns)
    }

    var body: some View {
        List {
            Section("Mission") {
                Text(division.mission)
                    .font(.subheadline)
            }

            Section("Status") {
                if matching.isEmpty {
                    Text("No work commissioned yet")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(matching.count) initiative\(matching.count == 1 ? "" : "s") in this division")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(matching) { initiative in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(initiative.title)
                                .font(.subheadline.weight(.semibold))
                            Text(initiative.stageLabel)
                                .font(.caption)
                                .foregroundStyle(initiative.isAwaitingDecision
                                                 ? HermesTheme.gold : .secondary)
                            if let live = initiative.liveUrl, !live.isEmpty,
                               let url = URL(string: live) {
                                Link(destination: url) {
                                    HStack(spacing: 5) {
                                        Circle().fill(HermesTheme.emerald)
                                            .frame(width: 6, height: 6)
                                        Text("LIVE")
                                            .font(.caption2.weight(.bold))
                                        Text(live)
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .foregroundStyle(HermesTheme.emerald)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Commission work") {
                TextField("What should the \(division.name) team build?",
                          text: $directive, axis: .vertical)
                    .lineLimit(2...5)
                Button {
                    commission()
                } label: {
                    Label("Commission work", systemImage: "paperplane.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(directive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || sending)
            }

            if let error = company.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .navigationTitle(division.name)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(sending)
        .overlay { if sending { ProgressView() } }
    }

    private func commission() {
        let text = directive.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        Task {
            await company.submitDirective("[\(division.name) division] \(text)",
                                          relay: runtime.relayConfiguration)
            sending = false
            if company.errorMessage == nil { dismiss() }
        }
    }
}
