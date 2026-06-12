import Foundation

/// One agent in the Hermes Agent Organization.
struct OrgAgent: Identifiable, Hashable, Codable {
    enum Tier: String, Codable, CaseIterable, Identifiable {
        case ceo, manager, sub
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ceo: "Executive (top)"
            case .manager: "Department head"
            case .sub: "Team member"
            }
        }
    }

    var id: String
    var name: String
    var title: String
    var summary: String
    var tier: Tier
    var parent: String?
    var accentHex: String
    /// Hermes profile this agent routes to (`hermes -p <slug>`).
    var profileSlug: String
    var systemImage: String = "person.fill"
    var plugins: [String] = []
    /// Hermes skills this agent loads (passed to `hermes chat -s ...`).
    var skills: [String] = []
    var coordinates: [String] = []
    /// The agent's editable soul.md (persona / instructions).
    var soul: String = ""
}

extension OrgAgent {
    /// The company-engine role this agent fills, if any. The autonomous
    /// company runs these roles under `company-<role>` sessions on the relay.
    var companyRole: String? {
        if tier == .ceo { return "ceo" }
        let s = "\(title) \(name) \(summary)".lowercased()
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }
        if has(["cfo", "financ", "account", "budget", "treasur"]) { return "cfo" }
        if has(["cto", "engineer", "develop", "technical", "software", "build"]) { return "cto" }
        if has(["market", "growth", "brand", "content", "seo", "social"]) { return "marketing" }
        if has(["research", "analyst", "intelligence", "insight", "data"]) { return "research" }
        return nil
    }

    /// (profile, session) for talking to this agent. Agents with a company
    /// role share the EXACT session the autonomous company uses for that role
    /// — so the CEO you chat with is the same brain that runs your company,
    /// not a disconnected second one. ("main" normalizes to the default
    /// profile on the relay, matching the company engine.)
    var chatRouting: (profile: String, session: String) {
        if let role = companyRole {
            return ("main", "company-\(role)")
        }
        return (profileSlug, "hermes-mobile-org-\(id)")
    }
}

/// The whole company: CEO → 8 department heads → their sub-agents.
enum HermesOrg {

    static var ceo: OrgAgent { all.first { $0.tier == .ceo }! }
    static var managers: [OrgAgent] { all.filter { $0.tier == .manager } }
    static var leadership: [OrgAgent] { all.filter { $0.tier != .sub } } // CEO + managers
    static func children(of id: String) -> [OrgAgent] { all.filter { $0.parent == id } }
    static func agent(id: String) -> OrgAgent? { all.first { $0.id == id } }

    // Department accent colors
    private static let gold = "D4AF37"
    private static let strat = "2E8B57"
    private static let fin = "27AE60"
    private static let ops = "16A1A1"
    private static let mkt = "E0533D"
    private static let legalC = "5A6ACF"
    private static let res = "3B82C4"
    private static let arC = "9B59B6"
    private static let eng = "12B5A5"

    /// Default org. Swap presets via OrgStore.applyPreset(_:).
    static var all: [OrgAgent] { corporate }

    struct Preset: Identifiable {
        let id: String
        let name: String
        let subtitle: String
        let agents: [OrgAgent]
    }

    static let presets: [Preset] = [
        Preset(id: "corporate", name: "Corporate", subtitle: "GM-orchestrated · governance + delivery (default)", agents: corporate),
        Preset(id: "classic", name: "Classic — Full Org", subtitle: "The original 40-agent company", agents: classicAll)
    ]

