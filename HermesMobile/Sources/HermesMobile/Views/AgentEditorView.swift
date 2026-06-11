import SwiftUI

struct AgentEditorView: View {
    @EnvironmentObject private var org: OrgStore
    @Environment(\.dismiss) private var dismiss

    private let editingID: String?

    @State private var name: String
    @State private var title: String
    @State private var summary: String
    @State private var tier: OrgAgent.Tier
    @State private var parent: String?
    @State private var accentHex: String
    @State private var profileSlug: String
    @State private var pluginsText: String
    @State private var soul: String
    @State private var systemImage: String

    init(agent: OrgAgent? = nil) {
        editingID = agent?.id
        _name = State(initialValue: agent?.name ?? "")
        _title = State(initialValue: agent?.title ?? "")
        _summary = State(initialValue: agent?.summary ?? "")
        _tier = State(initialValue: agent?.tier ?? .sub)
        _parent = State(initialValue: agent?.parent)
        _accentHex = State(initialValue: agent?.accentHex ?? AgentPalette.colors[0])
        _profileSlug = State(initialValue: agent?.profileSlug ?? "default")
        _pluginsText = State(initialValue: (agent?.plugins ?? []).joined(separator: ", "))
        _soul = State(initialValue: agent?.soul ?? "")
        _systemImage = State(initialValue: agent?.systemImage ?? "person.fill")
    }

    private var isEditing: Bool { editingID != nil }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Who this agent can report to, based on its rank.
    private var reportTargets: [OrgAgent] {
        tier == .manager ? org.agents.filter { $0.tier == .ceo } : org.leadership
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name (e.g. Sales Manager Agent)", text: $name)
                        .autocorrectionDisabled()
                    TextField("Department / role label (e.g. Sales)", text: $title)
                }

                Section("Rank & reporting") {
                    Picker("Rank", selection: $tier) {
                        ForEach(OrgAgent.Tier.allCases) { t in Text(t.label).tag(t) }
                    }
                    if tier != .ceo {
                        Picker("Reports to", selection: $parent) {
                            Text("— none —").tag(String?.none)
                            ForEach(reportTargets) { a in Text(a.name).tag(Optional(a.id)) }
                        }
                    }
                }

                Section("Accent color") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(AgentPalette.colors, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 34, height: 34)
                                    .overlay(Circle().stroke(.primary, lineWidth: accentHex == hex ? 3 : 0))
                                    .onTapGesture { accentHex = hex }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    TextField("Hermes profile", text: $profileSlug)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Brain")
                } footer: {
                    Text("Which Hermes profile this agent talks to (`hermes -p <profile>`).")
                }

                Section("Summary") {
                    TextField("What this agent does…", text: $summary, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    TextField("Plugins, comma-separated", text: $pluginsText, axis: .vertical)
                        .lineLimit(1...3)
                        .autocorrectionDisabled()
                } header: {
                    Text("Plugins & skills")
                } footer: {
                    Text("e.g. QuickBooks, web search, Canva")
                }

                Section {
                    // Recommended persona for this agent, one tap away.
                    if let editingID, let match = SoulLibrary.preset(for: editingID) {
                        Button {
                            soul = match.text
                        } label: {
                            Label("Use recommended: \(match.name)", systemImage: "sparkles")
                        }
                    }
                    Menu {
                        ForEach(SoulLibrary.presets) { preset in
                            Button(preset.name) { soul = preset.text }
                        }
                    } label: {
                        Label("Load from Soul Library (\(SoulLibrary.presets.count))", systemImage: "books.vertical.fill")
                    }
                    TextEditor(text: $soul)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                } header: {
                    Text("soul.md")
                } footer: {
                    Text("The agent's persona — sent with its first message. Pick a preset from The Agency library (MIT) and edit it, or write your own.")
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) { deleteAgent() } label: {
                            Label("Delete agent", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Agent" : "New Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        let id = editingID ?? org.newID(base: name)
        let plugins = pluginsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedProfile = profileSlug.trimmingCharacters(in: .whitespaces)

        let agent = OrgAgent(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            title: trimmedTitle.isEmpty ? "Team" : trimmedTitle,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            tier: tier,
            parent: tier == .ceo ? nil : (parent ?? org.ceo?.id),
            accentHex: accentHex,
            profileSlug: trimmedProfile.isEmpty ? "default" : trimmedProfile,
            systemImage: systemImage,
            plugins: plugins,
            coordinates: editingID.flatMap { org.agent(id: $0)?.coordinates } ?? [],
            soul: soul
        )
        org.upsert(agent)
        dismiss()
    }

    private func deleteAgent() {
        if let editingID, let existing = org.agent(id: editingID) { org.delete(existing) }
        dismiss()
    }
}
