import SwiftUI

struct AgentsView: View {
    @EnvironmentObject private var store: AgentProfileStore
    @State private var showingNew = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.agents) { agent in
                        NavigationLink {
                            AgentDetailView(agent: agent)
                        } label: {
                            HStack(spacing: 12) {
                                Text(agent.initials)
                                    .font(.caption.weight(.black))
                                    .frame(width: 42, height: 42)
                                    .background(Color(hex: agent.accentHex).opacity(0.2), in: Circle())

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(agent.handle)
                                        .font(.headline)
                                    Text(agent.role)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                                StatusPill(title: agent.status.title, color: agent.status.color, systemImage: "circle.fill")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Profiles")
                } footer: {
                    Text("Each profile persists its own config, memory summary, skills, jobs, connector state, and `soul.md` file.")
                }
            }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New agent")
                }
            }
            .sheet(isPresented: $showingNew) {
                NewAgentView()
            }
        }
    }
}

struct AgentDetailView: View {
    @EnvironmentObject private var store: AgentProfileStore
    @State private var soulDraft: String
    var agent: AgentProfile

    init(agent: AgentProfile) {
        self.agent = agent
        _soulDraft = State(initialValue: agent.soulMarkdown)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(agent.initials)
                            .font(.title3.weight(.black))
                            .frame(width: 54, height: 54)
                            .background(Color(hex: agent.accentHex).opacity(0.2), in: Circle())

                        VStack(alignment: .leading, spacing: 5) {
                            Text(agent.handle)
                                .font(.title3.weight(.bold))
                            Text(agent.role)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    StatusPill(title: agent.status.title, color: agent.status.color, systemImage: "circle.fill")
                    Text(agent.memorySummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("soul.md") {
                TextEditor(text: $soulDraft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)

                Button {
                    store.updateSoul(for: agent, soulMarkdown: soulDraft)
                } label: {
                    Label("Save soul.md", systemImage: "square.and.arrow.down.fill")
                }

                Text(store.fileLocationLabel(for: agent))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Skills") {
                ForEach(agent.skills, id: \.self) { skill in
                    Label(skill, systemImage: "checkmark.seal.fill")
                }
            }

            Section("Backends") {
                Label(agent.backend.title, systemImage: "server.rack")
                ForEach(SandboxBackend.allCases) { backend in
                    HStack {
                        Text(backend.title)
                        Spacer()
                        if backend == agent.backend {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.mint)
                        }
                    }
                }
            }
        }
        .navigationTitle(agent.handle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
