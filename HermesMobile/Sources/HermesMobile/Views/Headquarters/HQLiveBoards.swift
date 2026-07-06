import SceneKit
import SpriteKit
import UIKit

/// The room's live surfaces — real company data physically in the HQ:
/// - War Board (east wall): initiatives with stage + progress bars
/// - Kanban board (west wall): the task backlog by column
/// - News ticker (north wall): the company event feed as a marquee
/// - Decision Desk (by the executive steps): pending gates, badge + soft pulse
///
/// Each board is an SCNPlane whose material renders a SpriteKit scene, so text
/// stays crisp and updates are just node redraws — no scene rebuilds, no extra
/// lights. Boards are named `hq.tap.*` so the HQ tap handler can route them to
/// their SwiftUI sheets. `update(root:state:)` is cheap and idempotent; the
/// caller gates it behind a company-state signature so it runs only on change.
enum HQLiveBoards {

    // MARK: Tap routing names

    static let warBoardName = "hq.tap.warboard"
    static let kanbanName = "hq.tap.kanban"
    static let gateDeskName = "hq.tap.gatedesk"
    static let tickerName = "hq.ticker"
    private static let gateBadgeName = "hq.gatedesk.badge"
    private static let gateRingName = "hq.gatedesk.ring"

    /// What a tapped board opens.
    enum Kind { case warBoard, kanban, gates, production }

    static func kind(forNodeName name: String?) -> Kind? {
        switch name {
        case warBoardName:                        .warBoard
        case kanbanName:                          .kanban
        case gateDeskName:                        .gates
        case HQSceneBuilder.productionBayName:    .production
        default:                                  nil
        }
    }

    // MARK: Palette (mirrors HQSceneBuilder — muted, never neon)

