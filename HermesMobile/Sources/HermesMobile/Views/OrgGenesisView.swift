import SwiftUI

/// Org Genesis — Hermes interviews you and builds a custom company around
/// YOUR business: agents, titles, reporting lines, and souls, hired live.
struct OrgGenesisView: View {
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @EnvironmentObject private var company: CompanyStore
    @Environment(\.dismiss) private var dismiss

    enum Stage { case interview, generating, preview, failed(String) }

    @State private var stage: Stage = .interview
    @State private var business = ""
    @State private var timeSinks = ""
    @State private var goal = ""
    @State private var size = 1   // 0 = lean, 1 = full
    @State private var candidates: [OrgAgent] = []
    @State private var revealed = 0

    // Genesis 2.0 — set up the whole company, not just the org chart.
    @State private var thesisDraft = ""
    @State private var starters: [String] = []
    @State private var starterOn: [Bool] = []
    @State private var startNow = true
    @State private var hiring = false

    var body: some View {
        NavigationStack {
            ZStack {
                HermesTheme.background.ignoresSafeArea()
                switch stage {
                case .interview: interview
                case .generating: generating
                case .preview: preview
                case .failed(let why): failedView(why)
                }
            }
            .navigationTitle("Org Genesis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .interactiveDismissDisabled(isGenerating)
    }

    private var isGenerating: Bool { if case .generating = stage { return true }; return false }

    // MARK: Interview

    private var interview: some View {
        Form {
            Section {
                Text("Answer three questions and the General Manager will design and staff a company built for you.")
                    .font(.subheadline)
                    .foregroundStyle(HermesTheme.textSecondary)
            }
            Section("What's your business or project?") {
                TextField("e.g. I run a small bakery and sell cakes online", text: $business, axis: .vertical)
                    .lineLimit(1...3)
            }
            Section("What eats most of your time?") {
                TextField("e.g. social media, invoices, supplier emails", text: $timeSinks, axis: .vertical)
                    .lineLimit(1...3)
            }
            Section("Top goal for the next 12 months?") {
                TextField("e.g. double online orders", text: $goal, axis: .vertical)
                    .lineLimit(1...3)
            }
            Section("Company size") {
                Picker("Size", selection: $size) {
                    Text("Lean (8–12 agents)").tag(0)
                    Text("Full (14–20 agents)").tag(1)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Button {
                    stage = .generating
                    Task { await generate() }
                } label: {
                    Label("Design my company", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .disabled(business.trimmingCharacters(in: .whitespaces).isEmpty)
                .listRowBackground(HermesTheme.emerald.opacity(0.18))
            } footer: {
                Text("Replaces your current org — your existing agents and edits will be lost. You can always reload a preset.")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var generating: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large).tint(HermesTheme.emerald)
            Text("The General Manager is designing your company…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HermesTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    // MARK: Preview — the hiring montage

    private var preview: some View {
        VStack(spacing: 0) {
            List {
                Section("Your new company — \(candidates.count) agents") {
                    ForEach(Array(candidates.prefix(revealed).enumerated()), id: \.element.id) { _, agent in
                        HStack(spacing: 12) {
                            Image(systemName: agent.systemImage)
                                .foregroundStyle(Color(hex: agent.accentHex))
                                .frame(width: 32, height: 32)
                                .background(Color(hex: agent.accentHex).opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name).font(.subheadline.weight(.semibold))
                                Text(agent.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if agent.tier == .ceo {
                                Image(systemName: "crown.fill").foregroundStyle(HermesTheme.gold)
                            }
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                if revealed >= candidates.count {
                    Section("Investment thesis") {
                        TextField("What the company pursues", text: $thesisDraft, axis: .vertical)
                            .lineLimit(1...3)
                        Text("The market scout filters every opportunity through this lens.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    Section("Starter ideas") {
                        ForEach(starters.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: starterOn[index] ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(starterOn[index] ? HermesTheme.emerald : .secondary)
                                    .onTapGesture { starterOn[index].toggle() }
                                TextField("Idea", text: $starters[index], axis: .vertical)
                                    .lineLimit(1...3)
                                    .font(.subheadline)
                            }
                        }
                    }

                    Section {
                        Toggle("Start the company now", isOn: $startNow)
                            .tint(HermesTheme.emerald)
                    } footer: {
                        Text("Hiring builds your org. Starting also puts the team to work — scouting the market and on the starter ideas you kept.")
                    }
                }
            }
            .scrollContentBackground(.hidden)

            VStack(spacing: 10) {
                Button {
                    hire()
                } label: {
                    Label(hiring ? "Setting up…" : "Hire & set up", systemImage: "person.3.fill")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(HermesTheme.emerald)
                .disabled(revealed < candidates.count || hiring)

                Button("Start over") { stage = .interview }
                    .font(.subheadline)
                    .disabled(hiring)
            }
            .padding()
        }
        .onAppear { revealNext() }
    }

    private func revealNext() {
        guard revealed < candidates.count else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { revealed += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { revealNext() }
    }

    private func failedView(_ why: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle).foregroundStyle(.orange)
            Text(why)
                .font(.subheadline).foregroundStyle(HermesTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { stage = .interview }
                .buttonStyle(.borderedProminent).tint(HermesTheme.emerald)
        }
        .padding(28)
    }

    // MARK: Generation

    private func generate() async {
        let relay = runtime.relayConfiguration
        guard relay.isConfigured else {
            stage = .failed("Connect your relay first (Settings → Mac Relay).")
            return
        }
        var config = relay
        config.profile = "orchestrator"

        let count = size == 0 ? "8 to 12" : "14 to 20"
        let payload = """
        You are an expert company designer. Design an AI agent organization tailored to this owner.

        Business: \(business)
        Time sinks: \(timeSinks.isEmpty ? "unspecified" : timeSinks)
        12-month goal: \(goal.isEmpty ? "unspecified" : goal)

        Create \(count) agents. Respond with ONLY a JSON array, no prose, no markdown fences. Each element:
        {"id":"kebab-slug","name":"...","title":"<short department label>","summary":"<one sentence>","tier":"ceo|manager|sub","parent":"<id of manager or null>","soul":"<2-3 sentence persona: personality + how it works>"}

        Rules: EXACTLY one "ceo" tier agent (the orchestrator, parent null). Managers' parent is the ceo's id. Subs' parent is a manager's id. Tailor names/roles to THIS business — be specific, not generic.
        """

        var collected = ""
        do {
            for try await event in HermesRelayClient(configuration: config).stream(payload, sessionKey: "hermes-mobile-genesis") {
                switch event.type {
                case .start: break
                case .delta: collected += event.text ?? ""
                case .done:
                    if collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let reply = event.reply { collected = reply }
                case .error:
                    throw HermesRelayError.server(event.message ?? "Generation failed.")
                }
            }
        } catch {
            stage = .failed(error.localizedDescription)
            return
        }

        let agents = GenesisParser.parse(collected)
        guard agents.count >= 5 else {
            stage = .failed("The design came back malformed — try again.")
            return
        }
        candidates = agents
        revealed = 0
        thesisDraft = composedThesis()
        starters = composedStarters()
        starterOn = starters.map { _ in true }
        stage = .preview
    }

    // MARK: Genesis 2.0 — company setup defaults + hire

    private func composedThesis() -> String {
        let goalText = goal.trimmingCharacters(in: .whitespaces)
        let businessText = business.trimmingCharacters(in: .whitespaces)
        if !goalText.isEmpty, !businessText.isEmpty {
            return "\(businessText). Pursue products and automations that help: \(goalText)."
        }
        if !businessText.isEmpty {
            return "\(businessText). Pursue small, useful products that save time and grow the business."
        }
        return "Small, useful products that ship in days."
    }

    private func composedStarters() -> [String] {
        var out: [String] = []
        let sinks = timeSinks.trimmingCharacters(in: .whitespaces)
        let goalText = goal.trimmingCharacters(in: .whitespaces)
        if !sinks.isEmpty { out.append("Build a tool that takes this off my plate: \(sinks).") }
        if !goalText.isEmpty { out.append("Ship something this month that moves us toward: \(goalText).") }
        out.append("Find a small, high-leverage product we can build and ship in days.")
        return Array(out.prefix(3))
    }

    private func hire() {
        hiring = true
        org.applyPreset(candidates)
        let chosen = zip(starters, starterOn)
            .filter { $0.1 }
            .map { $0.0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let thesis = thesisDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if startNow {
                await company.setEnabled(true, thesis: thesis, relay: runtime.relayConfiguration)
            } else {
                await company.setThesis(thesis, relay: runtime.relayConfiguration)
            }
            for starter in chosen {
                await company.submitDirective(starter, relay: runtime.relayConfiguration)
            }
            dismiss()
        }
    }
}

// MARK: - Parser: model JSON → sanitized OrgAgents

enum GenesisParser {
    private struct RawAgent: Decodable {
        var id: String?
        var name: String?
        var title: String?
        var summary: String?
        var tier: String?
        var parent: String?
        var soul: String?
    }

    private static let palette = ["1C7A55", "23426B", "3C6FA0", "C7A35A", "5A6ACF", "16A1A1", "9B59B6", "2E8B57"]
    private static let icons: [String: String] = [
        "ceo": "crown.fill", "finance": "dollarsign.circle.fill", "market": "megaphone.fill",
        "tech": "chevron.left.forwardslash.chevron.right", "engineer": "chevron.left.forwardslash.chevron.right",
        "develop": "hammer.fill", "design": "paintpalette.fill", "content": "pencil.and.outline",
        "social": "bubble.left.and.bubble.right.fill", "sales": "chart.line.uptrend.xyaxis",
        "support": "headphones", "customer": "hand.thumbsup.fill", "legal": "building.columns.fill",
        "operat": "gearshape.2.fill", "research": "magnifyingglass", "data": "cylinder.split.1x2.fill",
        "product": "lightbulb.max.fill", "hr": "person.3.fill", "people": "person.3.fill",
        "supply": "shippingbox.fill", "inventory": "shippingbox.fill", "order": "cart.fill",
        "invoice": "doc.text.fill", "account": "doc.text.fill", "email": "envelope.fill",
        "schedul": "calendar", "assistant": "calendar.badge.clock", "secretar": "calendar.badge.clock"
    ]

    static func parse(_ raw: String) -> [OrgAgent] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RawAgent].self, from: data)
        else { return [] }

        var seen = Set<String>()
        var agents: [OrgAgent] = []

        for (i, r) in decoded.enumerated() {
            let name = (r.name ?? "Agent \(i + 1)").trimmingCharacters(in: .whitespaces)
            var id = (r.id ?? name).lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            if id.isEmpty { id = "agent-\(i + 1)" }
            while seen.contains(id) { id += "x" }
            seen.insert(id)

            let tier: OrgAgent.Tier
            switch (r.tier ?? "").lowercased() {
            case "ceo": tier = .ceo
            case "manager": tier = .manager
            default: tier = .sub
            }

            let key = (name + " " + (r.title ?? "")).lowercased()
            let icon = icons.first { key.contains($0.key) }?.value ?? "person.fill"

            agents.append(OrgAgent(
                id: id,
                name: name,
                title: r.title ?? "Team",
                summary: r.summary ?? "",
                tier: tier,
                parent: r.parent,
                accentHex: tier == .ceo ? "C7A35A" : palette[i % palette.count],
                profileSlug: tier == .ceo ? "orchestrator" : "default",
                systemImage: tier == .ceo ? "crown.fill" : icon,
                soul: r.soul ?? ""
            ))
        }

        // Exactly one CEO: first stays, extras demote to manager.
        var sawCEO = false
        for i in agents.indices where agents[i].tier == .ceo {
            if sawCEO { agents[i].tier = .manager } else { sawCEO = true }
        }
        if !sawCEO, !agents.isEmpty { agents[0].tier = .ceo; agents[0].parent = nil }
        let ceoID = agents.first { $0.tier == .ceo }?.id

        // Valid reporting lines.
        let ids = Set(agents.map(\.id))
        for i in agents.indices {
            if agents[i].tier == .ceo {
                agents[i].parent = nil
            } else if agents[i].parent == nil || !ids.contains(agents[i].parent ?? "") {
                agents[i].parent = ceoID
            }
        }
        return agents
    }
}
