import SwiftUI

struct OrgView: View {
    @EnvironmentObject private var org: OrgStore
    @State private var showingNew = false
    @State private var showingGenesis = false
    @State private var pendingPreset: HermesOrg.Preset?

    var body: some View {
        NavigationStack {
            List {
                if let ceo = org.ceo {
                    Section {
                        NavigationLink {
                            OrgAgentDetailView(agent: ceo)
                        } label: {
                            OrgAgentRow(agent: ceo, isLead: true)
                        }
                    } header: {
                        Text("Leadership")
                    } footer: {
                        Text("Your organization — \(org.agents.count) agents. Tap to open · swipe to delete · ＋ to add.")
                    }
                }

                ForEach(org.managers) { manager in
                    Section(manager.title) {
                        NavigationLink {
                            OrgAgentDetailView(agent: manager)
                        } label: {
                            OrgAgentRow(agent: manager, isLead: true)
                        }
                        .swipeActions { deleteButton(manager) }

                        ForEach(org.children(of: manager.id)) { sub in
                            NavigationLink {
                                OrgAgentDetailView(agent: sub)
                            } label: {
                                OrgAgentRow(agent: sub, isLead: false)
                            }
                            .swipeActions { deleteButton(sub) }
                        }
                    }
                }

                let unassigned = org.agents.filter {
                    $0.tier == .sub && ($0.parent == nil || org.agent(id: $0.parent ?? "") == nil)
                }
                if !unassigned.isEmpty {
                    Section("Unassigned") {
                        ForEach(unassigned) { sub in
                            NavigationLink {
                                OrgAgentDetailView(agent: sub)
                            } label: {
                                OrgAgentRow(agent: sub, isLead: false)
                            }
                            .swipeActions { deleteButton(sub) }
                        }
                    }
                }
            }
            .navigationTitle("Organization")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { showingGenesis = true } label: {
                            Label("✨ Genesis — build MY company", systemImage: "sparkles")
                        }
                        Section("Load a preset (replaces org)") {
                            ForEach(HermesOrg.presets) { preset in
                                Button { pendingPreset = preset } label: {
                                    Label(preset.name, systemImage: "square.stack.3d.up.fill")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "rectangle.stack")
                    }
                    .accessibilityLabel("Org presets")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNew = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add agent")
                }
            }
            .sheet(isPresented: $showingNew) { AgentEditorView() }
            .sheet(isPresented: $showingGenesis) { OrgGenesisView() }
            .alert("Load “\(pendingPreset?.name ?? "")”?",
                   isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } })) {
                Button("Cancel", role: .cancel) { pendingPreset = nil }
                Button("Replace org", role: .destructive) {
                    if let preset = pendingPreset { org.applyPreset(preset.agents) }
                    pendingPreset = nil
                }
            } message: {
                Text("This replaces your current org (\(org.agents.count) agents) with the “\(pendingPreset?.name ?? "")” preset. Any custom agents or edits will be lost.")
            }
        }
    }

    private func deleteButton(_ agent: OrgAgent) -> some View {
        Button(role: .destructive) { org.delete(agent) } label: { Label("Delete", systemImage: "trash") }
    }
}

private struct OrgAgentRow: View {
    let agent: OrgAgent
    let isLead: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: agent.systemImage)
                .font(isLead ? .headline : .subheadline)
                .foregroundStyle(Color(hex: agent.accentHex))
                .frame(width: isLead ? 38 : 30, height: isLead ? 38 : 30)
                .background(Color(hex: agent.accentHex).opacity(0.16), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(isLead ? .headline : .subheadline.weight(.medium))
                if isLead {
                    Text(agent.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.leading, isLead ? 0 : 8)
    }
}

struct OrgAgentDetailView: View {
    @EnvironmentObject private var org: OrgStore
    @Environment(\.dismiss) private var dismiss
    private let initialAgent: OrgAgent
    @State private var showingEdit = false
    @State private var showingCall = false
    @State private var showingFireConfirm = false

    init(agent: OrgAgent) { initialAgent = agent }

    private var agent: OrgAgent { org.agent(id: initialAgent.id) ?? initialAgent }

    var body: some View {
        List {
            Section {
                // The agent's live 3D office — same robot as the War Room.
                AgentRoomSceneView(agent: agent)
                    .frame(height: 170)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .listRowInsets(EdgeInsets())
                HStack(spacing: 14) {
                    Image(systemName: agent.systemImage)
                        .font(.title2)
                        .foregroundStyle(Color(hex: agent.accentHex))
                        .frame(width: 54, height: 54)
                        .background(Color(hex: agent.accentHex).opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agent.name).font(.title3.weight(.bold))
                        Text(agent.title).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                if !agent.summary.isEmpty {
                    Text(agent.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                NavigationLink {
                    AgentChatView(agent: agent)
                } label: {
                    Label("Chat with \(agent.name)", systemImage: "message.fill")
                        .foregroundStyle(Color(hex: agent.accentHex))
                }
                Button { showingCall = true } label: {
                    Label("Call \(agent.name)", systemImage: "phone.fill")
                        .foregroundStyle(HermesTheme.emerald)
                }
                Button { showingEdit = true } label: {
                    Label("Edit agent", systemImage: "pencil")
                }
            }

            if let parentID = agent.parent, let parent = org.agent(id: parentID) {
                Section("Reports to") { Label(parent.name, systemImage: parent.systemImage) }
            }

            let team = org.children(of: agent.id)
            if !team.isEmpty {
                Section("Team") { ForEach(team) { Label($0.name, systemImage: $0.systemImage) } }
            }

            if !agent.skills.isEmpty {
                Section {
                    ForEach(agent.skills, id: \.self) {
                        Label($0, systemImage: "wrench.and.screwdriver.fill")
                            .foregroundStyle(HermesTheme.emerald)
                    }
                } header: {
                    Text("Skills (\(agent.skills.count))")
                } footer: {
                    Text("These Hermes skills load whenever you chat or call \(agent.name).")
                }
            }

            if !agent.plugins.isEmpty {
                Section {
                    ForEach(agent.plugins, id: \.self) {
                        Label($0, systemImage: "puzzlepiece.extension.fill")
                    }
                } header: {
                    Text("Plugins (\(agent.plugins.count))")
                } footer: {
                    Text("Enable these on the Mac (hermes plugins enable) to activate.")
                }
            }

            Section("soul.md") {
                if agent.soul.isEmpty {
                    Text("No soul.md yet — tap Edit to give this agent its persona.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(agent.soul).font(.system(.footnote, design: .monospaced))
                }
            }

            Section("Hermes profile") {
                Label(agent.profileSlug, systemImage: "cpu.fill")
            }

            Section {
                Button(role: .destructive) { showingFireConfirm = true } label: {
                    Label("Fire \(agent.name)", systemImage: "person.fill.xmark")
                }
            } footer: {
                Text("Removes this agent from your company. Create a replacement any time with ＋ in Agents.")
            }
        }
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingEdit) { AgentEditorView(agent: agent) }
        .fullScreenCover(isPresented: $showingCall) { AgentCallView(agent: agent) }
        .confirmationDialog("Fire \(agent.name)?", isPresented: $showingFireConfirm, titleVisibility: .visible) {
            Button("Fire \(agent.name)", role: .destructive) {
                org.delete(agent)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll be removed from the company. Their direct reports move under the CEO.")
        }
    }
}
