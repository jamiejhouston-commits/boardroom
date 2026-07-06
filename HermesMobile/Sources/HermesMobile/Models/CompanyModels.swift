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
    var events: [CompanyEvent]?
    var tasks: [CompanyTask]?
    var taskMode: Bool?
    var asks: [CompanyAsk]?
    var schedules: [CompanySchedule]?

    static let empty = CompanyState(enabled: false, thesis: "", lastTick: 0,
                                    config: CompanyConfig(), initiatives: [], meetings: nil,
                                    events: nil, tasks: nil, taskMode: nil, asks: nil,
                                    schedules: nil)
}

/// A recurring owner automation (the Cron): a directive or an ask the company
/// runs on a schedule (hourly / daily / weekly).
struct CompanySchedule: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var kind: String            // "directive" | "ask"
    var text: String
    var cadence: String         // "hourly" | "daily" | "weekly"
    var atHour: Int
    var atMinute: Int
    var weekday: Int            // Monday=0 … Sunday=6
    var enabled: Bool
    var lastFired: Double?

    var kindLabel: String {
        switch kind {
        case "ask":     return "Ask"
        case "meeting": return "Office hours"
        default:        return "Pitch idea"
        }
    }

    private static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// "Daily at 9:00", "Mondays at 8:30", "Hourly at :15".
    var cadenceSummary: String {
        let time = String(format: "%d:%02d", atHour, atMinute)
        switch cadence {
        case "hourly": return "Hourly at :\(String(format: "%02d", atMinute))"
        case "weekly":
            let day = Self.weekdayNames[min(max(weekday, 0), 6)]
            return "\(day) at \(time)"
        default:       return "Daily at \(time)"
        }
    }
}

/// "Ask the company": the owner's question, each leader's answer, and the CEO's
/// synthesized answer. Built in the background (poll until `status == "done"`).
struct CompanyAsk: Codable, Equatable, Identifiable {
    var id: String
    var question: String
    var status: String                       // "live" | "done"
    var contributions: [CompanyAskContribution]?
    var answer: String
    var started: String

    var isLive: Bool { status == "live" }
}

struct CompanyAskContribution: Codable, Equatable, Identifiable {
    var role: String
    var text: String
    var id: String { "\(role)-\(text.prefix(12))" }
}

/// One Kanban task the owner handed the company. Moves todo → doing → done.
struct CompanyTask: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var status: String              // "todo" | "doing" | "done"
    var created: String
    var result: String?
    var artifacts: [String]?

    var column: TaskColumn {
        switch status {
        case "doing": return .doing
        case "done":  return .done
        default:      return .todo
        }
    }

    /// A parked task that failed all its retries (builder flags these with ⚠).
    var failed: Bool { (result ?? "").hasPrefix("⚠") }
}

enum TaskColumn: String, CaseIterable, Identifiable {
    case todo, doing, done
    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo:  return "To Do"
        case .doing: return "In Progress"
        case .done:  return "Done"
        }
    }

    var systemImage: String {
        switch self {
        case .todo:  return "tray.full"
        case .doing: return "hammer.fill"
        case .done:  return "checkmark.seal.fill"
        }
    }
}

struct CompanyEvent: Codable, Equatable, Identifiable {
    var text: String
    var ts: Double

    var id: String { "\(ts)-\(text.prefix(16))" }
    var date: Date { Date(timeIntervalSince1970: ts) }
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
    /// Production-line target. Optional so a relay that predates the field
    /// still decodes; missing means the historical default, iOS.
    var platform: String?

    var productionPlatform: ProductionPlatform {
        ProductionPlatform(rawValue: platform ?? "") ?? .ios
    }
}

/// What the company's production line builds — switched from the HQ's
/// Production Bay. Raw values match the relay (`hermes_company.PLATFORM_DIRECTIVES`).
enum ProductionPlatform: String, CaseIterable, Identifiable {
    case ios, ipados, macos

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ios:    "iPhone"
        case .ipados: "iPad"
        case .macos:  "Mac"
        }
    }

    var systemLabel: String {
        switch self {
        case .ios:    "iOS"
        case .ipados: "iPadOS"
        case .macos:  "macOS"
        }
    }

    var icon: String {
        switch self {
        case .ios:    "iphone"
        case .ipados: "ipad.landscape"
        case .macos:  "desktopcomputer"
        }
    }

    var blurb: String {
        switch self {
        case .ios:    "Native SwiftUI iPhone apps, verified in the iPhone Simulator."
        case .ipados: "Native SwiftUI iPad apps — split views, pointer, big-canvas layouts."
        case .macos:  "Native SwiftUI Mac apps — windows, menus, keyboard-first."
        }
    }
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
    /// "owner" when the Chairman pitched it directly (voice memo / directive).
    var origin: String?
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
