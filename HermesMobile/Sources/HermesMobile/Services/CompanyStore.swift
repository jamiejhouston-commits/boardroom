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

    /// Fire a local notification for every gate not seen before, then record
    /// them. `nonisolated static` so the BGAppRefresh path can reuse it.
    nonisolated static func notifyNewGates(in state: CompanyState) {
        let defaults = UserDefaults.standard
        let seen = Set(defaults.stringArray(forKey: seenGatesKey) ?? [])
        let gates = state.initiatives.filter(\.isAwaitingDecision)
        let unseen = gates.filter { !seen.contains("\($0.id)-\($0.stage)") }

        for initiative in unseen {
            let content = UNMutableNotificationContent()
            content.title = initiative.stage == "gate2"
                ? "Demo Day — the team has something to show you"
                : "The board needs your greenlight"
            content.body = "\(initiative.title): \(initiative.pitch)"
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "gate-\(initiative.id)-\(initiative.stage)",
                                      content: content, trigger: nil))
        }
        defaults.set(gates.map { "\($0.id)-\($0.stage)" }, forKey: seenGatesKey)
    }
}
