import SwiftUI

struct WarRoomView: View {
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @State private var showHQ = false
    private let feedTicker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ScreenHeader(
                        title: "War Room",
                        subtitle: "Live floor for the agent organization. Swipe each leader's room, tap a department to dive in.",
                        systemImage: "rectangle.3.group.bubble.left.fill"
                    )

                    Button { showHQ = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "building.2.crop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(HermesTheme.gold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enter Headquarters")
                                    .font(.headline)
                                    .foregroundStyle(HermesTheme.textPrimary)
                                Text("Step onto the live 3D company floor")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(HermesTheme.emerald)
                        }
                        .hermesCard()
                    }
                    .buttonStyle(.plain)

                    liveFeed

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

                    NavigationLink {
                        VaultGraphView()
                    } label: {
                        Label("Knowledge graph", systemImage: "circle.hexagongrid.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(HermesTheme.emerald.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)

                    LeadershipStrip()
                }
                .padding()
            }
            .navigationTitle("War Room")
            .navigationBarTitleDisplayMode(.inline)
            .task { await company.refresh(relay: runtime.relayConfiguration) }
            .onReceive(feedTicker) { _ in
                Task { await company.refresh(relay: runtime.relayConfiguration) }
            }
            .fullScreenCover(isPresented: $showHQ) {
                HeadquartersView()
            }
        }
    }

    // Live activity feed — what the company has been doing, newest first.
    @ViewBuilder
    private var liveFeed: some View {
        let events = (company.state.events ?? []).suffix(12).reversed()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("LIVE ACTIVITY").font(.caption.weight(.black)).tracking(1)
                Spacer()
            }
            if events.isEmpty {
                Text("Quiet right now. Switch the company on (Boardroom) and activity shows up here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(events)) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(HermesTheme.emerald).padding(.top, 6)
                        Text(event.text).font(.caption).foregroundStyle(HermesTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text(event.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(HermesTheme.hairline, lineWidth: 1))
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
