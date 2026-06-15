import Foundation

/// The shared knowledge every agent gets, on every screen, every turn — so
/// they're all coordinated instead of being amnesiac separate brains.
/// Built from the org chart, the memos you've sent, the meetings you've
/// scheduled, and the live company initiatives, then injected into each
/// agent's prompt. This is what lets the GM actually KNOW about your memo
/// and meeting, and what makes the chain of command real.
@MainActor
enum CompanyContext {
    static func brief(org: OrgStore, hub: MeetingHub, company: CompanyStore) -> String {
        var lines: [String] = [
            "=== COMPANY CONTEXT (shared knowledge — every agent has this right now; honor the chain of command) ==="
        ]

        if let ceo = org.ceo {
            lines.append("Chain of command:")
            lines.append("• \(ceo.name) — CEO/GM (top authority).")
            for mgr in org.managers {
                let team = org.children(of: mgr.id).map(\.name).prefix(6)
                let teamStr = team.isEmpty ? "" : " — team: \(team.joined(separator: ", "))"
                lines.append("• \(mgr.name) (\(mgr.title)) reports to \(ceo.name)\(teamStr)")
            }
        }

        let memos = hub.memos.prefix(5)
        if !memos.isEmpty {
            lines.append("Memos the owner sent (you are expected to know these):")
            for memo in memos {
                let to = memo.recipientIDs.compactMap { org.agent(id: $0)?.name }.prefix(4).joined(separator: ", ")
                lines.append("• \"\(memo.subject)\" → \(to.isEmpty ? "team" : to): \(memo.body.prefix(160))")
            }
        }

        let meetings = hub.upcoming.prefix(5)
        if !meetings.isEmpty {
            lines.append("Scheduled meetings (attend / be ready):")
            for meeting in meetings {
                let who = meeting.attendeeIDs.compactMap { org.agent(id: $0)?.name }.prefix(6).joined(separator: ", ")
                lines.append("• \"\(meeting.topic)\" at \(meeting.date.formatted(date: .abbreviated, time: .shortened)) with \(who)")
            }
        }

        let active = company.state.initiatives.filter { !$0.isTerminal }.prefix(5)
        if !active.isEmpty {
            lines.append("Active company initiatives:")
            for initiative in active {
                lines.append("• \(initiative.title) — \(initiative.stageLabel)")
            }
        }

        lines.append("=== END CONTEXT ===")
        return lines.joined(separator: "\n")
    }
}
