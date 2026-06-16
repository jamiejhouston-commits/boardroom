import ActivityKit
import Foundation

// Shared between the app and the HermesWidgets extension — plain types only.

/// Live Activity: countdown to a scheduled meeting (lock screen + Dynamic Island).
struct MeetingCountdownAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When the meeting starts — drives the live countdown timer.
        var startDate: Date
    }

    var topic: String
    var attendeeCount: Int
}

/// Live Activity: the company at work — a glanceable pulse on the lock screen
/// and in the Dynamic Island. Updated from CompanyStore as state changes.
struct CompanyPulseAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var headline: String        // the one thing happening (initiative / task)
        var detail: String          // its stage / status
        var status: String          // short status line
        var pendingGates: Int       // decisions waiting on the owner
        var working: Bool           // animate the pulse when the team is busy
    }

    var company: String             // "Boardroom"
}

/// Live Activity: a boardroom debate in progress — shows who's speaking now.
struct DebateActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var speakerName: String
        var accentHex: String
        var round: Int
        var totalRounds: Int
    }

    var topic: String
}
