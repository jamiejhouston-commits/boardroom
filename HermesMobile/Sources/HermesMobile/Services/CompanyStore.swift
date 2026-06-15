import EventKit
import Foundation
import UserNotifications

/// Window into the autonomous company running on the Mac relay.
/// Fetches state, applies the owner's gate decisions, and fires a local
/// notification whenever a NEW initiative arrives at a decision gate.
@MainActor
final class CompanyStore: ObservableObject {
    @Published private(set) var state: CompanyState = .empty
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private nonisolated static let seenGatesKey = "company.seenGateIDs"

    var pendingGates: [CompanyInitiative] {
        state.initiatives.filter(\.isAwaitingDecision)
    }

    var meetings: [CompanyMeeting] { state.meetings ?? [] }
    var liveMeeting: CompanyMeeting? { meetings.first(where: \.isLive) }

    func meetingDetail(id: String, relay: HermesRelayConfiguration) async -> CompanyMeeting? {
        try? await HermesRelayClient(configuration: relay).companyMeetingDetail(id: id)
    }

    /// Speak into a meeting — the agents respond to your input.
    func meetingSay(id: String, text: String, relay: HermesRelayConfiguration) async {
        try? await HermesRelayClient(configuration: relay).companyMeetingSay(id: id, text: text)
    }

    func refresh(relay: HermesRelayConfiguration) async {
        // !isLoading: the 60s ticker must not stack a second fetch on a slow
        // relay (causes isLoading flicker + duplicate gate notifications).
        guard relay.isConfigured, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await HermesRelayClient(configuration: relay).companyState()
            apply(fresh)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool, thesis: String, relay: HermesRelayConfiguration) async {
        guard relay.isConfigured else {
            errorMessage = "Connect your relay first (Settings → Mac Relay)."
            return
        }
        do {
            let client = HermesRelayClient(configuration: relay)
            let fresh = enabled
                ? try await client.companyStart(thesis: thesis)
                : try await client.companyHalt()
            apply(fresh)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func decide(id: String, decision: CompanyDecision, note: String,
                relay: HermesRelayConfiguration) async {
        do {
            let fresh = try await HermesRelayClient(configuration: relay)
                .companyGate(id: id, decision: decision, note: note)
            apply(fresh)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func initiativeDetail(id: String, relay: HermesRelayConfiguration) async -> CompanyInitiative? {
        try? await HermesRelayClient(configuration: relay).companyInitiativeDetail(id: id)
    }

    /// Tell the team to keep working on a finished project — next iteration.
    func iterate(id: String, instruction: String, relay: HermesRelayConfiguration) async {
        do {
            let fresh = try await HermesRelayClient(configuration: relay)
                .companyIterate(id: id, instruction: instruction)
            apply(fresh)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ fresh: CompanyState) {
        let hadLive = liveMeeting?.id
        state = fresh
        Self.notifyNewGates(in: fresh)
        // Ping when a brand-new meeting goes live so the owner can drop in.
        if let live = fresh.meetings?.first(where: \.isLive), live.id != hadLive {
            Self.notifyLiveMeeting(live)
        }
    }

    nonisolated static func notifyLiveMeeting(_ meeting: CompanyMeeting) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "🟢 Your team is meeting now"
            content.body = meeting.topic + " — tap to listen in."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "meeting-\(meeting.id)",
                                             content: content, trigger: nil))
        }
    }

    // MARK: New-gate notifications (shared with background refresh)

    /// Fire a local notification for every pending gate, re-reminding every
    /// 4h until the owner acts. Requests permission first — without it iOS
    /// silently drops everything (the original "agents are sleeping" bug).
    /// `nonisolated static` so the BGAppRefresh path can reuse it.
    nonisolated static func notifyNewGates(in state: CompanyState) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            deliverGateNotifications(state: state)
        }
    }

    private nonisolated static func deliverGateNotifications(state: CompanyState) {
        let defaults = UserDefaults.standard
        var lastNotified = defaults.dictionary(forKey: seenGatesKey) as? [String: Double] ?? [:]
        let gates = state.initiatives.filter(\.isAwaitingDecision)
        let now = Date().timeIntervalSince1970
        let remindEvery: Double = 4 * 3600

        for initiative in gates {
            let key = "\(initiative.id)-\(initiative.stage)"
            if let last = lastNotified[key], now - last < remindEvery { continue }
            // Framed as a meeting invite from the CEO — with an
            // add-to-calendar action button right on the notification.
            let content = UNMutableNotificationContent()
            if initiative.stage == "gate2" {
                content.title = "📅 Demo Day — the team wants to present"
                content.body = "\(initiative.title) is built. Approve to ship, or add Demo Day to your calendar."
            } else {
                content.title = "📅 The CEO requests a greenlight meeting"
                content.body = "\(initiative.title): \(initiative.pitch)"
            }
            content.sound = .default
            content.categoryIdentifier = NotificationPresenter.gateCategoryID
            content.userInfo = ["initiativeTitle": initiative.title,
                                "stage": initiative.stage]
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "gate-\(key)",   // stable: replaces, never stacks
                                      content: content, trigger: nil))
            lastNotified[key] = now
        }

        // Forget gates that were decided; keep the app badge = decisions waiting.
        let pendingKeys = Set(gates.map { "\($0.id)-\($0.stage)" })
        lastNotified = lastNotified.filter { pendingKeys.contains($0.key) }
        defaults.set(lastNotified, forKey: seenGatesKey)
        UNUserNotificationCenter.current().setBadgeCount(gates.count)
    }
}

/// Shows notification banners while the app is foreground — without this
/// delegate iOS suppresses them entirely when the app is open — and handles
/// the "Add meeting to Calendar" action on gate invites.
/// Stateless, hence @unchecked Sendable is sound.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationPresenter()

    static let gateCategoryID = "BOARDROOM_GATE"
    static let addToCalendarActionID = "ADD_GATE_MEETING_TO_CALENDAR"

    /// Call once at launch so gate notifications get the calendar button.
    func registerCategories() {
        let addToCalendar = UNNotificationAction(
            identifier: Self.addToCalendarActionID,
            title: "Add meeting to Calendar", options: [])
        let gateCategory = UNNotificationCategory(
            identifier: Self.gateCategoryID, actions: [addToCalendar],
            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([gateCategory])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == Self.addToCalendarActionID,
              let title = info["initiativeTitle"] as? String else { return }
        let isDemoDay = (info["stage"] as? String) == "gate2"
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Self.addGateMeeting(title: title, isDemoDay: isDemoDay) { done.resume() }
        }
    }

    /// Books "Boardroom — Greenlight review/Demo Day: <title>" at the next
    /// top of the hour (≥30 min away), 30 min long, 15-min alert.
    private static func addGateMeeting(title: String, isDemoDay: Bool,
                                       completion: @escaping @Sendable () -> Void) {
        let store = EKEventStore()
        store.requestWriteOnlyAccessToEvents { granted, _ in
            defer { completion() }
            guard granted else { return }
            let start = Calendar.current.nextDate(
                after: Date().addingTimeInterval(30 * 60),
                matching: DateComponents(minute: 0),
                matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
            let event = EKEvent(eventStore: store)
            event.title = isDemoDay
                ? "Boardroom — Demo Day: \(title)"
                : "Boardroom — Greenlight review: \(title)"
            event.startDate = start
            event.endDate = start.addingTimeInterval(30 * 60)
            event.calendar = store.defaultCalendarForNewEvents
            event.addAlarm(EKAlarm(relativeOffset: -15 * 60))
            try? store.save(event, span: .thisEvent)
        }
    }
}
