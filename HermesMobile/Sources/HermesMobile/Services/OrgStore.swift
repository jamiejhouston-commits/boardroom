import Foundation

/// The user's live, editable organization. Seeds with the default org, persists every change.
@MainActor
final class OrgStore: ObservableObject {
    @Published private(set) var agents: [OrgAgent] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("HermesMobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? dir.appendingPathComponent("org.json")
        load()
    }

    func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([OrgAgent].self, from: data),
           !decoded.isEmpty {
            agents = decoded
            runMigrations()
        } else {
            agents = HermesOrg.all
            persist()
        }
    }

    /// One-time additions for orgs saved before a seed agent existed.
    /// Flag-guarded so deleting the agent afterwards sticks.
    private func runMigrations() {
        let flag = "org.migration.executiveAssistant.v1"
        if !UserDefaults.standard.bool(forKey: flag) {
            UserDefaults.standard.set(true, forKey: flag)
            if agent(id: "executive_assistant") == nil, let boss = ceo,
               let seed = HermesOrg.all.first(where: { $0.id == "executive_assistant" }) {
                var secretary = seed
                secretary.parent = boss.id
                agents.append(secretary)
                agents.sort(by: Self.order)
                persist()
            }
        }
    }

    func resetToDefault() {
        agents = HermesOrg.all
        persist()
    }

    /// Replace the whole org with a preset's agents.
    func applyPreset(_ agents: [OrgAgent]) {
        self.agents = agents.sorted(by: Self.order)
        persist()
    }

    // MARK: Queries

    var ceo: OrgAgent? { agents.first { $0.tier == .ceo } }
    var managers: [OrgAgent] { agents.filter { $0.tier == .manager } }
    var leadership: [OrgAgent] { agents.filter { $0.tier != .sub } }     // CEO + department heads
    var topAgent: OrgAgent? { ceo ?? managers.first ?? agents.first }
    func children(of id: String) -> [OrgAgent] { agents.filter { $0.parent == id } }
    func agent(id: String) -> OrgAgent? { agents.first { $0.id == id } }

    // MARK: Mutations

    func upsert(_ agent: OrgAgent) {
        if let i = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[i] = agent
        } else {
            agents.append(agent)
        }
        agents.sort(by: Self.order)
        persist()
    }

    func updateSoul(id: String, soul: String) {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[i].soul = soul
        persist()
    }

    func delete(_ agent: OrgAgent) {
        agents.removeAll { $0.id == agent.id }
        // Re-parent any orphaned children to the CEO so nothing disappears.
        let ceoID = ceo?.id
        for i in agents.indices where agents[i].parent == agent.id {
            agents[i].parent = ceoID
        }
        persist()
    }

    /// A unique, stable id derived from a display name.
    func newID(base: String) -> String {
        let slug = base.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let root = slug.isEmpty ? "agent" : slug
        var candidate = root
        var n = 2
        while agents.contains(where: { $0.id == candidate }) {
            candidate = "\(root)-\(n)"
            n += 1
        }
        return candidate
    }

    private static func order(_ a: OrgAgent, _ b: OrgAgent) -> Bool {
        func rank(_ x: OrgAgent) -> Int { x.tier == .ceo ? 0 : (x.tier == .manager ? 1 : 2) }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return a.name < b.name
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(agents) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
