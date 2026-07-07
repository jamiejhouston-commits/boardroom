import EventKit
import Foundation
import UserNotifications

// MARK: - Models

/// A meeting you scheduled with agents — mirrored into the user's Apple Calendar.
struct ScheduledMeeting: Identifiable, Codable, Hashable {
    var id = UUID()
    var topic: String
    var date: Date
    var attendeeIDs: [String]
    /// EventKit identifier of the calendar event we created (for cleanup).
    var eventIdentifier: String?
    /// The prep memo sent for this meeting, if any.
    var memoID: UUID?
}

/// An internal memo ("email") sent to agents — prep instructions, expected
/// deliverables. Their acknowledgements collect in `replies`.
struct AgentMemo: Identifiable, Codable, Hashable {
    var id = UUID()
    var date = Date()
    var subject: String
    var body: String
    var recipientIDs: [String]
    var meetingDate: Date?
    var replies: [MemoReply] = []
}

struct MemoReply: Identifiable, Codable, Hashable {
    var id = UUID()
    var agentID: String
    var agentName: String
    var text: String
    var date = Date()
}

// MARK: - Hub

/// Owns scheduled meetings + the internal memo system.
/// • Schedules → real Apple Calendar event with a 15-minute alarm
///               (+ a local notification as backup).
/// • Memos     → delivered to each recipient agent through the relay;
///               their acknowledgements stream back into the thread.
@MainActor
final class MeetingHub: ObservableObject {
    @Published private(set) var meetings: [ScheduledMeeting] = []
    @Published private(set) var memos: [AgentMemo] = []
    /// Memo IDs with replies still arriving.
    @Published private(set) var awaiting: Set<UUID> = []

    private let eventStore = EKEventStore()
    private let meetingsURL: URL
    private let memosURL: URL

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("HermesMobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        meetingsURL = dir.appendingPathComponent("meetings.json")
        memosURL = dir.appendingPathComponent("memos.json")
        load()
    }

    var upcoming: [ScheduledMeeting] {
        meetings.filter { $0.date > Date().addingTimeInterval(-3600) }.sorted { $0.date < $1.date }
    }

    // MARK: Scheduling

    enum CalendarOutcome {
        case added            // in the user's calendar, alarm set
        case denied           // user refused calendar access
        case failed(String)   // EventKit error
    }

    /// Create the meeting: calendar event (15-min alarm), local notification,
    /// optional prep memo to all attendees.
    @discardableResult
    func schedule(topic: String, date: Date, attendees: [OrgAgent],
                  memoSubject: String?, memoBody: String?,
                  relay: HermesRelayConfiguration) async -> CalendarOutcome {
        var meeting = ScheduledMeeting(topic: topic, date: date, attendeeIDs: attendees.map(\.id))

        // 1. Apple Calendar + 15-minute alarm.
        let outcome: CalendarOutcome
        do {
            let granted = try await eventStore.requestWriteOnlyAccessToEvents()
            if granted {
                let event = EKEvent(eventStore: eventStore)
                event.title = "Hermes — \(topic)"
                event.startDate = date
                event.endDate = date.addingTimeInterval(30 * 60)
                event.notes = "Attendees: \(attendees.map(\.name).joined(separator: ", "))"
                event.calendar = eventStore.defaultCalendarForNewEvents
                event.addAlarm(EKAlarm(relativeOffset: -15 * 60))
                try eventStore.save(event, span: .thisEvent)
                meeting.eventIdentifier = event.eventIdentifier
                outcome = .added
            } else {
                outcome = .denied
            }
        } catch {
            outcome = .failed(error.localizedDescription)
        }

        // 2. Local notification 15 minutes before (backup alert).
        await scheduleNotification(topic: topic, date: date, id: meeting.id)

        // 3. Prep memo. An empty brief still sends — the agents get a default
        //    prep instruction — so "Send prep memo" never silently does nothing.
        if let subject = memoSubject?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subject.isEmpty {
            let trimmedBody = memoBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let body = trimmedBody.isEmpty
                ? "Prepare for this meeting. Confirm attendance, what you will prepare, and the deliverables you'll bring."
                : trimmedBody
            let memo = sendMemo(subject: subject, body: body, recipients: attendees,
                                meetingDate: date, relay: relay)
            meeting.memoID = memo.id
        }

        meetings.append(meeting)
        persist()
        LiveActivityManager.startMeetingCountdown(for: meeting)   // Dynamic Island countdown
        return outcome
    }

