import Foundation

/// A small, plain snapshot of the company the app writes into the shared App
/// Group container so the home/lock-screen widgets can render instantly without
/// a network call. Kept deliberately tiny — widgets get a fraction of a second
/// of CPU, so everything they show is precomputed here.
///
/// Compiled into BOTH the app and the HermesWidgets extension. Foundation only —
/// no app-internal types — so the widget target can use it.
struct CompanySnapshot: Codable, Equatable {
    var enabled: Bool
    var taskMode: Bool
    var pendingGates: Int
    var headline: String        // the one thing to glance at (initiative or task)
    var detail: String          // its stage / status line
    var tasksTodo: Int
    var tasksDoing: Int
    var tasksDone: Int
    var updated: Date

    static let placeholder = CompanySnapshot(
        enabled: false, taskMode: false, pendingGates: 0,
        headline: "Boardroom", detail: "Tap to open your company",
        tasksTodo: 0, tasksDoing: 0, tasksDone: 0, updated: Date(timeIntervalSince1970: 0))

    var tasksTotal: Int { tasksTodo + tasksDoing + tasksDone }

    /// One-line status used by the inline lock-screen widget + Dynamic Island.
    var statusLine: String {
        if pendingGates > 0 {
            return pendingGates == 1 ? "1 decision waiting" : "\(pendingGates) decisions waiting"
        }
        if !enabled { return "Company halted" }
        if taskMode { return tasksDoing > 0 ? "Working your list" : "On your list" }
        return "Company running"
    }
}

/// Read/write the snapshot from the shared App Group container. The same suite
/// name is used by the app (writer) and the widget extension (reader).
enum CompanySharedStore {
    /// Must match the App Group entitlement on both targets (project.yml).
    static let appGroup = "group.com.jamiehouston.boardroom"
    private static let key = "company.snapshot.v1"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func write(_ snapshot: CompanySnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: key)
    }

    static func read() -> CompanySnapshot {
        guard let data = defaults?.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(CompanySnapshot.self, from: data)
        else { return .placeholder }
        return snapshot
    }
}
