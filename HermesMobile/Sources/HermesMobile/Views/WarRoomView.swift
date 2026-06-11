import SwiftUI

struct WarRoomView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ScreenHeader(
                        title: "War Room",
                        subtitle: "Live floor for the agent organization. Swipe each leader's room, tap a department to dive in.",
                        systemImage: "rectangle.3.group.bubble.left.fill"
                    )

                    AgentStudio3DPanel()

                    NavigationLink {
                        CompanyFloorView()
                    } label: {
                        Label("See the whole company floor", systemImage: "building.2.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.mint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)

                    LeadershipStrip()
                }
                .padding()
            }
            .navigationTitle("War Room")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct LeadershipStrip: View {
    @EnvironmentObject private var org: OrgStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Departments")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(org.leadership) { agent in
                        NavigationLink {
                            OrgAgentDetailView(agent: agent)
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: agent.systemImage)
                                        .foregroundStyle(Color(hex: agent.accentHex))
                                        .frame(width: 36, height: 36)
                                        .background(Color(hex: agent.accentHex).opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
                                    Spacer()
                                    Circle().fill(.green).frame(width: 10, height: 10)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agent.name)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text(agent.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .frame(width: 152, height: 120)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
