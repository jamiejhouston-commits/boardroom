import Foundation

/// Role-aligned Hermes skills + plugins for each agent. These are REAL —
/// `skills` are passed to `hermes chat -s ...` so the agent actually loads
/// them, not just displays them. Mirrors what's installed on the Mac relay.
enum SkillLibrary {

    /// Skills every agent gets — the baseline toolkit.
    static let core = ["hermes-agent", "defuddle"]

    /// Role keyword → extra skills that role should be equipped with.
    private static let byKeyword: [(words: [String], skills: [String])] = [
        (["ceo", "chief executive", "general manager", "orchestrat", "gm"],
         ["workspace-dispatch", "apple-reminders", "apple-notes"]),
        (["research", "analyst", "intelligence", "insight", "data"],
         ["firecrawl", "defuddle", "obsidian-markdown"]),
        (["build", "engineer", "develop", "cto", "software", "frontend", "backend"],
         ["claude-code", "codex", "local-agent-workspace"]),
        (["devops", "infra", "deploy", "sre", "operation", "coo"],
         ["claude-code", "macos-computer-use", "workspace-dispatch"]),
        (["qa", "quality", "test"],
         ["claude-code", "macos-computer-use"]),
        (["security", "infosec", "compliance"],
         ["claude-code", "firecrawl"]),
        (["market", "growth", "brand", "content", "social", "seo"],
         ["firecrawl", "defuddle", "apple-notes"]),
        (["finance", "cfo", "account", "payroll", "budget"],
         ["obsidian-bases", "apple-notes"]),
        (["legal", "lawyer", "counsel", "contract"],
         ["defuddle", "obsidian-markdown"]),
        (["assistant", "secretary", "coordinat", "chief of staff", "scheduler"],
         ["apple-reminders", "apple-notes", "imessage", "apple-utilities"]),
        (["product", "design", "creative"],
         ["firecrawl", "obsidian-canvas"]),
        (["knowledge", "documentation", "librarian"],
         ["obsidian-markdown", "obsidian-bases", "json-canvas"]),
        (["customer", "support", "success", "concierge"],
         ["imessage", "apple-reminders"]),
    ]

    /// A solid, role-aligned skill set for any agent (deduplicated, ordered).
    static func skills(for agent: OrgAgent) -> [String] {
        let haystack = "\(agent.title) \(agent.name) \(agent.summary)".lowercased()
        var result = core
        for entry in byKeyword where entry.words.contains(where: haystack.contains) {
            result.append(contentsOf: entry.skills)
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    /// Suggested plugins by role (the user enables them on the Mac).
    static func plugins(for agent: OrgAgent) -> [String] {
        let haystack = "\(agent.title) \(agent.name) \(agent.summary)".lowercased()
        if ["research", "market", "growth", "data", "analyst"].contains(where: haystack.contains) {
            return ["browser-browser-use"]
        }
        return []
    }
}
