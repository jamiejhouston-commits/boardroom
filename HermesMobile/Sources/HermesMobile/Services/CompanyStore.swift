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

    func refresh(relay: HermesRelayConfiguration) async {
        guard relay.isConfigured else { return }
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

    private func apply(_ fresh: CompanyState) {
        state = fresh
        Self.notifyNewGates(in: fresh)
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
            let content = UNMutableNotificationContent()
            content.title = initiative.stage == "gate2"
                ? "Demo Day — the team has something to show you"
                : "The board needs your greenlight"
            content.body = "\(initiative.title): \(initiative.pitch)"
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "gate-\(key)-\(Int(now))",
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
/// delegate iOS suppresses them entirely when the app is open.
/// Stateless, hence @unchecked Sendable is sound.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound, .badge])
    }
}
