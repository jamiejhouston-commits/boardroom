import UIKit

/// The live state an agent broadcasts on the HQ floor. Drives the color and
/// pulse of the holographic status ring above each agent.
enum HQAgentStatus: Equatable {
    case active          // executing real work right now
    case thinking        // reasoning / mid-turn
    case collaborating   // in a boardroom debate / meeting
    case blocked         // stalled, needs unblocking
    case waitingForUser  // a decision gate is open — the owner's call
    case urgent          // something needs attention now
    case idle            // present, breathing, nothing assigned

    /// Ring tint — keyed to the Hermes palette (emerald/gold/steel/silver),
    /// restrained, never neon.
    var tint: UIColor {
        switch self {
        case .active:         return UIColor(red: 0.11, green: 0.48, blue: 0.33, alpha: 1)  // emerald
        case .thinking:       return UIColor(red: 0.78, green: 0.64, blue: 0.35, alpha: 1)  // gold
        case .collaborating:  return UIColor(red: 0.24, green: 0.44, blue: 0.63, alpha: 1)  // steel
        case .blocked:        return UIColor(red: 0.82, green: 0.46, blue: 0.20, alpha: 1)  // amber
        case .waitingForUser: return UIColor(red: 0.85, green: 0.70, blue: 0.36, alpha: 1)  // bright gold
        case .urgent:         return UIColor(red: 0.80, green: 0.26, blue: 0.24, alpha: 1)  // deep red
        case .idle:           return UIColor(red: 0.68, green: 0.72, blue: 0.78, alpha: 1)  // silver
        }
    }

    /// Half-cycle pulse duration (seconds). Urgent/waiting pulse faster.
    var pulse: Double {
        switch self {
        case .urgent, .waitingForUser: return 0.5
        case .active, .collaborating:  return 0.9
        case .thinking, .blocked:      return 1.3
        case .idle:                    return 2.2
        }
    }

    var glyph: String {
        switch self {
        case .active:         return "🟢"
        case .thinking:       return "🟡"
        case .collaborating:  return "🔵"
        case .blocked:        return "🟠"
        case .waitingForUser: return "✨"
        case .urgent:         return "🔴"
        case .idle:           return "⚪️"
        }
    }

    var label: String {
        switch self {
        case .active:         return "Executing"
        case .thinking:       return "Thinking"
        case .collaborating:  return "Collaborating"
        case .blocked:        return "Blocked"
        case .waitingForUser: return "Waiting for you"
        case .urgent:         return "Urgent"
        case .idle:           return "Standing by"
        }
    }
}

/// Derives an agent's live status from the company engine's state.
/// Pure function — unit-tested. Intentionally simple for Slice 1; the mapping
/// widens as later slices add per-agent work tracking.
enum AgentStatusResolver {
    static func status(for agent: OrgAgent, in state: CompanyState) -> HQAgentStatus {
        let inits = state.initiatives
        let role = agent.companyRole

        // 1) The CEO answers to the owner at any open decision gate.
        if agent.tier == .ceo, inits.contains(where: { $0.isAwaitingDecision }) {
            return .waitingForUser
        }
        // 2) A blocked initiative parks its lead builder.
        if inits.contains(where: { $0.stage == "blocked" }), role == "cto" {
            return .blocked
        }
        // 3) Active build → the CEO and the technical lead are executing.
        if inits.contains(where: { $0.stage == "execution" }), agent.tier == .ceo || role == "cto" {
            return .active
        }
        // 3b) Active research → the research lead is executing.
        if inits.contains(where: { $0.stage == "research" }), role == "research" {
            return .active
        }
        // 4) A boardroom debate pulls finance + marketing into collaboration.
        if inits.contains(where: { $0.stage == "boardroom" }), role == "cfo" || role == "marketing" {
            return .collaborating
        }
        return .idle
    }
}
