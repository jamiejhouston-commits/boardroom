import Foundation

/// Mirror of the relay's company-engine JSON (`Scripts/hermes_company.py`).
/// Decoded with `.convertFromSnakeCase`, so `last_tick` → `lastTick`, etc.

struct CompanyState: Codable, Equatable {
    var enabled: Bool
    var thesis: String
    var lastTick: Double
    var config: CompanyConfig
    var initiatives: [CompanyInitiative]
    var meetings: [CompanyMeeting]?

    static let empty = CompanyState(enabled: false, thesis: "", lastTick: 0,
                                    config: CompanyConfig(), initiatives: [], meetings: nil)
}

struct CompanyMeeting: Codable, Equatable, Identifiable {
    var id: String
    var topic: String
    var status: String                 // "live" or "done"
    var attendees: [String]
    var started: String
    var turnCount: Int?                 // present in the list summary
    var turns: [CompanyMeetingTurn]?    // present only in the detail endpoint

    var isLive: Bool { status == "live" }
}

struct CompanyMeetingTurn: Codable, Equatable, Identifiable {
    var role: String
    var text: String
    var ts: String

    var id: String { "\(role)-\(ts)-\(text.prefix(12))" }
}

struct CompanyConfig: Codable, Equatable {
    var intervalMinutes: Int = 30
    var quietStart: Int = 22
    var quietEnd: Int = 7
    var maxActive: Int = 1
    var budgetCalls: Int = 40
}

struct CompanyScore: Codable, Equatable {
    var heat: Double?
    var fit: Double?
    var effort: Double?
    var rationale: String?
}

struct CompanyMinute: Codable, Equatable, Identifiable {
    var stage: String
    var role: String
    var text: String
    var ts: String

    var id: String { "\(stage)-\(role)-\(ts)" }
}

struct CompanyInitiative: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var pitch: String
    var stage: String
    var created: String
    var score: CompanyScore?
    var callsUsed: Int
    var brief: String
    var artifacts: [String]
    var note: String
    /// Private GitHub repo the deliverables shipped to (set after gate-2 approve).
    var repoUrl: String?
    /// Present only on the detail endpoint.
    var minutes: [CompanyMinute]?

    var isAwaitingDecision: Bool { stage == "gate1" || stage == "gate2" }
    var isTerminal: Bool { stage == "shipped" || stage == "killed" }

    /// Pipeline position for the progress bar (gates share their phase).
    var progress: Double {
        switch stage {
        case "research":    0.15
        case "boardroom":   0.3
        case "gate1":       0.4
        case "planning":    0.55
        case "execution":   0.7
        case "demo_ready":  0.85
        case "gate2":       0.92
        case "shipped":     1.0
        default:            0.0   // killed
        }
    }

    var stageLabel: String {
        switch stage {
        case "research":    "Researching"
        case "boardroom":   "Boardroom debate"
        case "gate1":       "Awaiting your greenlight"
        case "planning":    "CEO planning"
        case "execution":   "Team building"
        case "demo_ready":  "Preparing demo"
        case "gate2":       "Demo Day — your call"
        case "shipped":     "Shipped"
        case "killed":      "Killed"
        default:            stage
        }
    }
}

enum CompanyDecision: String {
    case approve, kill, revise
}

struct CompanyAck: Codable, Equatable {
    var ok: Bool?
}
