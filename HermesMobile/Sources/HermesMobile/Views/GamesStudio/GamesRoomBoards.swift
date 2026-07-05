import SceneKit
import SpriteKit
import UIKit

/// The Games Production Room's live surfaces — the studio's real state rendered
/// physically in the room, using the same SpriteKit-scene-as-SCNMaterial pattern
/// as `HQLiveBoards` (crisp text, cheap redraws, no scene rebuilds):
///  • the giant arcade screen (current build + Fun-Gate badge),
///  • the design whiteboard (pillars + playtest quotes),
///  • the distribution board (itch / Reddit / portals),
///  • the cabinet marquee + attract screen,
///  • the Fun Gate plaque + verdict color.
///
/// `update(root:game:)` is cheap and idempotent — the scene view gates it behind
/// a game-state signature so it runs only on change.
enum GamesRoomBoards {

    // MARK: Palette

    private static let bg = UIColor(red: 0.045, green: 0.058, blue: 0.085, alpha: 1)
    private static let panel = UIColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1)
    private static let textBright = UIColor(red: 0.9, green: 0.92, blue: 0.96, alpha: 1)
    private static let textDim = UIColor(red: 0.55, green: 0.6, blue: 0.68, alpha: 1)
    private static let emerald = GamesRoomBuilder.emerald
    private static let emeraldHot = GamesRoomBuilder.emeraldHot
    private static let gold = GamesRoomBuilder.gold
    private static let amber = GamesRoomBuilder.amber

    private static let fontBold = "HelveticaNeue-Bold"
    private static let fontSemi = "HelveticaNeue-Medium"

    // MARK: Board factories

    static func megaScreenNode() -> SCNNode {
        framedBoard(name: GamesRoomBuilder.megaScreenName, width: 11, height: 5,
                    sceneSize: CGSize(width: 1280, height: 582), title: "NOW BUILDING")
    }

    static func whiteboardNode() -> SCNNode {
        framedBoard(name: GamesRoomBuilder.whiteboardName, width: 6.4, height: 3.6,
                    sceneSize: CGSize(width: 900, height: 506), title: "DESIGN")
    }

    static func distributionNode() -> SCNNode {
        framedBoard(name: GamesRoomBuilder.distributionName, width: 5.6, height: 3.2,
                    sceneSize: CGSize(width: 840, height: 480), title: "DISTRIBUTION")
    }

    static func cabinetScreenMaterial() -> SCNMaterial {
        boardMaterial(scene: attractScene(), emissionIntensity: 0.9)
    }

    static func marqueeMaterial() -> SCNMaterial {
        let scene = plainScene(size: CGSize(width: 512, height: 128))
        drawMarquee(scene, title: "SKYLINE STACK")
        return boardMaterial(scene: scene, emissionIntensity: 1.0)
    }

    static func funGatePlaqueMaterial() -> SCNMaterial {
        let scene = plainScene(size: CGSize(width: 640, height: 128))
        drawPlaque(scene, verdict: nil)
        return boardMaterial(scene: scene, emissionIntensity: 0.9)
    }

    // MARK: Live update

    static func update(root: SCNNode, game: StudioGame?) {
        if let scene = scene(under: root, named: GamesRoomBuilder.megaScreenName) {
            drawMegaScreen(scene, game: game)
        }
        if let scene = scene(under: root, named: GamesRoomBuilder.whiteboardName) {
            drawWhiteboard(scene, game: game)
        }
        if let scene = scene(under: root, named: GamesRoomBuilder.distributionName) {
            drawDistribution(scene, game: game)
        }
        if let scene = scene(under: root, named: GamesRoomBuilder.cabinetMarqueeName) {
            drawMarquee(scene, title: (game?.title ?? "SKYLINE STACK").uppercased())
        }
        if let scene = scene(under: root, named: GamesRoomBuilder.funGateBadgeName) {
            drawPlaque(scene, verdict: game?.funGate)
        }
        updateFunGateColor(root: root, game: game)
    }

    private static func updateFunGateColor(root: SCNNode, game: StudioGame?) {
        let approved: Bool? = {
            guard let gate = game?.funGate, gate.isDecided else { return nil }
            return gate.isApproved
        }()
        let color = GamesRoomBuilder.funGateColor(approved: approved)
        root.enumerateHierarchy { node, _ in
            guard node.name == GamesRoomBuilder.funGateTrimName,
                  let material = node.geometry?.firstMaterial else { return }
            material.emission.contents = color
        }
    }

    // MARK: Mega arcade screen

    private static func drawMegaScreen(_ scene: SKScene, game: StudioGame?) {
        redraw(scene, title: "NOW BUILDING") { content, size in
            guard let game else {
                content.addChild(centered("The studio is idle — pitch a game.",
                                          at: CGPoint(x: size.width / 2, y: size.height / 2)))
                return
            }
            // Left column: title + line + stage + progress + build note.
            let leftX: CGFloat = 40
            content.addChild(label(game.title, font: fontBold, size: 62, color: textBright,
                                   at: CGPoint(x: leftX, y: size.height - 150), align: .left))
            content.addChild(label(game.lineLabel.uppercased(), font: fontSemi, size: 24,
                                   color: gold, at: CGPoint(x: leftX, y: size.height - 196), align: .left))

            let stageColor: UIColor = game.isShipped ? emerald
                : game.stage == "shelved" ? textDim : emeraldHot
            content.addChild(label(game.stageLabel.uppercased(), font: fontBold, size: 30,
                                   color: stageColor, at: CGPoint(x: leftX, y: size.height - 258), align: .left))

            // Progress bar.
            let barW = size.width * 0.44
            let barY = size.height - 300
            let track = SKShapeNode(rect: CGRect(x: leftX, y: barY, width: barW, height: 10), cornerRadius: 5)
            track.fillColor = panel; track.strokeColor = .clear
            content.addChild(track)
            let fill = SKShapeNode(rect: CGRect(x: leftX, y: barY, width: max(10, barW * CGFloat(game.progress)),
                                                height: 10), cornerRadius: 5)
            fill.fillColor = game.isShipped ? emerald : emeraldHot; fill.strokeColor = .clear
            content.addChild(fill)

            if let note = game.buildNotes, !note.isEmpty {
                content.addChild(wrapped(note, width: barW, font: fontSemi, size: 20, color: textDim,
                                         at: CGPoint(x: leftX, y: barY - 40), lines: 3))
            }

            // Fun-Gate badge.
            let gate = game.funGate
            let badgeText = gate.isApproved ? "FUN GATE ✓ APPROVED"
                : gate.isRejected ? "FUN GATE ✗ REJECTED" : "FUN GATE · PENDING"
            let badgeColor = gate.isApproved ? emerald : gate.isRejected ? amber : textDim
            content.addChild(label(badgeText, font: fontBold, size: 26, color: badgeColor,
                                   at: CGPoint(x: leftX, y: 44), align: .left))

            // Right column: a stylized attract tower preview.
            drawTowerPreview(content, rect: CGRect(x: size.width * 0.62, y: 60,
                                                   width: size.width * 0.3, height: size.height - 200))
        }
    }

    /// A little stacked-tower motif so the screen reads as *this* game at a glance.
    private static func drawTowerPreview(_ content: SKNode, rect: CGRect) {
        let floors = 9
        let h = rect.height / CGFloat(floors + 2)
        var w = rect.width
        var cx = rect.midX
        for i in 0..<floors {
            let jitter = (i == 0) ? 0 : CGFloat((i % 2 == 0 ? 1 : -1)) * min(18, CGFloat(i) * 3)
            cx += jitter * 0.15
            let y = rect.minY + CGFloat(i) * h
            let block = SKShapeNode(rect: CGRect(x: cx - w / 2, y: y, width: w, height: h - 3), cornerRadius: 3)
            let t = CGFloat(i) / CGFloat(floors)
            block.fillColor = UIColor(red: 0.12 + 0.05 * t, green: 0.68 + 0.1 * t, blue: 0.46, alpha: 1)
            block.strokeColor = UIColor(white: 1, alpha: 0.12); block.lineWidth = 1
            content.addChild(block)
            w = max(rect.width * 0.4, w - CGFloat.random(in: 4...12))
        }
    }

    // MARK: Whiteboard — design pillars + playtest quotes

    private static func drawWhiteboard(_ scene: SKScene, game: StudioGame?) {
        redraw(scene, title: "DESIGN") { content, size in
            guard let game else {
                content.addChild(centered("—", at: CGPoint(x: size.width / 2, y: size.height / 2)))
                return
            }
            content.addChild(label(game.title, font: fontBold, size: 30, color: gold,
                                   at: CGPoint(x: 32, y: size.height - 108), align: .left))
            var y = size.height - 158
            for pillar in game.pillars.prefix(4) {
                content.addChild(bullet(color: emerald, at: CGPoint(x: 40, y: y)))
                content.addChild(wrapped(pillar, width: size.width - 90, font: fontSemi, size: 22,
                                         color: textBright, at: CGPoint(x: 62, y: y), lines: 2))
                y -= 52
            }
            // A playtest quote at the bottom, if any.
            if let best = game.playtests.max(by: { $0.rating < $1.rating }) {
                content.addChild(label("PLAYTEST", font: fontBold, size: 16, color: textDim,
                                       at: CGPoint(x: 32, y: 62), align: .left))
                content.addChild(wrapped("“\(best.reaction)” — \(best.tester) \(best.rating)/10",
                                         width: size.width - 64, font: fontSemi, size: 20, color: gold,
                                         at: CGPoint(x: 32, y: 40), lines: 2))
            }
        }
    }

    // MARK: Distribution board — channel status lamps

    private static func drawDistribution(_ scene: SKScene, game: StudioGame?) {
        redraw(scene, title: "DISTRIBUTION") { content, size in
            guard let game else { return }
            var y = size.height - 140
            for channel in game.distributionChannels {
                let status = ChannelStatus(channel.status)
                let lampColor: UIColor = status == .live ? emerald
                    : status == .submitted ? gold : textDim.withAlphaComponent(0.6)
                let lamp = SKShapeNode(circleOfRadius: 12)
                lamp.fillColor = lampColor; lamp.strokeColor = .clear
                lamp.position = CGPoint(x: 46, y: y + 8)
                content.addChild(lamp)
                content.addChild(label(channel.name, font: fontSemi, size: 26, color: textBright,
                                       at: CGPoint(x: 78, y: y), align: .left))
                content.addChild(label(status.label.uppercased(), font: fontBold, size: 22, color: lampColor,
                                       at: CGPoint(x: size.width - 40, y: y), align: .right))
                y -= 82
            }
        }
    }

    // MARK: Cabinet marquee + attract + Fun-Gate plaque

    private static func drawMarquee(_ scene: SKScene, title: String) {
        scene.removeAllChildren()
        let node = label(title, font: fontBold, size: 58, color: gold, at: .zero)
        node.position = CGPoint(x: scene.size.width / 2, y: scene.size.height / 2)
        node.verticalAlignmentMode = .center
        scene.addChild(node)
    }

    private static func drawPlaque(_ scene: SKScene, verdict: StudioFunGate?) {
        scene.removeAllChildren()
        let word: String
        let color: UIColor
        if let verdict, verdict.isApproved { word = "APPROVED"; color = emerald }
        else if let verdict, verdict.isRejected { word = "REJECTED"; color = amber }
        else { word = "PENDING"; color = textDim }
        let title = label("FUN GATE", font: fontBold, size: 40, color: textDim,
                          at: CGPoint(x: scene.size.width / 2, y: scene.size.height * 0.66))
        title.verticalAlignmentMode = .center
        scene.addChild(title)
        let verdictNode = label(word, font: fontBold, size: 52, color: color,
                                at: CGPoint(x: scene.size.width / 2, y: scene.size.height * 0.3))
        verdictNode.verticalAlignmentMode = .center
        scene.addChild(verdictNode)
    }

    private static func attractScene() -> SKScene {
        let scene = plainScene(size: CGSize(width: 430, height: 360))
        // A static attract frame: title, a small tower, and a prompt.
        let tower = SKNode()
        var w: CGFloat = 150, cx = scene.size.width / 2
        for i in 0..<7 {
            let y = 70 + CGFloat(i) * 28
            let block = SKShapeNode(rect: CGRect(x: cx - w / 2, y: y, width: w, height: 24), cornerRadius: 3)
            block.fillColor = UIColor(red: 0.12, green: 0.7, blue: 0.47, alpha: 1)
            block.strokeColor = UIColor(white: 1, alpha: 0.12)
            tower.addChild(block)
            w = max(60, w - 14); cx += (i % 2 == 0 ? 8 : -8)
        }
        scene.addChild(tower)
        let title = label("SKYLINE STACK", font: fontBold, size: 34, color: gold,
                          at: CGPoint(x: scene.size.width / 2, y: scene.size.height - 48))
        scene.addChild(title)
        let prompt = label("TAP TO PLAY", font: fontBold, size: 24, color: textBright,
                           at: CGPoint(x: scene.size.width / 2, y: 34))
        let pulse = SKAction.sequence([.fadeAlpha(to: 0.35, duration: 0.7), .fadeAlpha(to: 1, duration: 0.7)])
        prompt.run(.repeatForever(pulse))
        scene.addChild(prompt)
        return scene
    }

    // MARK: Board plumbing (mirrors HQLiveBoards)

    private static func framedBoard(name: String, width: CGFloat, height: CGFloat,
                                    sceneSize: CGSize, title: String) -> SCNNode {
        let holder = SCNNode()
        holder.name = name

        let frame = SCNBox(width: width + 0.24, height: height + 0.24, length: 0.12, chamferRadius: 0.03)
        let fm = SCNMaterial()
        fm.lightingModel = .physicallyBased
        fm.diffuse.contents = UIColor(red: 0.09, green: 0.1, blue: 0.13, alpha: 1)
        fm.metalness.contents = 0.55; fm.roughness.contents = 0.35
        frame.materials = [fm]
        let frameNode = SCNNode(geometry: frame)
        frameNode.position = SCNVector3(0, 0, -0.07)
        holder.addChildNode(frameNode)

        let scene = plainScene(size: sceneSize)
        let plane = SCNPlane(width: width, height: height)
        plane.materials = [boardMaterial(scene: scene, emissionIntensity: 0.6)]
        holder.addChildNode(SCNNode(geometry: plane))

        redraw(scene, title: title) { content, size in
            content.addChild(centered("syncing…", at: CGPoint(x: size.width / 2, y: size.height / 2)))
        }
        return holder
    }

    private static func plainScene(size: CGSize) -> SKScene {
        let scene = SKScene(size: size)
        scene.scaleMode = .aspectFit
        scene.backgroundColor = bg
        return scene
    }

    private static func boardMaterial(scene: SKScene, emissionIntensity: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = scene
        material.diffuse.contentsTransform = SCNMatrix4Translate(SCNMatrix4MakeScale(1, -1, 1), 0, 1, 0)
        material.emission.contents = scene
        material.emission.contentsTransform = material.diffuse.contentsTransform
        material.emission.intensity = emissionIntensity
        material.lightingModel = .constant
        material.isDoubleSided = false
        return material
    }

    private static func scene(under root: SCNNode, named name: String) -> SKScene? {
        guard let node = root.childNode(withName: name, recursively: true) else { return nil }
        var found: SKScene?
        node.enumerateHierarchy { n, stop in
            if let scene = n.geometry?.firstMaterial?.diffuse.contents as? SKScene {
                found = scene; stop.pointee = true
            }
        }
        return found
    }

    private static func redraw(_ scene: SKScene, title: String,
                               content: (SKNode, CGSize) -> Void) {
        scene.removeAllChildren()
        let size = scene.size
        scene.addChild(label(title, font: fontBold, size: 30, color: textDim,
                             at: CGPoint(x: 32, y: size.height - 52), align: .left))
        let rule = SKShapeNode(rect: CGRect(x: 32, y: size.height - 70, width: size.width - 64, height: 2))
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
        node.verticalAlignmentMode = .baseline
        return node
    }

    private static func centered(_ text: String, at point: CGPoint) -> SKLabelNode {
        label(text, font: fontSemi, size: 24, color: textDim, at: point)
    }

    private static func bullet(color: UIColor, at point: CGPoint) -> SKShapeNode {
        let dot = SKShapeNode(circleOfRadius: 5)
        dot.fillColor = color; dot.strokeColor = .clear
        dot.position = CGPoint(x: point.x, y: point.y + 8)
        return dot
    }

    /// Naive word-wrap into up to `lines` label rows, top-anchored at `point`.
    private static func wrapped(_ text: String, width: CGFloat, font: String, size: CGFloat,
                                color: UIColor, at point: CGPoint, lines: Int) -> SKNode {
        let container = SKNode()
        let charW = size * 0.52
        let perLine = max(8, Int(width / charW))
        var remaining = Substring(text)
        var row = 0
        while !remaining.isEmpty && row < lines {
            var cut = remaining.count <= perLine ? remaining.endIndex
                : remaining.index(remaining.startIndex, offsetBy: perLine)
            if cut != remaining.endIndex {
                // back up to the last space so words don't split
                if let space = remaining[..<cut].lastIndex(of: " ") { cut = space }
            }
            let line = String(remaining[..<cut]).trimmingCharacters(in: .whitespaces)
            let node = label(line, font: font, size: size, color: color,
                             at: CGPoint(x: point.x, y: point.y - CGFloat(row) * (size + 6)), align: .left)
            container.addChild(node)
            remaining = remaining[cut...].drop(while: { $0 == " " })
            row += 1
        }
        return container
    }
}