    func cancel(_ meeting: ScheduledMeeting) {
        meetings.removeAll { $0.id == meeting.id }
        persist()
        LiveActivityManager.endMeetingCountdown(for: meeting.id)
        if let identifier = meeting.eventIdentifier,
           let event = eventStore.event(withIdentifier: identifier) {
            try? eventStore.remove(event, span: .thisEvent)
        }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [meeting.id.uuidString])
    }

    private func scheduleNotification(topic: String, date: Date, id: UUID) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let fireDate = date.addingTimeInterval(-15 * 60)
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Meeting in 15 minutes"
        content.body = topic
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: trigger))
    }

    // MARK: Memos

    /// Send an internal memo to agents. Returns immediately; replies stream in.
    @discardableResult
    func sendMemo(subject: String, body: String, recipients: [OrgAgent],
                  meetingDate: Date?, relay: HermesRelayConfiguration) -> AgentMemo {
        let memo = AgentMemo(subject: subject, body: body,
                             recipientIDs: recipients.map(\.id), meetingDate: meetingDate)
        memos.insert(memo, at: 0)
        persist()

        guard relay.isConfigured, !recipients.isEmpty else { return memo }
        awaiting.insert(memo.id)

        for agent in recipients {
            var config = relay
            config.profile = agent.profileSlug
            let persona = agent.soul.isEmpty ? agent.summary : agent.soul

            var payload = "You are the \(agent.name) in a multi-agent company. Your remit: \(persona)\n\n"
            payload += "INTERNAL MEMO from the owner.\nSubject: \(subject)\n"
            if let meetingDate {
                payload += "Meeting: \(meetingDate.formatted(date: .abbreviated, time: .shortened))\n"
            }
            payload += "\n\(body)\n\nReply briefly in your role: confirm attendance, what you will prepare, and the deliverables you'll bring."

            let session = "hermes-mobile-memo-\(agent.id)"
            Task { [weak self] in
                let text: String
                do {
                    text = try await HermesRelayClient(configuration: config)
                        .collect(payload, sessionKey: session)
                } catch {
                    text = "⚠️ \(error.localizedDescription)"
                }
                self?.appendReply(memoID: memo.id, agent: agent, text: text)
            }
        }
        return memo
    }

    private func appendReply(memoID: UUID, agent: OrgAgent, text: String) {
        guard let index = memos.firstIndex(where: { $0.id == memoID }) else { return }
        memos[index].replies.append(MemoReply(agentID: agent.id, agentName: agent.name, text: text))
        if memos[index].replies.count >= memos[index].recipientIDs.count {
            awaiting.remove(memoID)
        }
        persist()
    }

    /// File an already-written memo (e.g. debate minutes) without sending
    /// it through the relay.
    func fileMinutes(subject: String, body: String, recipients: [OrgAgent]) {
        let memo = AgentMemo(subject: subject, body: body,
                             recipientIDs: recipients.map(\.id), meetingDate: nil)
        memos.insert(memo, at: 0)
        persist()
    }

    func deleteMemo(_ memo: AgentMemo) {
        memos.removeAll { $0.id == memo.id }
        awaiting.remove(memo.id)
        persist()
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: meetingsURL),
           let decoded = try? JSONDecoder().decode([ScheduledMeeting].self, from: data) {
            meetings = decoded
        }
        if let data = try? Data(contentsOf: memosURL),
           let decoded = try? JSONDecoder().decode([AgentMemo].self, from: data) {
            memos = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(meetings) {
            try? data.write(to: meetingsURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(memos) {
            try? data.write(to: memosURL, options: .atomic)
        }
    }
}
