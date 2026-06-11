import Foundation

@MainActor
final class AgentProfileStore: ObservableObject {
    @Published private(set) var agents: [AgentProfile] = []
    @Published private(set) var events: [WarRoomEvent] = []

    private let rootURL: URL
    private let profilesURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil) {
        let baseURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.rootURL = baseURL.appendingPathComponent("HermesMobile", isDirectory: true)
        self.profilesURL = self.rootURL.appendingPathComponent("agents", isDirectory: true)

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func load() {
        do {
            try FileManager.default.createDirectory(at: profilesURL, withIntermediateDirectories: true)
            let profileFiles = try FileManager.default.contentsOfDirectory(
                at: profilesURL,
                includingPropertiesForKeys: nil
            )
            .compactMap { url -> URL? in
                if url.lastPathComponent == "profile.json" || url.pathExtension == "json" {
                    return url
                }

                let nestedProfile = url.appendingPathComponent("profile.json")
                return FileManager.default.fileExists(atPath: nestedProfile.path) ? nestedProfile : nil
            }

            if profileFiles.isEmpty {
                agents = SampleData.agents
                events = SampleData.events(for: agents)
                try persistAll()
                return
            }

            agents = try profileFiles.map { url in
                let data = try Data(contentsOf: url)
                var profile = try decoder.decode(AgentProfile.self, from: data)
                let soulURL = soulURL(for: profile.id)
                if let soul = try? String(contentsOf: soulURL, encoding: .utf8), !soul.isEmpty {
                    profile.soulMarkdown = soul
                }
                return profile
            }
            .sorted { $0.handle < $1.handle }

            events = SampleData.events(for: agents)
        } catch {
            agents = SampleData.agents
            events = SampleData.events(for: SampleData.agents)
        }
    }

    func updateSoul(for agent: AgentProfile, soulMarkdown: String) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[index].soulMarkdown = soulMarkdown
        agents[index].lastActive = Date()
        try? persist(agents[index])
    }

    func addAgent(
        handle: String,
        role: String,
        accentHex: String,
        backend: SandboxBackend,
        memorySummary: String,
        soulMarkdown: String,
        skills: [String]
    ) {
        let name = handle.isEmpty ? "New Agent" : handle
        let profile = AgentProfile(
            id: UUID(),
            handle: name,
            role: role.isEmpty ? "Agent" : role,
            status: .idle,
            accentHex: accentHex,
            backend: backend,
            memorySummary: memorySummary.isEmpty ? "New agent — no memory captured yet." : memorySummary,
            soulMarkdown: soulMarkdown.isEmpty ? "# \(name)\n" : soulMarkdown,
            skills: skills,
            connectors: ConnectorSurface.defaults,
            jobs: [],
            lastActive: Date()
        )
        agents.append(profile)
        agents.sort { $0.handle < $1.handle }
        try? persist(profile)
    }

    func addDemoEvent() {
        guard let agent = agents.randomElement() else { return }
        let options = [
            ("Tool call finished", "Browser automation returned 3 relevant sources.", WarRoomEvent.EventKind.tool),
            ("Memory compacted", "Updated project memory with the latest user preference.", WarRoomEvent.EventKind.memory),
            ("Subagent delegated", "Spawned an isolated worker for API contract discovery.", WarRoomEvent.EventKind.delegation),
            ("Schedule queued", "Prepared unattended status brief for tomorrow morning.", WarRoomEvent.EventKind.schedule),
            ("Reasoning pass", "Compared sandbox backends for the requested workflow.", WarRoomEvent.EventKind.thought)
        ]
        let pick = options.randomElement()!
        events.insert(
            WarRoomEvent(
                id: UUID(),
                agentID: agent.id,
                timestamp: Date(),
                title: pick.0,
                detail: pick.1,
                kind: pick.2
            ),
            at: 0
        )
        events = Array(events.prefix(30))
    }

    func fileLocationLabel(for agent: AgentProfile) -> String {
        soulURL(for: agent.id).path
    }

    private func persistAll() throws {
        try agents.forEach(persist)
    }

    private func persist(_ profile: AgentProfile) throws {
        let folder = folderURL(for: profile.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let profileURL = folder.appendingPathComponent("profile.json")
        let data = try encoder.encode(profile)
        try data.write(to: profileURL, options: .atomic)
        try profile.soulMarkdown.write(to: folder.appendingPathComponent("soul.md"), atomically: true, encoding: .utf8)
    }

    private func folderURL(for id: UUID) -> URL {
        profilesURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func soulURL(for id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent("soul.md")
    }
}
