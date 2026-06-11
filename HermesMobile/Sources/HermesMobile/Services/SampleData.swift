import Foundation

enum SampleData {
    static let agents: [AgentProfile] = [
        AgentProfile(
            id: UUID(uuidString: "C8C31536-9A74-4B6E-9F65-995C94C5E1F1")!,
            handle: "Atlas",
            role: "Coordinator",
            status: .active,
            accentHex: "39D98A",
            backend: .local,
            memorySummary: "Tracks product direction, open decisions, and the current sprint narrative.",
            soulMarkdown: """
            # Atlas

            You are the coordinator. Keep the user oriented, split work into concrete tasks, and protect momentum.

            ## Operating Style
            - Prefer short status reports.
            - Call out blockers early.
            - Delegate isolated research or tool-heavy tasks.
            """,
            skills: ["planning", "memory", "delegation", "briefing"],
            connectors: ConnectorSurface.defaults,
            jobs: [
                .init(id: UUID(), title: "Daily project brief", detail: "Summarize active work and decisions.", progress: 0.74, priority: "High", dueLabel: "08:00"),
                .init(id: UUID(), title: "Route inbox asks", detail: "Classify inbound messages across connected surfaces.", progress: 0.42, priority: "Medium", dueLabel: "Live")
            ],
            lastActive: Date()
        ),
        AgentProfile(
            id: UUID(uuidString: "5DAD7D51-8E12-4BBE-9E20-F5C7714A3B02")!,
            handle: "Vega",
            role: "Research",
            status: .thinking,
            accentHex: "55C7F7",
            backend: .docker,
            memorySummary: "Maintains source trails, model comparisons, and research summaries.",
            soulMarkdown: """
            # Vega

            You are the research agent. Verify unstable claims, cite primary sources, and keep findings tight.

            ## Tool Rules
            - Use web search when facts may have changed.
            - Prefer primary docs, specs, and papers.
            - Return concise source-backed conclusions.
            """,
            skills: ["web search", "browser automation", "citations", "vision"],
            connectors: ConnectorSurface.defaults,
            jobs: [
                .init(id: UUID(), title: "Hermes feature watch", detail: "Track desktop release changes and docs updates.", progress: 0.58, priority: "High", dueLabel: "Hourly"),
                .init(id: UUID(), title: "Model matrix", detail: "Compare available models for tool-heavy agents.", progress: 0.28, priority: "Low", dueLabel: "Fri")
            ],
            lastActive: Date().addingTimeInterval(-240)
        ),
        AgentProfile(
            id: UUID(uuidString: "B4959737-08F0-4A78-AE3B-04EF2DF6D7EF")!,
            handle: "Forge",
            role: "Builder",
            status: .delegated,
            accentHex: "FFB020",
            backend: .ssh,
            memorySummary: "Stores implementation patterns, generated skills, and terminal runbooks.",
            soulMarkdown: """
            # Forge

            You are the builder. Work in sandboxes, ship tested changes, and keep terminal output actionable.

            ## Boundaries
            - Never mutate user files without intent.
            - Prefer focused tests.
            - Keep generated skills small and reusable.
            """,
            skills: ["terminal", "python rpc", "codegen", "sandboxing"],
            connectors: ConnectorSurface.defaults,
            jobs: [
                .init(id: UUID(), title: "iOS shell prototype", detail: "Build the phone-native Hermes command surface.", progress: 0.66, priority: "High", dueLabel: "Now"),
                .init(id: UUID(), title: "Sandbox probe", detail: "Check local and Docker backend availability.", progress: 0.35, priority: "Medium", dueLabel: "Today")
            ],
            lastActive: Date().addingTimeInterval(-90)
        )
    ]

    static func events(for agents: [AgentProfile]) -> [WarRoomEvent] {
        guard agents.count >= 3 else { return [] }
        return [
            .init(id: UUID(), agentID: agents[2].id, timestamp: Date().addingTimeInterval(-20), title: "Subagent spawned", detail: "Opened an isolated worker for SwiftUI project scaffolding.", kind: .delegation),
            .init(id: UUID(), agentID: agents[0].id, timestamp: Date().addingTimeInterval(-80), title: "Memory updated", detail: "Captured preference: phone-first, full Hermes Desktop parity over time.", kind: .memory),
            .init(id: UUID(), agentID: agents[1].id, timestamp: Date().addingTimeInterval(-160), title: "Web source checked", detail: "Desktop feature set mapped: connect, memory, schedule, delegate, search, sandbox.", kind: .tool),
            .init(id: UUID(), agentID: agents[0].id, timestamp: Date().addingTimeInterval(-260), title: "Automation planned", detail: "Queued future build slices for gateway, scheduling, and tool execution.", kind: .schedule)
        ]
    }
}
