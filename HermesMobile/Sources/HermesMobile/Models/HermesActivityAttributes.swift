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
