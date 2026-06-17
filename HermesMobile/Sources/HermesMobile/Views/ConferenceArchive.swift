import SwiftUI

/// Which back-wall screen the user tapped in the Conference Room.
enum ConferenceArchiveKind: Int, Identifiable {
    case minutes, vault
    var id: Int { rawValue }
}

/// Live minutes of the meeting in progress — tapping the right-hand screen.
struct MeetingMinutesView: View {
    let messages: [ChatMessage]
    let elapsed: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        Text("Minutes will fill in as the meeting talks.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(messages) { message in
                            ChatBubble(message: message, speaker: "Agent", accentHex: "39D98A")
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Meeting Minutes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Label(elapsed, systemImage: "clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Every decision the company has taken — tapping the left-hand screen.
struct DecisionVaultView: View {
    let initiatives: [CompanyInitiative]
    @Environment(\.dismiss) private var dismiss

    private struct Decision: Identifiable {
        let id: String
        let title: String
        let outcome: String
        let color: Color
        let detail: String
        let date: String
    }

    private var decisions: [Decision] {
        initiatives.compactMap { initiative in
            let outcome: String
            let color: Color
            switch initiative.stage {
            case "shipped":
                outcome = "Shipped"; color = HermesTheme.emerald
            case "killed":
                outcome = "Killed"; color = .red
            case "planning", "execution", "demo_ready", "gate2":
                outcome = "Greenlit"; color = HermesTheme.gold
            default:
                return nil   // research / boardroom / gate1 — no decision taken yet
            }
            return Decision(id: initiative.id,
                            title: initiative.title,
                            outcome: outcome,
                            color: color,
                            detail: initiative.note.isEmpty ? initiative.stageLabel : initiative.note,
                            date: String(initiative.created.prefix(10)))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if decisions.isEmpty {
                    Section {
                        Text("No decisions logged yet. When you greenlight, ship, or kill an initiative — or your PA records a meeting decision — it lands here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(decisions) { decision in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top) {
                                    Text(decision.title)
                                        .font(.subheadline.weight(.bold))
                                        .lineLimit(2)
                                    Spacer()
                                    Text(decision.outcome.uppercased())
                                        .font(.caption2.weight(.black)).tracking(1)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(decision.color.opacity(0.18), in: Capsule())
                                        .foregroundStyle(decision.color)
                                }
                                Text(decision.detail)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                Text(decision.date)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("\(decisions.count) decisions on record")
                    }
                }
            }
            .navigationTitle("Decision Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
