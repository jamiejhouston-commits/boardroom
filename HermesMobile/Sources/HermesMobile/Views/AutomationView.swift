import SwiftUI

struct AutomationView: View {
    @EnvironmentObject private var store: AgentProfileStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.agents) { agent in
                        ForEach(agent.jobs) { job in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(job.title)
                                        .font(.headline)
                                    Spacer()
                                    Text(job.dueLabel)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                }

                                Text(job.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                HStack {
                                    ProgressView(value: job.progress)
                                        .tint(Color(hex: agent.accentHex))
                                    Text(agent.handle)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color(hex: agent.accentHex))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Scheduled Work")
                } footer: {
                    Text("This is the iPhone surface for Hermes cron: reports, backups, briefings, follow-ups, and unattended gateway tasks.")
                }

                Section("Create") {
                    Label("Natural-language schedule parser", systemImage: "text.badge.plus")
                    Label("Gateway wakeups", systemImage: "bell.badge.fill")
                    Label("Run history", systemImage: "list.bullet.clipboard.fill")
                }
            }
            .navigationTitle("Cron")
        }
    }
}
