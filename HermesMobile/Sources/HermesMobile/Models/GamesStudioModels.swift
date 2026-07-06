import Foundation

/// Mirror of the relay's Games Studio engine JSON (`Scripts/hermes_games_studio.py`).
/// Decoded with `.convertFromSnakeCase`, so `build_notes` → `buildNotes`, etc.
/// The Games Studio is the first Boardroom division; this is the data the Games
/// Production Room renders.

struct GamesStudioState: Codable, Equatable {
    var enabled: Bool
    var games: [StudioGame]
    var events: [StudioEvent]?
    var lastTick: Double?

    /// The current title the room focuses on: the newest non-shelved game, or
    /// the flagship, or whatever exists.
    var currentGame: StudioGame? {
        games.first { $0.stage != "shelved" } ?? games.first
    }

    static let empty = GamesStudioState(enabled: false, games: [], events: nil, lastTick: nil)

    /// The bundled fallback — the studio's real, shipped, playable flagship of
    /// record. Used whenever the relay is unreachable so the room is fully alive
    /// offline. This isn't faked data: `SkylineStack.html` genuinely ships in the
    /// bundle and is genuinely playable in the cabinet.
    static let flagship = GamesStudioState(
        enabled: true,
        games: [StudioGame.skylineStack],
        events: [
            StudioEvent(text: "flagship seeded: Skyline Stack (shipped)", ts: nil),
            StudioEvent(text: "Fun Gate APPROVED: Skyline Stack", ts: nil),
            StudioEvent(text: "shipped: Skyline Stack", ts: nil),
        ],
        lastTick: nil)
}

struct StudioEvent: Codable, Equatable, Identifiable {
    var text: String
    var ts: Double?
    var id: String { "\(ts ?? 0)-\(text.prefix(20))" }
}

struct StudioPlaytest: Codable, Equatable, Identifiable {
    var tester: String
    var rating: Int
    var reaction: String
    var id: String { tester }
}

struct StudioFunGate: Codable, Equatable {
    var verdict: String        // "" | "APPROVED" | "REJECTED"
    var reasons: [String]

    var isApproved: Bool { verdict == "APPROVED" }
    var isRejected: Bool { verdict == "REJECTED" }
    var isDecided: Bool { !verdict.isEmpty }
}

/// A game moving through the studio pipeline.
struct StudioGame: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var line: String                    // daily-puzzle | hyper-casual | viral-funnel
    var pitch: String
    var stage: String
    var pillars: [String]
    var buildNotes: String?
    var runtime: String                 // bundled/served HTML filename ("" until built)
    var playtests: [StudioPlaytest]
    var funGate: StudioFunGate
    var distribution: [String: String]  // channel → planned|submitted|live
    var score: Int?                     // owner's best arcade score
    var created: String?

    /// Sellable asset packs (2D/3D) flow through the same pipeline as games,
    /// with asset-aware stages, reviewers, and marketplaces.
    var isAssetPack: Bool { line.hasPrefix("asset-") }

    var lineLabel: String {
        switch line {
        case "daily-puzzle": "Daily Puzzle"
        case "viral-funnel": "Viral Funnel"
        case "asset-2d":     "2D Asset Pack"
        case "asset-3d":     "3D Asset Pack"
        default:             "Hyper-Casual"
        }
    }

    /// Pipeline position for a progress bar (0…1). Fun-Gate rejection shows as
    /// mid-pipeline (it loops back to design), never as shipped.
    var progress: Double {
        switch stage {
        case "concept":      0.12
        case "design":       0.28
        case "build":        0.46
        case "playtest":     0.62
        case "fun_gate":     0.78
        case "distribution": 0.9
        case "shipped":      1.0
        default:             0.0   // shelved
        }
    }

    var stageLabel: String {
        switch stage {
        case "concept":      "Concepting"
        case "design":       "Designing"
        case "build":        "Building"
        case "playtest":     isAssetPack ? "Art Review" : "Playtesting"
        case "fun_gate":     gateLabel
        case "distribution": isAssetPack ? "Listing for Sale" : "Distributing"
        case "shipped":      isAssetPack ? "On Sale" : "Shipped"
        case "shelved":      "Shelved"
        default:             stage
        }
    }

    /// Asset packs pass a Quality Gate (would a studio pay?); games a Fun Gate.
    var gateLabel: String { isAssetPack ? "Quality Gate" : "Fun Gate" }

    var isShipped: Bool { stage == "shipped" }
    /// Playable in the cabinet only when a runtime file exists in the bundle.
    var isPlayable: Bool { !runtime.isEmpty }

    /// Average playtest fun rating (0…10), 0 with no data.
    var averageFun: Double {
        guard !playtests.isEmpty else { return 0 }
        return (Double(playtests.map(\.rating).reduce(0, +)) / Double(playtests.count) * 10).rounded() / 10
    }

    /// Channel status in a stable display order. Games go to players; asset
    /// packs go to marketplaces (itch.io, Roblox Creator Store, engine stores).
    var distributionChannels: [(name: String, status: String)] {
        if isAssetPack {
            return [("itch.io", distribution["itch"] ?? "planned"),
                    ("Roblox Store", distribution["roblox"] ?? "planned"),
                    ("Engine Stores", distribution["unity"] ?? "planned")]
        }
        return [("itch.io", distribution["itch"] ?? "planned"),
                ("Reddit", distribution["reddit"] ?? "planned"),
                ("Portals", distribution["portals"] ?? "planned")]
    }

    /// The real, shipped flagship — mirrors `seed_flagship` on the relay.
    static let skylineStack = StudioGame(
        id: "flagship-skyline",
        title: "Skyline Stack",
        line: "hyper-casual",
        pitch: "Drop each floor clean to raise the tower — one thumb, endless.",
        stage: "shipped",
        pillars: [
            "One-tap core loop: drop the sliding floor, trim the overhang.",
            "Perfect landings grow the block back and build a combo.",
            "Rising speed is the only difficulty knob — pure skill.",
            "Ten-second onramp, endless ceiling, instant restart.",
        ],
        buildNotes: "Canvas + WebAudio tower-stacker. Swinging floor, overhang trimming, perfect-combo scoring, best-score persistence.",
        runtime: "SkylineStack.html",
        playtests: [
            StudioPlaytest(tester: "Pixel", rating: 9, reaction: "One more go — the perfect chime is addictive."),
            StudioPlaytest(tester: "Bolt", rating: 8, reaction: "Clean, fast, reads instantly. Combo hook lands."),
            StudioPlaytest(tester: "Ada", rating: 9, reaction: "Skyline theme + juice make it feel premium."),
        ],
        funGate: StudioFunGate(
            verdict: "APPROVED",
            reasons: [
                "Fun in the first ten seconds — no tutorial needed.",
                "Perfect-combo loop creates the one-more-try pull.",
                "Difficulty comes purely from speed — always feels fair.",
            ]),
        distribution: ["itch": "live", "reddit": "submitted", "portals": "planned"],
        score: nil,
        created: nil)
}

/// Channel status → a room lamp color intent (resolved to UIColor in the scene).
enum ChannelStatus: String {
    case planned, submitted, live

    init(_ raw: String) { self = ChannelStatus(rawValue: raw) ?? .planned }

    var label: String {
        switch self {
        case .planned:   "Planned"
        case .submitted: "Submitted"
        case .live:      "Live"
        }
    }
}
