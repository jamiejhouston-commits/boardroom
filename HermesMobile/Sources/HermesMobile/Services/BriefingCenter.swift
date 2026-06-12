import Foundation
import UserNotifications

/// The Morning Briefing — your Executive Secretary opens the day for you:
/// today's meetings, overnight memo replies, a status line per department,
/// and the decisions waiting on you. Optional daily notification; read or
/// spoken aloud.
@MainActor
final class BriefingCenter: ObservableObject {
    @Published private(set) var briefing: String = ""
    @Published private(set) var generatedAt: Date?
    @Published private(set) var isGenerating = false
    @Published private(set) var isSpeaking = false
    @Published var lastError: String?

    @Published var notifyDaily: Bool {
        didSet { UserDefaults.standard.set(notifyDaily, forKey: "briefing.notify"); rescheduleNotification() }
    }
    @Published var notifyHour: Int {
        didSet { UserDefaults.standard.set(notifyHour, forKey: "briefing.hour"); rescheduleNotification() }
    }

    private let voice = AgentVoice()

    init() {
        notifyDaily = UserDefaults.standard.bool(forKey: "briefing.notify")
        notifyHour = UserDefaults.standard.object(forKey: "briefing.hour") as? Int ?? 8
        briefing = UserDefaults.standard.string(forKey: "briefing.last") ?? ""
        generatedAt = UserDefaults.standard.object(forKey: "briefing.lastDate") as? Date
    }

    /// True when today's briefing has already been generated.
    var isFreshToday: Bool {
        guard let generatedAt else { return false }
        return Calendar.current.isDateInToday(generatedAt) && !briefing.isEmpty
    }

    // MARK: Generation

    func generate(org: OrgStore, hub: MeetingHub, relay: HermesRelayConfiguration) async {
        guard !isGenerating else { return }
        guard relay.isConfigured else {
            lastError = "Connect your relay first (Settings → Mac Relay)."
            return
        }
        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        let secretary = org.agent(id: "executive_assistant") ?? org.ceo
        var config = relay
        config.profile = secretary?.profileSlug ?? "default"

        // Real data in → real briefing out.
        let today = hub.upcoming.filter { Calendar.current.isDateInToday($0.date) }
        let meetingLines = today.isEmpty
            ? "none scheduled"
            : today.map { "\($0.topic) at \($0.date.formatted(date: .omitted, time: .shortened)) (\($0.attendeeIDs.count) attendees)" }
                .joined(separator: "; ")

        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        let freshReplies = hub.memos.flatMap { memo in
            memo.replies.filter { $0.date > dayAgo }.map { "\($0.agentName) re: \(memo.subject)" }
        }
        let replyLines = freshReplies.isEmpty ? "none" : freshReplies.prefix(8).joined(separator: "; ")
        let departments = org.managers.map(\.name).joined(separator: ", ")

        let payload = """
        You are \(secretary?.name ?? "the Executive Secretary"), delivering the owner's MORNING BRIEFING. Be warm but efficient — a real chief-of-staff opening the day.

        Today's date: \(Date().formatted(date: .complete, time: .omitted))
        Today's meetings: \(meetingLines)
        Memo replies in the last 24h: \(replyLines)
        Departments: \(departments)

        Write the briefing: 1) a one-line greeting, 2) today's schedule, 3) what came in overnight, 4) one sharp status line per department (invent plausible, business-like status), 5) "Three things that need your decision today" as short bullets. Keep the whole thing under 220 words. Plain text, no markdown headers.
        """

        var collected = ""
        do {
            for try await event in HermesRelayClient(configuration: config).stream(payload, sessionKey: "hermes-mobile-briefing") {
                switch event.type {
                case .start: break
                case .delta: collected += event.text ?? ""
                case .done:
                    if collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let reply = event.reply { collected = reply }
                case .error:
                    throw HermesRelayError.server(event.message ?? "Briefing failed.")
                }
            }
        } catch {
            lastError = error.localizedDescription
            return
        }

        briefing = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        generatedAt = Date()
        UserDefaults.standard.set(briefing, forKey: "briefing.last")
        UserDefaults.standard.set(generatedAt, forKey: "briefing.lastDate")
    }

    // MARK: Read aloud

    func toggleSpeech(secretaryID: String, voice voiceModel: String,
                      relay: HermesRelayConfiguration) {
        if isSpeaking {
            voice.stop()
            isSpeaking = false
        } else if !briefing.isEmpty {
            isSpeaking = true
            let text = briefing
            Task { [weak self] in
                await self?.voice.speak(text, seedFrom: secretaryID,
                                        voice: voiceModel, relay: relay)
                self?.isSpeaking = false
            }
        }
    }

    // MARK: Daily notification

    private func rescheduleNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["hermes-morning-briefing"])
        guard notifyDaily else { return }

        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Your morning briefing is ready"
            content.body = "Your secretary has the day lined up — meetings, overnight replies, and the decisions waiting on you."
            content.sound = .default
            var components = DateComponents()
            components.hour = notifyHour
            components.minute = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            try? await center.add(UNNotificationRequest(identifier: "hermes-morning-briefing",
                                                        content: content, trigger: trigger))
        }
    }
}
