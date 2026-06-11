import ActivityKit
import Foundation

/// Starts/updates/ends Hermes Live Activities (lock screen + Dynamic Island).
/// All calls are safe no-ops when the user has Live Activities disabled.
@MainActor
enum LiveActivityManager {

    // MARK: Meeting countdown

    private static var meetingActivities: [UUID: Activity<MeetingCountdownAttributes>] = [:]

    /// Show a countdown for a meeting starting within the next 12 hours.
    static func startMeetingCountdown(for meeting: ScheduledMeeting) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let lead = meeting.date.timeIntervalSinceNow
        guard lead > 60, lead < 12 * 3600 else { return }

        let attributes = MeetingCountdownAttributes(topic: meeting.topic,
                                                    attendeeCount: meeting.attendeeIDs.count)
        let state = MeetingCountdownAttributes.ContentState(startDate: meeting.date)
        let content = ActivityContent(state: state,
                                      staleDate: meeting.date.addingTimeInterval(30 * 60))
        if let activity = try? Activity.request(attributes: attributes, content: content) {
            meetingActivities[meeting.id] = activity
        }
    }

    static func endMeetingCountdown(for meetingID: UUID) {
        guard let activity = meetingActivities.removeValue(forKey: meetingID) else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: Debate — who's speaking now

    private static var debateActivity: Activity<DebateActivityAttributes>?

    static func startDebate(topic: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endDebate()
        let attributes = DebateActivityAttributes(topic: topic)
        let state = DebateActivityAttributes.ContentState(speakerName: "Convening…",
                                                          accentHex: "1C7A55",
                                                          round: 1, totalRounds: 1)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))
        debateActivity = try? Activity.request(attributes: attributes, content: content)
    }

    static func updateDebate(speaker: String, accentHex: String, round: Int, totalRounds: Int) {
        guard let activity = debateActivity else { return }
        let state = DebateActivityAttributes.ContentState(speakerName: speaker,
                                                          accentHex: accentHex,
                                                          round: round, totalRounds: totalRounds)
        Task {
            await activity.update(ActivityContent(state: state,
                                                  staleDate: Date().addingTimeInterval(3600)))
        }
    }

    static func endDebate() {
        guard let activity = debateActivity else { return }
        debateActivity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