    private static let bg = UIColor(red: 0.045, green: 0.058, blue: 0.085, alpha: 1)
    private static let panel = UIColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1)
    private static let textBright = UIColor(red: 0.88, green: 0.90, blue: 0.94, alpha: 1)
    private static let textDim = UIColor(red: 0.55, green: 0.60, blue: 0.68, alpha: 1)
    private static let emerald = HQSceneBuilder.emerald
    private static let gold = HQSceneBuilder.gold
    private static let silver = UIColor(red: 0.68, green: 0.72, blue: 0.78, alpha: 1)

    private static let fontBold = "HelveticaNeue-Bold"
    private static let fontSemi = "HelveticaNeue-Medium"

    // MARK: Factories (built once by HQSceneBuilder)

    static func warBoardNode() -> SCNNode {
        framedBoard(name: warBoardName, width: 7.4, height: 3.5,
                    sceneSize: CGSize(width: 1024, height: 484), title: "WAR BOARD")
    }

    static func kanbanNode() -> SCNNode {
        framedBoard(name: kanbanName, width: 5.8, height: 3.1,
                    sceneSize: CGSize(width: 896, height: 480), title: "TASKS")
    }

    static func tickerNode() -> SCNNode {
        let scene = boardScene(size: CGSize(width: 2048, height: 72))
        scene.backgroundColor = UIColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 1)
        let plane = SCNPlane(width: 23, height: 0.78)
        plane.materials = [boardMaterial(scene: scene)]
        let node = SCNNode(geometry: plane)
        node.name = tickerName
        return node
    }

    /// The Decision Desk: a gold-trimmed pedestal with a floating brief and a
    /// pending-gate count. Pulses (softly) only while a decision waits.
    static func gateDeskNode() -> SCNNode {
        let desk = SCNNode()
        desk.name = gateDeskName

        let column = SCNCylinder(radius: 0.4, height: 1.02)
        let cm = SCNMaterial()
        cm.lightingModel = .physicallyBased
        cm.diffuse.contents = UIColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1)
        cm.metalness.contents = 0.5
        cm.roughness.contents = 0.35
        column.materials = [cm]
        let columnNode = SCNNode(geometry: column)
        columnNode.position = SCNVector3(0, 0.51, 0)
        desk.addChildNode(columnNode)

        let ring = SCNTorus(ringRadius: 0.42, pipeRadius: 0.022)
        let rm = SCNMaterial()
        rm.diffuse.contents = UIColor.black
        rm.emission.contents = gold
        rm.emission.intensity = 0.0            // lit only when gates wait
        ring.materials = [rm]
        let ringNode = SCNNode(geometry: ring)
        ringNode.name = gateRingName
        ringNode.position = SCNVector3(0, 1.04, 0)
        desk.addChildNode(ringNode)

        // The floating brief — a slim document hovering above the pedestal.
        let doc = SCNBox(width: 0.46, height: 0.6, length: 0.02, chamferRadius: 0.01)
        let dm = SCNMaterial()
        dm.lightingModel = .physicallyBased
        dm.diffuse.contents = UIColor(red: 0.85, green: 0.86, blue: 0.88, alpha: 1)
        dm.roughness.contents = 0.7
        doc.materials = [dm]
        let docNode = SCNNode(geometry: doc)
        docNode.position = SCNVector3(0, 1.55, 0)
        docNode.eulerAngles.y = -0.35
        let hover = SCNAction.sequence([
            .moveBy(x: 0, y: 0.07, z: 0, duration: 1.8),
            .moveBy(x: 0, y: -0.07, z: 0, duration: 1.8),
        ])
        hover.timingMode = .easeInEaseOut
        docNode.runAction(.repeatForever(hover))
        docNode.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 22)))
        desk.addChildNode(docNode)

        // Badge: "N" pending decisions, billboarded to always face the player.
        let text = SCNText(string: "", extrusionDepth: 0.4)
        text.font = UIFont.systemFont(ofSize: 5, weight: .bold)
        text.flatness = 0.15
        let tm = SCNMaterial()
        tm.diffuse.contents = UIColor.black
        tm.emission.contents = gold
        tm.emission.intensity = 0.9
        text.materials = [tm]
        let badge = SCNNode(geometry: text)
        badge.name = gateBadgeName
        badge.scale = SCNVector3(0.075, 0.075, 0.075)
        badge.position = SCNVector3(0, 2.05, 0)
        badge.constraints = [SCNBillboardConstraint()]
        desk.addChildNode(badge)

        return desk
    }

    // MARK: Live updates (called only when the company signature changes)

    static func update(root: SCNNode, state: CompanyState) {
        if let scene = boardScene(under: root, named: warBoardName) {
            drawWarBoard(scene, initiatives: Array(state.initiatives.suffix(7)).reversed())
        }
        if let scene = boardScene(under: root, named: kanbanName) {
            drawKanban(scene, tasks: state.tasks ?? [])
        }
        if let scene = boardScene(under: root, named: tickerName) {
            drawTicker(scene, events: state.events ?? [])
        }
        updateGateDesk(under: root, pending: state.initiatives.filter(\.isAwaitingDecision).count)
    }

    // MARK: War board

    private static func drawWarBoard(_ scene: SKScene, initiatives: [CompanyInitiative]) {
        redraw(scene, title: "WAR BOARD") { content, size in
            guard !initiatives.isEmpty else {
                content.addChild(emptyLabel("No initiatives yet — the company is scouting.", at: CGPoint(x: size.width / 2, y: size.height / 2)))
                return
            }
            let rowH: CGFloat = (size.height - 84) / CGFloat(max(initiatives.count, 4))
            for (i, initiative) in initiatives.enumerated() {
                let y = size.height - 92 - CGFloat(i) * rowH
                let title = label(String(initiative.title.prefix(30)), font: fontSemi, size: 26,
                                  color: initiative.isTerminal ? textDim : textBright,
                                  at: CGPoint(x: 28, y: y), align: .left)
                content.addChild(title)

                let stageColor: UIColor = initiative.isAwaitingDecision ? gold
                    : initiative.stage == "shipped" ? emerald
                    : initiative.stage == "killed" ? silver.withAlphaComponent(0.6)
                    : emerald.withAlphaComponent(0.85)
                content.addChild(label(String(initiative.stageLabel.prefix(24)), font: fontSemi, size: 20,
                                       color: stageColor,
                                       at: CGPoint(x: size.width - 28, y: y), align: .right))

                // Progress bar under the row.
                let barW = size.width - 56
                let track = SKShapeNode(rect: CGRect(x: 28, y: y - 22, width: barW, height: 6), cornerRadius: 3)
                track.fillColor = panel; track.strokeColor = .clear
                content.addChild(track)
                let fillW = max(6, barW * CGFloat(initiative.progress))
                let fill = SKShapeNode(rect: CGRect(x: 28, y: y - 22, width: fillW, height: 6), cornerRadius: 3)
                fill.fillColor = initiative.isAwaitingDecision ? gold : emerald
                fill.strokeColor = .clear
                fill.alpha = initiative.isTerminal && initiative.stage == "killed" ? 0.25 : 0.9
                content.addChild(fill)
            }
        }
    }

    // MARK: Kanban

    private static func drawKanban(_ scene: SKScene, tasks: [CompanyTask]) {
        redraw(scene, title: "TASKS") { content, size in
            let columns: [(String, String, UIColor)] = [
                ("todo", "TO DO", silver), ("doing", "DOING", gold), ("done", "DONE", emerald),
            ]
            let colW = size.width / 3
            for (i, column) in columns.enumerated() {
                let x = colW * CGFloat(i) + colW / 2
                let items = tasks.filter { $0.status == column.0 }
                content.addChild(label("\(column.1) · \(items.count)", font: fontBold, size: 24,
                                       color: column.2, at: CGPoint(x: x, y: size.height - 92)))
                for (j, task) in items.prefix(4).enumerated() {
                    let y = size.height - 140 - CGFloat(j) * 62
                    let card = SKShapeNode(rect: CGRect(x: x - colW / 2 + 16, y: y - 20,
                                                        width: colW - 32, height: 50), cornerRadius: 8)
                    card.fillColor = panel
                    card.strokeColor = column.2.withAlphaComponent(0.35)
                    card.lineWidth = 1.5
                    content.addChild(card)
                    content.addChild(label(String(task.text.prefix(18)), font: fontSemi, size: 19,
                                           color: textBright, at: CGPoint(x: x, y: y - 2)))
                }
                if items.isEmpty {
                    content.addChild(label("—", font: fontSemi, size: 22, color: textDim,
                                           at: CGPoint(x: x, y: size.height - 150)))
                }
            }
        }
    }

    // MARK: Ticker

    private static func drawTicker(_ scene: SKScene, events: [CompanyEvent]) {
        let recent = events.suffix(6).reversed().map(\.text)
        let string = recent.isEmpty
            ? "BOARDROOM · all quiet — the company is standing by"
            : recent.joined(separator: "      •      ")
        // Skip the rebuild when the feed hasn't changed — keeps the marquee smooth.
        if scene.userData?["text"] as? String == string { return }
        scene.userData = NSMutableDictionary(dictionary: ["text": string])
        scene.removeAllChildren()

        let node = label(string, font: fontSemi, size: 34, color: textBright.withAlphaComponent(0.92),
                         at: .zero, align: .left)
        node.verticalAlignmentMode = .center
        node.position = CGPoint(x: scene.size.width, y: scene.size.height / 2)
        scene.addChild(node)
        let width = node.frame.width
        let travel = scene.size.width + width + 40
        let sweep = SCNActionizedSKAction.marquee(travel: travel, speed: 130)
        node.run(sweep)
    }

    // MARK: Gate desk

    private static func updateGateDesk(under root: SCNNode, pending: Int) {
        guard let desk = root.childNode(withName: gateDeskName, recursively: true) else { return }
        if let badge = desk.childNode(withName: gateBadgeName, recursively: true),
           let text = badge.geometry as? SCNText {
            text.string = pending > 0 ? "\(pending)" : ""
            // SCNText draws from its baseline origin — recenter after each change.
            let (lo, hi) = badge.boundingBox
            badge.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, 0, 0)
        }
        if let ring = desk.childNode(withName: gateRingName, recursively: true),
           let material = ring.geometry?.firstMaterial {
            ring.removeAction(forKey: "pulse")
            if pending > 0 {
                material.emission.intensity = 1.0
                let pulse = SCNAction.sequence([
                    .customAction(duration: 0.9) { n, t in
                        n.geometry?.firstMaterial?.emission.intensity = 0.45 + 0.55 * t / 0.9
                    },
                    .customAction(duration: 0.9) { n, t in
                        n.geometry?.firstMaterial?.emission.intensity = 1.0 - 0.55 * t / 0.9
                    },
                ])
                ring.runAction(.repeatForever(pulse), forKey: "pulse")
            } else {
                material.emission.intensity = 0.0
            }
        }
    }

    // MARK: Board plumbing

    private static func framedBoard(name: String, width: CGFloat, height: CGFloat,
                                    sceneSize: CGSize, title: String) -> SCNNode {
        let holder = SCNNode()
        holder.name = name

        let frame = SCNBox(width: width + 0.22, height: height + 0.22, length: 0.12, chamferRadius: 0.03)
        let fm = SCNMaterial()
        fm.lightingModel = .physicallyBased
        fm.diffuse.contents = UIColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1)
        fm.metalness.contents = 0.55
        fm.roughness.contents = 0.35
        frame.materials = [fm]
        let frameNode = SCNNode(geometry: frame)
        frameNode.position = SCNVector3(0, 0, -0.07)
        holder.addChildNode(frameNode)

        let scene = boardScene(size: sceneSize)
        let plane = SCNPlane(width: width, height: height)
        plane.materials = [boardMaterial(scene: scene)]
        let planeNode = SCNNode(geometry: plane)
        holder.addChildNode(planeNode)

        redraw(scene, title: title) { content, size in
            content.addChild(emptyLabel("syncing…", at: CGPoint(x: size.width / 2, y: size.height / 2)))
        }
        return holder
    }

    private static func boardScene(size: CGSize) -> SKScene {
        let scene = SKScene(size: size)
        scene.scaleMode = .aspectFit
        scene.backgroundColor = bg
        return scene
    }

    private static func boardMaterial(scene: SKScene) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = scene
        // SpriteKit renders y-up; SceneKit samples y-down — flip the texture.
        material.diffuse.contentsTransform = SCNMatrix4Translate(SCNMatrix4MakeScale(1, -1, 1), 0, 1, 0)
        material.emission.contents = scene
        material.emission.contentsTransform = material.diffuse.contentsTransform
        material.emission.intensity = 0.55        // readable, not neon
        material.lightingModel = .constant
        material.isDoubleSided = false
        return material
    }

    /// Find the SKScene rendered by a named board.
    private static func boardScene(under root: SCNNode, named name: String) -> SKScene? {
        guard let node = root.childNode(withName: name, recursively: true) else { return nil }
        var found: SKScene?
        node.enumerateHierarchy { n, stop in
            if let scene = n.geometry?.firstMaterial?.diffuse.contents as? SKScene {
                found = scene; stop.pointee = true
            }
        }
        return found
    }

    /// Clear + redraw a board: header row, hairline, then the caller's content.
    private static func redraw(_ scene: SKScene, title: String,
                               content: (SKNode, CGSize) -> Void) {
        scene.userData = nil
        scene.removeAllChildren()
        let size = scene.size
        scene.addChild(label(title, font: fontBold, size: 30, color: textDim,
                             at: CGPoint(x: 28, y: size.height - 48), align: .left))
        let rule = SKShapeNode(rect: CGRect(x: 28, y: size.height - 64, width: size.width - 56, height: 2))
        rule.fillColor = emerald.withAlphaComponent(0.55); rule.strokeColor = .clear
        scene.addChild(rule)
        let holder = SKNode()
        scene.addChild(holder)
        content(holder, size)
    }

    private static func label(_ text: String, font: String, size: CGFloat, color: UIColor,
                              at point: CGPoint,
                              align: SKLabelHorizontalAlignmentMode = .center) -> SKLabelNode {
        let node = SKLabelNode(fontNamed: font)
        node.text = text
        node.fontSize = size
        node.fontColor = color
        node.position = point
        node.horizontalAlignmentMode = align
        node.verticalAlignmentMode = .center
        return node
    }

    private static func emptyLabel(_ text: String, at point: CGPoint) -> SKLabelNode {
        label(text, font: fontSemi, size: 24, color: textDim, at: point)
    }
}

/// Tiny namespace for SK marquee motion (kept out of the board code for clarity).
private enum SCNActionizedSKAction {
    static func marquee(travel: CGFloat, speed: CGFloat) -> SKAction {
        let duration = TimeInterval(travel / speed)
        let slide = SKAction.moveBy(x: -travel, y: 0, duration: duration)
        let reset = SKAction.moveBy(x: travel, y: 0, duration: 0)
        return .repeatForever(.sequence([slide, reset]))
    }
}
