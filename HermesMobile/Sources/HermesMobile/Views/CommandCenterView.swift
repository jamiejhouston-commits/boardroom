import SwiftUI

/// The Command Center — the app's home. A live, calm operational dashboard
/// over the real organization. Everything that looks tappable IS: chips and
/// rows push the agent's detail; the quick-action bar and section actions jump
/// to the relevant tab via `AppRouter`.
///
/// Visuals follow `HermesTheme` (creamy light / deep-navy dark, muted accents).
struct CommandCenterView: View {
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var briefings: BriefingCenter
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @State private var ringProgress: CGFloat = 0
    @State private var showSettings = false
    @State private var showGateway = false
    @State private var showBriefing = false

    var body: some View {
        NavigationStack {
            ZStack {
                HermesTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        topBar
                        tagline
                        briefingCard
                        boardroomCard
                        hero
                        quickActions
                        overview
                        liveFeed
                        upcoming
                        departmentStatus
                        signals
                        footer
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showGateway) { GatewayView() }
            .sheet(isPresented: $showBriefing) { BriefingView() }
            .onAppear {
                withAnimation(.easeOut(duration: 1.1)) { ringProgress = 0.992 }
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Menu {
                Button { router.go(.chat) } label: { Label("Message the company", systemImage: "message.fill") }
                Button { router.go(.meetings) } label: { Label("Schedule a meeting", systemImage: "person.2.wave.2.fill") }
                Button { router.go(.agents) } label: { Label("Manage agents", systemImage: "person.3.fill") }
                Button { router.go(.warRoom) } label: { Label("Open the War Room", systemImage: "rectangle.3.group.fill") }
                Divider()
                Button { showGateway = true } label: { Label("Gateway", systemImage: "antenna.radiowaves.left.and.right") }
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape.fill") }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(HermesTheme.textSecondary)
            }

            Spacer()

            VStack(spacing: 2) {
                HStack(spacing: 7) {
                    Image(systemName: "staroflife.fill")
                        .font(.caption)
                        .foregroundStyle(HermesTheme.gold)
                    Text("BOARDROOM")
                        .font(.headline.weight(.bold))
                        .tracking(5)
                        .foregroundStyle(HermesTheme.textPrimary)
                }
                Text("COMMAND CENTER")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(4)
                    .foregroundStyle(HermesTheme.textSecondary)
            }

            Spacer()

            Button { showSettings = true } label: {
                Circle()
                    .fill(HermesTheme.surfaceRaised)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(HermesTheme.gold.opacity(0.6), lineWidth: 1))
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.caption)
                            .foregroundStyle(HermesTheme.textSecondary)
                    )
            }
        }
    }

    private var tagline: some View {
        Text("ONE ORGANIZATION · ONE MISSION · LIMITLESS IMPACT")
            .font(.system(size: 10, weight: .semibold))
            .tracking(2)
            .foregroundStyle(HermesTheme.textSecondary)
            .frame(maxWidth: .infinity)
    }

    /// The Secretary's daily opener — tap into the full briefing.
    private var briefingCard: some View {
        Button { showBriefing = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "sunrise.fill")
                    .font(.title3)
                    .foregroundStyle(HermesTheme.gold)
                    .frame(width: 40, height: 40)
                    .background(HermesTheme.gold.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Morning Briefing")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(HermesTheme.textPrimary)
                    Text(briefings.isFreshToday
                         ? "Today's briefing is ready — tap to read"
                         : "Your secretary will line up the day")
                        .font(.caption)
                        .foregroundStyle(HermesTheme.textSecondary)
                }
                Spacer()
                if briefings.isFreshToday {
                    Circle().fill(HermesTheme.emerald).frame(width: 9, height: 9)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(HermesTheme.textSecondary)
            }
            .hermesCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: Boardroom — the autonomous company + pending gates

    private var boardroomCard: some View {
        NavigationLink {
            BoardroomView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "building.columns.fill")
                    .font(.title3)
                    .foregroundStyle(HermesTheme.emerald)
                    .frame(width: 38, height: 38)
                    .background(HermesTheme.emerald.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Boardroom")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(HermesTheme.textPrimary)
                    Text(boardroomStatus)
                        .font(.caption)
                        .foregroundStyle(HermesTheme.textSecondary)
                }
                Spacer()
                if !company.pendingGates.isEmpty {
                    Text("\(company.pendingGates.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(HermesTheme.gold, in: Circle())
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(HermesTheme.textSecondary)
            }
            .hermesCard()
        }
        .buttonStyle(.plain)
        .task { await company.refresh(relay: runtime.relayConfiguration) }
    }

    private var boardroomStatus: String {
        if !company.pendingGates.isEmpty {
            return "The board is waiting on your decision"
        }
        if company.state.enabled {
            return "Company running — agents are working"
        }
        return "Company halted — tap to switch it on"
    }

    // MARK: Hero — emblem + leadership

    private var hero: some View {
        VStack(spacing: 14) {
            if let gm = org.ceo {
                NavigationLink {
                    OrgAgentDetailView(agent: gm)
                } label: {
                    VStack(spacing: 8) {
                        emblem
                        VStack(spacing: 2) {
                            Text(gm.name.uppercased())
                                .font(.subheadline.weight(.bold))
                                .tracking(2)
                                .foregroundStyle(HermesTheme.textPrimary)
                            Text(gm.title)
                                .font(.caption)
                                .foregroundStyle(HermesTheme.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            } else {
                emblem
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(org.managers) { agent in
                        NavigationLink {
                            OrgAgentDetailView(agent: agent)
                        } label: {
                            leadershipChip(agent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(HermesTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(HermesTheme.hairline, lineWidth: 1)
        )
    }

    private var emblem: some View {
        ZStack {
            Circle().strokeBorder(HermesTheme.gold.opacity(0.35), lineWidth: 1).frame(width: 116, height: 116)
            Circle().strokeBorder(HermesTheme.emerald.opacity(0.30), lineWidth: 1).frame(width: 92, height: 92)
            Circle().fill(HermesTheme.surface).frame(width: 74, height: 74)
                .overlay(Circle().strokeBorder(HermesTheme.gold.opacity(0.7), lineWidth: 1.5))
            Image(systemName: "staroflife.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(HermesTheme.gold)
        }
        .padding(.top, 6)
    }

    private func leadershipChip(_ agent: OrgAgent) -> some View {
        VStack(spacing: 6) {
            Image(systemName: agent.systemImage)
                .font(.subheadline)
                .foregroundStyle(HermesTheme.textPrimary)
                .frame(width: 42, height: 42)
                .background(HermesTheme.surface, in: Circle())
                .overlay(Circle().strokeBorder(HermesTheme.hairline, lineWidth: 1))
            Text(agent.title.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(1)
                .foregroundStyle(HermesTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 60)
    }

    // MARK: Quick actions — unambiguous buttons that go somewhere

    private var quickActions: some View {
        HStack(spacing: 10) {
            actionButton("Message", "message.fill") { router.go(.chat) }
            // Straight into the 3D boardroom — leadership already in the room.
            NavigationLink {
                MeetingRoomView(attendees: org.leadership)
            } label: {
                actionLabel("Conference", "video.fill")
            }
            .buttonStyle(.plain)
            NavigationLink {
                EarthquakeReadyHomeView()
            } label: {
                actionLabel("Earthquake", "waveform.path.ecg.rectangle.fill")
            }
            .buttonStyle(.plain)
            NavigationLink {
                AirQualityWindowHomeView()
            } label: {
                actionLabel("Air Quality", "wind")
            }
            .buttonStyle(.plain)
            actionButton("War Room", "rectangle.3.group.fill") { router.go(.warRoom) }
        }
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionLabel(title, icon)
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HermesTheme.emerald)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(HermesTheme.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HermesTheme.emerald.opacity(0.35), lineWidth: 1))
    }

    // MARK: Organization overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("ORGANIZATION OVERVIEW", actionTitle: nil, action: nil)

            HStack(spacing: 10) {
                statTile(value: "\(org.agents.count)", label: "Total Agents", icon: "person.3.fill", tint: HermesTheme.emerald) { router.go(.agents) }
                statTile(value: "\(org.managers.count)", label: "Departments", icon: "square.grid.2x2.fill", tint: HermesTheme.steel) { router.go(.agents) }
            }
            HStack(spacing: 10) {
                statTile(value: "143", label: "Active Tasks", icon: "checklist", tint: HermesTheme.navy) { router.go(.meetings) }
                missionTile
            }
        }
    }

    private func statTile(value: String, label: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.subheadline).foregroundStyle(tint)
                Text(value).font(.title2.weight(.bold)).foregroundStyle(HermesTheme.textPrimary)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(HermesTheme.textSecondary)
            }
            .hermesCard()
        }
        .buttonStyle(.plain)
    }

    private var missionTile: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(HermesTheme.hairline, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(HermesTheme.emerald, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("99%").font(.caption.weight(.bold)).foregroundStyle(HermesTheme.textPrimary)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text("SYSTEM HEALTH")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(HermesTheme.textSecondary)
                Text("On Track").font(.subheadline.weight(.bold)).foregroundStyle(HermesTheme.emerald)
            }
            Spacer(minLength: 0)
        }
        .hermesCard()
    }

    // MARK: Live feed

    private var liveFeed: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("LIVE FEED", actionTitle: "View all") { router.go(.agents) }
            VStack(spacing: 0) {
                ForEach(Array(Self.feed.enumerated()), id: \.element.id) { index, item in
                    feedRowLink(item)
                    if index < Self.feed.count - 1 {
                        Divider().overlay(HermesTheme.hairline)
                    }
                }
            }
            .hermesCard()
        }
    }

    @ViewBuilder
    private func feedRowLink(_ item: FeedItem) -> some View {
        if let agent = matchedAgent(item.agent) {
            NavigationLink { OrgAgentDetailView(agent: agent) } label: { feedRow(item) }
                .buttonStyle(.plain)
        } else {
            feedRow(item)
        }
    }

    private func feedRow(_ item: FeedItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.footnote)
                .foregroundStyle(item.tint)
                .frame(width: 30, height: 30)
                .background(item.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(item.agent).font(.subheadline.weight(.semibold)).foregroundStyle(HermesTheme.textPrimary)
                Text(item.text).font(.caption).foregroundStyle(HermesTheme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(item.time).font(.caption2).foregroundStyle(HermesTheme.textSecondary)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    // MARK: Upcoming

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("UPCOMING", actionTitle: "Schedule") { router.go(.meetings) }
            VStack(spacing: 0) {
                ForEach(Array(Self.events.enumerated()), id: \.element.id) { index, event in
                    Button { router.go(.meetings) } label: {
                        HStack(spacing: 12) {
                            Text(event.time)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(HermesTheme.emerald)
                                .frame(width: 52, alignment: .leading)
                            Rectangle().fill(HermesTheme.hairline).frame(width: 1, height: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title).font(.subheadline.weight(.semibold)).foregroundStyle(HermesTheme.textPrimary)
                                Text(event.detail).font(.caption).foregroundStyle(HermesTheme.textSecondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(HermesTheme.textSecondary)
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < Self.events.count - 1 {
                        Divider().overlay(HermesTheme.hairline)
                    }
                }
            }
            .hermesCard()
        }
    }

    // MARK: Department status

    private var departmentStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("DEPARTMENT STATUS", actionTitle: nil, action: nil)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(org.managers) { agent in
                        NavigationLink {
                            OrgAgentDetailView(agent: agent)
                        } label: {
                            VStack(spacing: 7) {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: agent.systemImage)
                                        .font(.subheadline)
                                        .foregroundStyle(HermesTheme.textPrimary)
                                        .frame(width: 46, height: 46)
                                        .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(HermesTheme.hairline, lineWidth: 1))
                                    Circle().fill(HermesTheme.emerald).frame(width: 8, height: 8).offset(x: 3, y: -3)
                                }
                                Text(shortTitle(agent))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(HermesTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 58)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: Signals (key metrics / priorities / alerts)

    private var signals: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("KEY METRICS", icon: "chart.line.uptrend.xyaxis")
                metricRow("Monthly ROI", "$245K", "+12%", HermesTheme.emerald)
                Divider().overlay(HermesTheme.hairline)
                metricRow("Active Agents", "\(org.agents.count)", "live", HermesTheme.steel)
                Divider().overlay(HermesTheme.hairline)
                metricRow("Hours Saved", "1,204", "this mo", HermesTheme.navy)
            }
            .hermesCard()

            VStack(alignment: .leading, spacing: 10) {
                cardTitle("TOP PRIORITIES", icon: "flag.fill")
                priorityRowLink("Close Q2 financial review", "CFO Agent")
                Divider().overlay(HermesTheme.hairline)
                priorityRowLink("Ship onboarding flow", "CTO Agent")
                Divider().overlay(HermesTheme.hairline)
                priorityRowLink("Launch growth campaign", "Marketing Agent")
            }
            .hermesCard()

            VStack(alignment: .leading, spacing: 10) {
                cardTitle("SYSTEM ALERTS", icon: "bell.badge.fill")
                alertRow("All systems operational", HermesTheme.emerald, "checkmark.circle.fill")
                Divider().overlay(HermesTheme.hairline)
                alertRow("2 agents idle — capacity available", HermesTheme.silver, "moon.zzz.fill")
            }
            .hermesCard()
        }
    }

    private var footer: some View {
        Text("SECURE · PRIVATE · SOVEREIGN")
            .font(.system(size: 9, weight: .semibold))
            .tracking(3)
            .foregroundStyle(HermesTheme.textSecondary.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    // MARK: Small builders

    private func metricRow(_ label: String, _ value: String, _ delta: String, _ tint: Color) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(HermesTheme.textSecondary)
            Spacer()
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(HermesTheme.textPrimary)
            Text(delta)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tint.opacity(0.12), in: Capsule())
        }
    }

    @ViewBuilder
    private func priorityRowLink(_ title: String, _ owner: String) -> some View {
        if let agent = matchedAgent(owner) {
            NavigationLink { OrgAgentDetailView(agent: agent) } label: { priorityRow(title, owner) }
                .buttonStyle(.plain)
        } else {
            priorityRow(title, owner)
        }
    }

    private func priorityRow(_ title: String, _ owner: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(HermesTheme.emerald.opacity(0.5)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(HermesTheme.textPrimary)
                Text(owner).font(.caption2).foregroundStyle(HermesTheme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(HermesTheme.textSecondary)
        }
        .contentShape(Rectangle())
    }

    private func alertRow(_ text: String, _ tint: Color, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.footnote).foregroundStyle(tint)
            Text(text).font(.subheadline).foregroundStyle(HermesTheme.textPrimary)
            Spacer(minLength: 0)
        }
    }

    private func cardTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(HermesTheme.gold)
            Text(title).font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(HermesTheme.textPrimary)
            Spacer()
        }
    }

    private func sectionHeader(_ title: String, actionTitle: String?, action: (() -> Void)?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundStyle(HermesTheme.textSecondary)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HermesTheme.emerald)
                }
            }
        }
    }

    private func shortTitle(_ agent: OrgAgent) -> String {
        let name = agent.name.replacingOccurrences(of: " Agent", with: "")
        return name.count <= 10 ? name : agent.title
    }

    /// Best-effort match of a feed/priority label to a real org agent.
    private func matchedAgent(_ name: String) -> OrgAgent? {
        let lower = name.lowercased()
        if let exact = org.agents.first(where: { lower.contains($0.name.lowercased()) || $0.name.lowercased().contains(lower) }) {
            return exact
        }
        let firstWord = lower.split(separator: " ").first.map(String.init) ?? lower
        return org.agents.first(where: { $0.name.lowercased().contains(firstWord) }) ?? org.ceo
    }

    // MARK: Seeded illustrative content (wired to real signals later)

    private struct FeedItem: Identifiable {
        let id = UUID()
        let agent: String
        let icon: String
        let text: String
        let time: String
        let tint: Color
    }

    private static let feed: [FeedItem] = [
        FeedItem(agent: "Marketing Agent", icon: "megaphone.fill", text: "Campaign analytics refreshed", time: "2m", tint: HermesTheme.emerald),
        FeedItem(agent: "CFO Agent", icon: "dollarsign.circle.fill", text: "Monthly cash-flow reconciled", time: "11m", tint: HermesTheme.navy),
        FeedItem(agent: "Operations Agent", icon: "gearshape.2.fill", text: "3 workflows completed", time: "24m", tint: HermesTheme.steel),
        FeedItem(agent: "Builder Agent", icon: "cube.fill", text: "Pushed onboarding scaffold", time: "1h", tint: HermesTheme.emeraldSoft),
        FeedItem(agent: "Legal Agent", icon: "building.columns.fill", text: "Reviewed vendor contract", time: "2h", tint: HermesTheme.silver)
    ]

    private struct EventItem: Identifiable {
        let id = UUID()
        let time: String
        let title: String
        let detail: String
    }

    private static let events: [EventItem] = [
        EventItem(time: "9:00", title: "Executive Standup", detail: "GM · all department heads"),
        EventItem(time: "11:30", title: "Strategy Review", detail: "Strategy · CFO · CPO"),
        EventItem(time: "2:00", title: "Budget Review", detail: "CFO · Accounting"),
        EventItem(time: "4:00", title: "Product Demo", detail: "CPO · Builder · QA")
    ]
}
