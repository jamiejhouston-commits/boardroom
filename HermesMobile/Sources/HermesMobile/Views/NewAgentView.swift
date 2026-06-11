import SwiftUI

enum AgentPalette {
    static let colors = ["39D98A", "55C7F7", "FFB020", "FF5D5D", "B16CFF", "FF8FB1", "2DD4BF", "F59E0B", "8B5CF6"]
}

struct NewAgentView: View {
    @EnvironmentObject private var store: AgentProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var handle = ""
    @State private var role = ""
    @State private var accentHex = AgentPalette.colors[0]
    @State private var backend: SandboxBackend = .local
    @State private var memorySummary = ""
    @State private var skillsText = ""
    @State private var soul = ""

    private var canSave: Bool {
        !handle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Handle (e.g. Orion)", text: $handle)
                        .autocorrectionDisabled()
                    TextField("Role (e.g. Analyst)", text: $role)
                }

                Section("Accent Color") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(AgentPalette.colors, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 34, height: 34)
                                    .overlay(
                                        Circle().stroke(.primary, lineWidth: accentHex == hex ? 3 : 0)
                                    )
                                    .onTapGesture { accentHex = hex }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Backend") {
                    Picker("Sandbox backend", selection: $backend) {
                        ForEach(SandboxBackend.allCases) { backend in
                            Text(backend.title).tag(backend)
                        }
                    }
                }

                Section("Memory Summary") {
                    TextField("What this agent tracks…", text: $memorySummary, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    TextField("Skills, comma-separated", text: $skillsText, axis: .vertical)
                        .lineLimit(1...3)
                        .autocorrectionDisabled()
                } header: {
                    Text("Skills")
                } footer: {
                    Text("e.g. planning, web search, codegen")
                }

                Section("soul.md") {
                    TextEditor(text: $soul)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                }
            }
            .navigationTitle("New Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if soul.isEmpty {
                    soul = "# New Agent\n\nYou are a Hermes agent. Describe how this agent should think, what it owns, and how it should behave.\n"
                }
            }
        }
    }

    private func create() {
        let skills = skillsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        store.addAgent(
            handle: handle.trimmingCharacters(in: .whitespaces),
            role: role.trimmingCharacters(in: .whitespaces),
            accentHex: accentHex,
            backend: backend,
            memorySummary: memorySummary.trimmingCharacters(in: .whitespacesAndNewlines),
            soulMarkdown: soul,
            skills: skills
        )
        dismiss()
    }
}