    // ───────── Corporate (default): GM → governance + Agent Command Center ─────────
    static let corporate: [OrgAgent] = [
        OrgAgent(id: "gm", name: "General Manager", title: "Orchestrator",
                 summary: "Coordinates every agent, routes work, sets priorities — reports to you, the owner.",
                 tier: .ceo, parent: nil, accentHex: gold, profileSlug: "orchestrator", systemImage: "crown.fill"),

        // The GM's right hand.
        OrgAgent(id: "executive_assistant", name: "Executive Secretary", title: "Executive Office",
                 summary: "The GM's gatekeeper — calendar, meeting prep, briefs, follow-ups, and keeping the boss focused.",
                 tier: .sub, parent: "gm", accentHex: gold, profileSlug: "default",
                 systemImage: "calendar.badge.clock", plugins: ["Calendar", "Notes"]),

        // Governance + C-suite
        OrgAgent(id: "cfo", name: "CFO Agent", title: "Finance",
                 summary: "Budgeting, forecasting, profitability, cash-flow, financial reporting.",
                 tier: .manager, parent: "gm", accentHex: fin, profileSlug: "default",
                 systemImage: "dollarsign.circle.fill", plugins: ["QuickBooks", "Spreadsheets"]),
        OrgAgent(id: "cto", name: "CTO Agent", title: "Technology",
                 summary: "Code quality, architecture, security, infrastructure, technical decisions.",
                 tier: .manager, parent: "gm", accentHex: eng, profileSlug: "default",
                 systemImage: "chevron.left.forwardslash.chevron.right", plugins: ["GitHub", "CI/CD"]),
        OrgAgent(id: "cpo", name: "CPO Agent", title: "Product",
                 summary: "Feature prioritization, customer feedback, roadmap, product vision.",
                 tier: .manager, parent: "gm", accentHex: legalC, profileSlug: "default",
                 systemImage: "lightbulb.max.fill"),
        OrgAgent(id: "operations", name: "Operations Agent", title: "Execution",
                 summary: "Execution systems, workflow design, process management, delivery tracking.",
                 tier: .manager, parent: "gm", accentHex: ops, profileSlug: "default",
                 systemImage: "gearshape.2.fill"),
        OrgAgent(id: "ar", name: "Agent Resources (AR)", title: "Resources",
                 summary: "Recruitment, onboarding, training, skills, performance, capacity.",
                 tier: .manager, parent: "gm", accentHex: arC, profileSlug: "default",
                 systemImage: "person.3.fill"),
        OrgAgent(id: "legal", name: "Legal Agent", title: "Compliance",
                 summary: "Contracts, compliance, risk, policy, IP, legal checks.",
                 tier: .manager, parent: "gm", accentHex: mkt, profileSlug: "default",
                 systemImage: "building.columns.fill"),
        OrgAgent(id: "strategy", name: "Strategy Agent", title: "Planning",
                 summary: "Long-term planning, business models, opportunity mapping, competitive positioning.",
                 tier: .manager, parent: "gm", accentHex: strat, profileSlug: "default",
                 systemImage: "target"),
        OrgAgent(id: "command_center", name: "Agent Command Center", title: "Delivery",
                 summary: "The delivery hub — coordinates the doer pods: build, research, marketing, data, support, QA.",
                 tier: .manager, parent: "gm", accentHex: res, profileSlug: "default",
                 systemImage: "rectangle.3.group.fill"),

        // Finance team
        OrgAgent(id: "accounting", name: "Accounting Agent", title: "Finance",
                 summary: "Bookkeeping and ledgers — connected to QuickBooks.",
                 tier: .sub, parent: "cfo", accentHex: fin, profileSlug: "default",
                 systemImage: "doc.text.fill", plugins: ["QuickBooks"]),
        OrgAgent(id: "investor_relations", name: "Investor Relations Agent", title: "Finance",
                 summary: "Pitch decks, business plans, fundraising, investor updates.",
                 tier: .sub, parent: "cfo", accentHex: fin, profileSlug: "default",
                 systemImage: "briefcase.fill"),

        // Technology team
        OrgAgent(id: "security", name: "Security Agent", title: "Technology",
                 summary: "API keys, credentials, vulnerabilities, penetration testing, monitoring.",
                 tier: .sub, parent: "cto", accentHex: eng, profileSlug: "default",
                 systemImage: "lock.shield.fill"),
        OrgAgent(id: "devops", name: "DevOps Agent", title: "Technology",
                 summary: "CI/CD, deployment, infrastructure, monitoring, environments.",
                 tier: .sub, parent: "cto", accentHex: eng, profileSlug: "default",
                 systemImage: "infinity"),

        // Product team
        OrgAgent(id: "customer_success", name: "Customer Success Agent", title: "Product",
                 summary: "Customer onboarding, retention, reviews, support tickets.",
                 tier: .sub, parent: "cpo", accentHex: legalC, profileSlug: "default",
                 systemImage: "hand.thumbsup.fill"),

        // Operations team
        OrgAgent(id: "task_coordinator", name: "Task Coordinator Agent", title: "Execution",
                 summary: "Coordinates and tracks tasks across the company.",
                 tier: .sub, parent: "operations", accentHex: ops, profileSlug: "default",
                 systemImage: "checklist"),
        OrgAgent(id: "workflow_automation", name: "Workflow Automation Agent", title: "Execution",
                 summary: "Designs and automates repeatable workflows.",
                 tier: .sub, parent: "operations", accentHex: ops, profileSlug: "default",
                 systemImage: "arrow.triangle.branch"),

        // Resources team
        OrgAgent(id: "recruitment", name: "Recruitment Agent", title: "Resources",
                 summary: "Creates new agents, selects their skills, and onboards them.",
                 tier: .sub, parent: "ar", accentHex: arC, profileSlug: "default",
                 systemImage: "person.badge.plus"),
        OrgAgent(id: "knowledge_officer", name: "Knowledge Officer", title: "Resources",
                 summary: "Manages soul.md, documentation, company memory, and lessons learned.",
                 tier: .sub, parent: "ar", accentHex: arC, profileSlug: "default",
                 systemImage: "books.vertical.fill"),

        // Legal team
        OrgAgent(id: "compliance", name: "Compliance Agent", title: "Compliance",
                 summary: "Regulatory and policy compliance checks.",
                 tier: .sub, parent: "legal", accentHex: mkt, profileSlug: "default",
                 systemImage: "checkmark.shield.fill"),

        // Strategy team
        OrgAgent(id: "business_analyst", name: "Business Analyst Agent", title: "Planning",
                 summary: "Analyzes the business, models scenarios, surfaces opportunities.",
                 tier: .sub, parent: "strategy", accentHex: strat, profileSlug: "default",
                 systemImage: "chart.bar.fill"),

        // Agent Command Center — the delivery pods
        OrgAgent(id: "builder", name: "Builder Agent", title: "Delivery",
                 summary: "Scaffolds and assembles — builds and integrates the product.",
                 tier: .sub, parent: "command_center", accentHex: res, profileSlug: "default",
                 systemImage: "cube.fill"),
        OrgAgent(id: "research", name: "Research Agent", title: "Delivery",
                 summary: "Deep research, fact verification, market & technical intelligence.",
                 tier: .sub, parent: "command_center", accentHex: res, profileSlug: "default",
                 systemImage: "magnifyingglass", coordinates: ["cto", "cpo", "strategy"]),
        OrgAgent(id: "marketing", name: "Marketing Agent", title: "Delivery",
                 summary: "Brand, campaigns, social, content, SEO, ads, growth.",
                 tier: .sub, parent: "command_center", accentHex: res, profileSlug: "default",
                 systemImage: "megaphone.fill", plugins: ["Social", "SEO", "Google Ads", "Meta Ads", "Canva"]),
        OrgAgent(id: "data", name: "Data Agent", title: "Delivery",
                 summary: "Databases, pipelines, analytics, and data intelligence.",
                 tier: .sub, parent: "command_center", accentHex: res, profileSlug: "default",
                 systemImage: "cylinder.split.1x2.fill"),
        OrgAgent(id: "concierge", name: "Concierge Agent", title: "Delivery",
                 summary: "The front door — triages requests and gets things done for you.",
                 tier: .sub, parent: "command_center", accentHex: res, profileSlug: "default",
                 systemImage: "bell.fill"),
        OrgAgent(id: "qa", name: "QA Agent", title: "Delivery",
                 summary: "Tests, finds bugs, and verifies quality across the work.",
                 tier: .sub, parent: "command_center", accentHex: res, profileSlug: "default",
                 systemImage: "checkmark.circle.fill")
    ]

