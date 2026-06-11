import SwiftUI

struct AttendeePickerView: View {
    @EnvironmentObject private var org: OrgStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    var confirmTitle: String = "Start"
    var onConfirm: ([OrgAgent]) -> Void

    private var leaders: [OrgAgent] { org.leadership }

    var body: some View {
        NavigationStack {
            List {
                ForEach(leaders, id: \.id) { lead in
                    Section(lead.tier == .ceo ? "Executive" : lead.title) {
                        row(lead)
                        if lead.tier != .ceo {
                            ForEach(org.children(of: lead.id)) { sub in
                                row(sub)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pick Attendees")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("\(confirmTitle) (\(selected.count))") {
                        let chosen = org.agents.filter { selected.contains($0.id) }
                        onConfirm(chosen)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }

    private func row(_ agent: OrgAgent) -> some View {
        Button {
            if selected.contains(agent.id) { selected.remove(agent.id) } else { selected.insert(agent.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: agent.systemImage)
                    .foregroundStyle(Color(hex: agent.accentHex))
                    .frame(width: 30, height: 30)
                    .background(Color(hex: agent.accentHex).opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                Text(agent.name)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: selected.contains(agent.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(agent.id) ? .mint : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
