import EventKit
import Foundation
import UserNotifications
import WidgetKit

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

    /// Set the investment thesis without toggling the company on (Genesis 2.0).
    func setThesis(_ thesis: String, relay: HermesRelayConfiguration) async {
        await run(relay) { try await $0.companySetThesis(thesis) }
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

    /// Owner pitches an idea by voice or text — seeded as an initiative the
    /// team researches, debates, and brings to the greenlight gate.
    func submitDirective(_ text: String, relay: HermesRelayConfiguration) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await run(relay) { try await $0.companyDirective(text: trimmed) }
    }

    // MARK: Ask the company

    /// Submit a question; returns the created ask to poll, or nil on failure.
    func ask(_ question: String, relay: HermesRelayConfiguration) async -> CompanyAsk? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard relay.isConfigured else {
            errorMessage = "Connect your relay first (Settings → Mac Relay)."
            return nil
        }
        do {
            let ask = try await HermesRelayClient(configuration: relay).companyAsk(question: trimmed)
            errorMessage = nil
            return ask
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func askDetail(id: String, relay: HermesRelayConfiguration) async -> CompanyAsk? {
        try? await HermesRelayClient(configuration: relay).companyAskDetail(id: id)
    }

    // MARK: Schedules (the Cron)

    var schedules: [CompanySchedule] { state.schedules ?? [] }

    func addSchedule(title: String, kind: String, text: String, cadence: String,
                     atHour: Int, atMinute: Int, weekday: Int,
                     relay: HermesRelayConfiguration) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await run(relay) {
            try await $0.companyAddSchedule(title: title, kind: kind, text: text,
                                            cadence: cadence, atHour: atHour,
                                            atMinute: atMinute, weekday: weekday)
        }
    }

    func deleteSchedule(id: String, relay: HermesRelayConfiguration) async {
        await run(relay) { try await $0.companyDeleteSchedule(id: id) }
    }

    func toggleSchedule(id: String, enabled: Bool, relay: HermesRelayConfiguration) async {
        await run(relay) { try await $0.companyToggleSchedule(id: id, enabled: enabled) }
    }

    // MARK: Kanban task board

    var tasks: [CompanyTask] { state.tasks ?? [] }
    var taskMode: Bool { state.taskMode ?? false }

    func tasks(in column: TaskColumn) -> [CompanyTask] {
        tasks.filter { $0.column == column }
    }

    /// Hand the team a list (one task per line). Blank lines are dropped server-side.
    func addTasks(_ raw: String, relay: HermesRelayConfiguration) async {
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return }
        await run(relay) { try await $0.companyAddTasks(lines) }
    }

    /// Flip the "Kanban List" toggle.
    func setTaskMode(_ on: Bool, relay: HermesRelayConfiguration) async {
        await run(relay) { try await $0.companyTaskMode(on: on) }
    }

    func clearDoneTasks(relay: HermesRelayConfiguration) async {
        await run(relay) { try await $0.companyClearDoneTasks() }
    }

    func deleteTask(id: String, relay: HermesRelayConfiguration) async {
        await run(relay) { try await $0.companyDeleteTask(id: id) }
    }

    /// Run a company mutation and fold the fresh state back in, surfacing errors.
    private func run(_ relay: HermesRelayConfiguration,
                     _ call: (HermesRelayClient) async throws -> CompanyState) async {
        guard relay.isConfigured else {
            errorMessage = "Connect your relay first (Settings → Mac Relay)."
            return
        }
        do {
            let fresh = try await call(HermesRelayClient(configuration: relay))
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
        writeWidgetSnapshot(fresh)
    }

    /// The current glanceable snapshot, computed live from state — used by the
    /// AR headquarters' status board as well as the widgets.
    var snapshot: CompanySnapshot { Self.makeSnapshot(from: state) }

    /// Pure: fold company state into the small snapshot the widgets, Dynamic
    /// Island, and AR office all render.
    static func makeSnapshot(from state: CompanyState) -> CompanySnapshot {
        let tasks = state.tasks ?? []
        let gates = state.initiatives.filter(\.isAwaitingDecision)
        let doing = tasks.filter { $0.column == .doing }
        let inMotion = state.initiatives.first { !$0.isAwaitingDecision && !$0.isTerminal }

        let headline: String
        let detail: String
        if let gate = gates.first {
            headline = gate.title
            detail = gate.stageLabel
        } else if let task = doing.first {
            headline = task.text
            detail = "Building now"
        } else if (state.taskMode ?? false), let next = tasks.first(where: { $0.column == .todo }) {
            headline = next.text
            detail = "Next on your list"
        } else if let initiative = inMotion {
            headline = initiative.title
            detail = initiative.stageLabel
        } else if state.enabled {
            headline = "Scouting the market"
            detail = "Looking for the next idea to build"
        } else {
            headline = "Company halted"
            detail = "Switch it on to put the team to work"
        }

        return CompanySnapshot(
            enabled: state.enabled,
            taskMode: state.taskMode ?? false,
            pendingGates: gates.count,
            headline: headline,
            detail: detail,
            tasksTodo: tasks.filter { $0.column == .todo }.count,
            tasksDoing: doing.count,
            tasksDone: tasks.filter { $0.column == .done }.count,
            updated: Date())
    }

    /// Precompute the glanceable snapshot for the home/lock widgets + Dynamic
    /// Island, drop it in the shared App Group, and ask iOS to reload widgets.
    private func writeWidgetSnapshot(_ fresh: CompanyState) {
        let snapshot = Self.makeSnapshot(from: fresh)
        CompanySharedStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        LiveActivityManager.syncCompanyPulse(snapshot)
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