    // ───────── Classic (preset): the original 40-agent org ─────────
    static let classicAll: [OrgAgent] = [
        // ───────── CEO ─────────
        OrgAgent(id: "ceo", name: "CEO / GM Agent", title: "Chief Executive",
                 summary: "Vision, priorities, decision-making, coordination across all agents, final approvals, accountability, and resource allocation.",
                 tier: .ceo, parent: nil, accentHex: gold, profileSlug: "orchestrator",
                 systemImage: "crown.fill"),
        OrgAgent(id: "executive_assistant", name: "Executive Secretary", title: "Chief Executive",
                 summary: "The CEO's gatekeeper — calendar, meeting prep, briefs, follow-ups, and keeping the boss focused.",
                 tier: .sub, parent: "ceo", accentHex: gold, profileSlug: "default",
                 systemImage: "calendar.badge.clock", plugins: ["Calendar", "Notes"]),

        // ───────── Department heads ─────────
        OrgAgent(id: "strategist", name: "Strategist Agent", title: "Strategy",
                 summary: "Long-term planning, business models, opportunity mapping, partnerships, roadmaps, competitive positioning.",
                 tier: .manager, parent: "ceo", accentHex: strat, profileSlug: "default",
                 systemImage: "lightbulb.max.fill", plugins: ["Market data", "Roadmapping"]),
        OrgAgent(id: "cfo", name: "CFO Agent", title: "Finance",
                 summary: "Budgeting, forecasting, accounting oversight, pricing, profitability, cash-flow, financial reporting.",
                 tier: .manager, parent: "ceo", accentHex: fin, profileSlug: "default",
                 systemImage: "dollarsign.circle.fill", plugins: ["QuickBooks", "Spreadsheets"]),
        OrgAgent(id: "coo", name: "COO / Operations Agent", title: "Operations",
                 summary: "Execution systems, workflow design, process management, delivery tracking, operational efficiency.",
                 tier: .manager, parent: "ceo", accentHex: ops, profileSlug: "default",
                 systemImage: "gearshape.2.fill", plugins: ["Task tracker", "Automation"]),
        OrgAgent(id: "marketing", name: "Marketing Manager Agent", title: "Marketing",
                 summary: "Brand, campaigns, social media, content planning, growth funnels, audience analytics.",
                 tier: .manager, parent: "ceo", accentHex: mkt, profileSlug: "default",
                 systemImage: "megaphone.fill",
                 plugins: ["Social (X/IG/LinkedIn/FB)", "Email", "Google Ads", "Meta Ads", "SEO", "Analytics", "Canva"]),
        OrgAgent(id: "legal", name: "Lawyer / Legal Agent", title: "Legal",
                 summary: "Contracts, compliance, risk review, policy review, intellectual property, legal checks.",
                 tier: .manager, parent: "ceo", accentHex: legalC, profileSlug: "default",
                 systemImage: "building.columns.fill", plugins: ["Contract review", "Compliance DB"]),
        OrgAgent(id: "researcher", name: "Researcher Agent", title: "Research",
                 summary: "Deep research, fact verification, market intelligence, technical research, source validation, briefing notes.",
                 tier: .manager, parent: "ceo", accentHex: res, profileSlug: "default",
                 systemImage: "magnifyingglass",
                 plugins: ["Web search", "Browser", "Data intelligence"],
                 coordinates: ["cto", "marketing", "legal", "coo"]),
        OrgAgent(id: "ar", name: "Agent Resources (AR) Agent", title: "Agent Resources",
                 summary: "Recruitment, onboarding, training, skills matrix, performance appraisals, capability development, workload balance.",
                 tier: .manager, parent: "ceo", accentHex: arC, profileSlug: "default",
                 systemImage: "person.3.fill", plugins: ["Skills matrix", "Appraisals"]),
        OrgAgent(id: "cto", name: "CTO / Product & Engineering Agent", title: "Product & Engineering",
                 summary: "Technical architecture, product planning, coding standards, integrations, QA and deployment oversight.",
                 tier: .manager, parent: "ceo", accentHex: eng, profileSlug: "default",
                 systemImage: "chevron.left.forwardslash.chevron.right", plugins: ["GitHub", "CI/CD"]),

        // ───────── Strategy ─────────
        OrgAgent(id: "business_analyst", name: "Business Analyst Agent", title: "Strategy",
                 summary: "Analyzes the business, models scenarios, and surfaces opportunities.",
                 tier: .sub, parent: "strategist", accentHex: strat, profileSlug: "default",
                 systemImage: "chart.line.uptrend.xyaxis"),
        OrgAgent(id: "partnerships", name: "Partnerships Agent", title: "Strategy",
                 summary: "Finds, evaluates, and manages strategic partnerships.",
                 tier: .sub, parent: "strategist", accentHex: strat, profileSlug: "default",
                 systemImage: "hands.sparkles.fill"),
        OrgAgent(id: "project_planner", name: "Project Planner Agent", title: "Strategy",
                 summary: "Turns strategy into roadmaps, milestones, and plans.",
                 tier: .sub, parent: "strategist", accentHex: strat, profileSlug: "default",
                 systemImage: "calendar"),

        // ───────── Finance ─────────
        OrgAgent(id: "accounting", name: "Accounting Agent", title: "Finance",
                 summary: "Bookkeeping, ledgers, and accounting — connected to QuickBooks.",
                 tier: .sub, parent: "cfo", accentHex: fin, profileSlug: "default",
                 systemImage: "doc.text.fill", plugins: ["QuickBooks"]),
        OrgAgent(id: "payroll", name: "Payroll Agent", title: "Finance",
                 summary: "Runs payroll and tracks compensation.",
                 tier: .sub, parent: "cfo", accentHex: fin, profileSlug: "default",
                 systemImage: "banknote.fill"),
        OrgAgent(id: "procurement", name: "Procurement Agent", title: "Finance",
                 summary: "Purchasing, vendors, and procurement.",
                 tier: .sub, parent: "cfo", accentHex: fin, profileSlug: "default",
                 systemImage: "cart.fill"),
        OrgAgent(id: "reporting", name: "Reporting Agent", title: "Finance",
                 summary: "Financial reports, dashboards, and statements.",
                 tier: .sub, parent: "cfo", accentHex: fin, profileSlug: "default",
                 systemImage: "chart.pie.fill"),

        // ───────── Operations ─────────
        OrgAgent(id: "task_coordinator", name: "Task Coordinator Agent", title: "Operations",
                 summary: "Coordinates and tracks tasks across the company.",
                 tier: .sub, parent: "coo", accentHex: ops, profileSlug: "default",
                 systemImage: "checklist"),
        OrgAgent(id: "workflow_automation", name: "Workflow Automation Agent", title: "Operations",
                 summary: "Designs and automates repeatable workflows.",
                 tier: .sub, parent: "coo", accentHex: ops, profileSlug: "default",
                 systemImage: "arrow.triangle.branch"),
        OrgAgent(id: "quality_control", name: "Quality Control Agent", title: "Operations",
                 summary: "Checks output quality and consistency.",
                 tier: .sub, parent: "coo", accentHex: ops, profileSlug: "default",
                 systemImage: "checkmark.seal.fill"),

        // ───────── Marketing ─────────
        OrgAgent(id: "content_creator", name: "Content Creator Agent", title: "Marketing",
                 summary: "Writes copy, posts, and campaign content.",
                 tier: .sub, parent: "marketing", accentHex: mkt, profileSlug: "default",
                 systemImage: "pencil.and.outline", plugins: ["Content", "Copywriting"]),
        OrgAgent(id: "design", name: "Design Agent", title: "Marketing",
                 summary: "Visual assets, graphics, and brand design.",
                 tier: .sub, parent: "marketing", accentHex: mkt, profileSlug: "default",
                 systemImage: "paintpalette.fill", plugins: ["Canva", "Image generation"]),
        OrgAgent(id: "seo", name: "SEO Agent", title: "Marketing",
                 summary: "Keyword research, on-page SEO, and search visibility.",
                 tier: .sub, parent: "marketing", accentHex: mkt, profileSlug: "default",
                 systemImage: "magnifyingglass.circle.fill", plugins: ["SEO tools", "Search Console"]),
        OrgAgent(id: "ads_growth", name: "Ads / Growth Agent", title: "Marketing",
                 summary: "Paid acquisition, growth experiments, and funnels.",
                 tier: .sub, parent: "marketing", accentHex: mkt, profileSlug: "default",
                 systemImage: "chart.line.uptrend.xyaxis", plugins: ["Google Ads", "Meta Ads"]),
        OrgAgent(id: "community_manager", name: "Community Manager Agent", title: "Marketing",
                 summary: "Social engagement, community, and scheduling.",
                 tier: .sub, parent: "marketing", accentHex: mkt, profileSlug: "default",
                 systemImage: "bubble.left.and.bubble.right.fill", plugins: ["Social scheduler"]),

        // ───────── Legal ─────────
        OrgAgent(id: "compliance", name: "Compliance Agent", title: "Legal",
                 summary: "Regulatory and policy compliance checks.",
                 tier: .sub, parent: "legal", accentHex: legalC, profileSlug: "default",
                 systemImage: "checkmark.shield.fill"),
        OrgAgent(id: "contract_review", name: "Contract Review Agent", title: "Legal",
                 summary: "Reviews and redlines contracts.",
                 tier: .sub, parent: "legal", accentHex: legalC, profileSlug: "default",
                 systemImage: "doc.text.magnifyingglass"),
        OrgAgent(id: "policy", name: "Policy Agent", title: "Legal",
                 summary: "Drafts and reviews internal and external policy.",
                 tier: .sub, parent: "legal", accentHex: legalC, profileSlug: "default",
                 systemImage: "book.closed.fill"),

        // ───────── Research ─────────
        OrgAgent(id: "market_research", name: "Market Research Agent", title: "Research",
                 summary: "Market intelligence and competitive analysis.",
                 tier: .sub, parent: "researcher", accentHex: res, profileSlug: "default",
                 systemImage: "chart.bar.doc.horizontal.fill"),
        OrgAgent(id: "technical_research", name: "Technical Research Agent", title: "Research",
                 summary: "Deep technical research and feasibility.",
                 tier: .sub, parent: "researcher", accentHex: res, profileSlug: "default",
                 systemImage: "wrench.and.screwdriver.fill"),
        OrgAgent(id: "data_intelligence", name: "Data Intelligence Agent", title: "Research",
                 summary: "Gathers, validates, and structures data.",
                 tier: .sub, parent: "researcher", accentHex: res, profileSlug: "default",
                 systemImage: "cylinder.split.1x2.fill"),

        // ───────── Agent Resources ─────────
        OrgAgent(id: "training", name: "Training Agent", title: "Agent Resources",
                 summary: "Onboards and trains agents.",
                 tier: .sub, parent: "ar", accentHex: arC, profileSlug: "default",
                 systemImage: "graduationcap.fill"),
        OrgAgent(id: "skills_auditor", name: "Skills Auditor Agent", title: "Agent Resources",
                 summary: "Maintains the skills matrix and capability gaps.",
                 tier: .sub, parent: "ar", accentHex: arC, profileSlug: "default",
                 systemImage: "list.bullet.clipboard.fill"),
        OrgAgent(id: "performance_review", name: "Performance Review Agent", title: "Agent Resources",
                 summary: "Runs appraisals and performance reviews.",
                 tier: .sub, parent: "ar", accentHex: arC, profileSlug: "default",
                 systemImage: "star.fill"),
        OrgAgent(id: "capacity_planning", name: "Capacity Planning Agent", title: "Agent Resources",
                 summary: "Balances workload and plans capacity.",
                 tier: .sub, parent: "ar", accentHex: arC, profileSlug: "default",
                 systemImage: "gauge.with.dots.needle.bottom.50percent"),

        // ───────── Product & Engineering ─────────
        OrgAgent(id: "builder", name: "Builder Agent", title: "Product & Engineering",
                 summary: "Scaffolds & assembles — new projects, wiring components, MVP skeletons, and integrating the team's work into a running product.",
                 tier: .sub, parent: "cto", accentHex: eng, profileSlug: "default",
                 systemImage: "cube.fill"),
        OrgAgent(id: "frontend_dev", name: "Frontend Developer Agent", title: "Product & Engineering",
                 summary: "Builds the UI / client — screens, components, styling, and client-side logic.",
                 tier: .sub, parent: "cto", accentHex: eng, profileSlug: "default",
                 systemImage: "macwindow"),
        OrgAgent(id: "backend_dev", name: "Backend Developer Agent", title: "Product & Engineering",
                 summary: "Builds the server / API — endpoints, business logic, auth, and server-side integrations.",
                 tier: .sub, parent: "cto", accentHex: eng, profileSlug: "default",
                 systemImage: "server.rack"),
        OrgAgent(id: "data_engineer", name: "Data Engineer Agent", title: "Product & Engineering",
                 summary: "Databases, schemas, data pipelines, and storage.",
                 tier: .sub, parent: "cto", accentHex: eng, profileSlug: "default",
                 systemImage: "cylinder.fill"),
        OrgAgent(id: "qa", name: "Testing / QA Agent", title: "Product & Engineering",
                 summary: "Writes and runs tests, finds bugs, verifies quality.",
                 tier: .sub, parent: "cto", accentHex: eng, profileSlug: "default",
                 systemImage: "checkmark.circle.fill"),
        OrgAgent(id: "devops", name: "DevOps Agent", title: "Product & Engineering",
                 summary: "CI/CD, deployment, infrastructure, monitoring, environments.",
                 tier: .sub, parent: "cto", accentHex: eng, profileSlug: "default",
                 systemImage: "infinity")
    ]
}
