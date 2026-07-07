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
                        if !runtime.relayConfiguration.isConfigured {
                            pairingCard
                        }
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

    /// First-run front door: nothing in the app is live until the Mac relay
    /// is paired, so say that plainly instead of hiding pairing in a menu.
    private var pairingCard: some View {
        Button { showGateway = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.title3)
                    .foregroundStyle(HermesTheme.gold)
                    .frame(width: 40, height: 40)
                    .background(HermesTheme.gold.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect your Mac")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(HermesTheme.textPrimary)
                    Text("Pair the Hermes relay to bring your company to life")
                        .font(.caption)
                        .foregroundStyle(HermesTheme.textSecondary)
                }
                Spacer()
                Text("PAIR")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(HermesTheme.emerald, in: Capsule())
            }
            .hermesCard()
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(HermesTheme.gold.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
            actionButton("War Room", "rectangle.3.group.fill") { router.go(.warRoom) }
            NavigationLink {
                LabsView()
            } label: {
                actionLabel("Labs", "flask.fill")
            }
            .buttonStyle(.plain)
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
                statTile(value: "\(activeTaskCount)", label: "Active Tasks", icon: "checklist", tint: HermesTheme.navy) { router.go(.warRoom) }
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

    /// Honest relay status — paired & healthy, degraded, or not paired.
    private var missionTile: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(HermesTheme.hairline, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: relayHealthy ? ringProgress : 0)
                    .stroke(HermesTheme.emerald, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: relayHealthy ? "checkmark" : "bolt.slash")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(relayHealthy ? HermesTheme.emerald : HermesTheme.textSecondary)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text("MAC RELAY")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(HermesTheme.textSecondary)
                Text(relayStatusLabel)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(relayHealthy ? HermesTheme.emerald : HermesTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .hermesCard()
    }

    private var relayHealthy: Bool {
        runtime.relayConfiguration.isConfigured && company.errorMessage == nil
    }

    private var relayStatusLabel: String {
        if !runtime.relayConfiguration.isConfigured { return "Not paired" }
        return company.errorMessage == nil ? "Connected" : "Unreachable"
    }

    private var activeTaskCount: Int {
        let tasks = (company.state.tasks ?? []).filter { $0.status != "done" }.count
        let building = company.state.initiatives.filter { !$0.isTerminal }.count
        return tasks + building
    }

    // MARK: Live feed

    /// Real company activity — the same events the War Room shows.
    private var liveFeed: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("LIVE FEED", actionTitle: "View all") { router.go(.warRoom) }
            VStack(spacing: 0) {
                let events = Array((company.state.events ?? []).suffix(5).reversed())
                if events.isEmpty {
                    Text(company.state.enabled
                         ? "No activity yet — the feed fills as your company works."
                         : "The company is idle — switch it on in the Boardroom.")
                        .font(.caption)
                        .foregroundStyle(HermesTheme.textSecondary)
                        .padding(.vertical, 9)
                } else {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        feedRow(event)
                        if index < events.count - 1 {
                            Divider().overlay(HermesTheme.hairline)
                        }
                    }
                }
            }
            .hermesCard()
        }
    }

    private func feedRow(_ event: CompanyEvent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.footnote)
                .foregroundStyle(HermesTheme.emerald)
                .frame(width: 30, height: 30)
                .background(HermesTheme.emerald.opacity(0.12), in: Circle())
            Text(event.text)
                .font(.caption)
                .foregroundStyle(HermesTheme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(event.date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                .font(.caption2)
                .foregroundStyle(HermesTheme.textSecondary)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    // MARK: Upcoming

    /// Real upcoming work: live meetings first, then enabled Cron schedules.
    private struct UpcomingRow: Identifiable {
        let id: String
        let time: String
        let title: String
        let detail: String
    }

    private var upcomingRows: [UpcomingRow] {
        var rows: [UpcomingRow] = (company.state.meetings ?? [])
            .filter(\.isLive)
            .map { UpcomingRow(id: "meeting-\($0.id)", time: "LIVE",
                               title: $0.topic, detail: $0.attendees.joined(separator: " · ")) }
        rows += (company.state.schedules ?? [])
            .filter(\.enabled)
            .map { UpcomingRow(id: "schedule-\($0.id)",
                               time: String(format: "%d:%02d", $0.atHour, $0.atMinute),
                               title: $0.title, detail: $0.cadenceSummary) }
        return Array(rows.prefix(4))
    }

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("UPCOMING", actionTitle: "Schedule") { router.go(.meetings) }
            VStack(spacing: 0) {
                let rows = upcomingRows
                if rows.isEmpty {
                    Text("Nothing on the calendar — schedule a meeting or add a Cron.")
                        .font(.caption)
                        .foregroundStyle(HermesTheme.textSecondary)
                        .padding(.vertical, 9)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, event in
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
                        if index < rows.count - 1 {
                            Divider().overlay(HermesTheme.hairline)
                        }
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
                                    if relayHealthy && company.state.enabled {
                                        Circle().fill(HermesTheme.emerald).frame(width: 8, height: 8).offset(x: 3, y: -3)
                                    }
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

    private var shippedCount: Int { company.state.initiatives.filter { $0.stage == "shipped" }.count }
    private var inFlightCount: Int { company.state.initiatives.filter { !$0.isTerminal }.count }
    private var tasksDoneCount: Int { (company.state.tasks ?? []).filter { $0.status == "done" }.count }

    /// Top initiatives by pipeline progress — the company's real priorities.
    private var topPriorities: [CompanyInitiative] {
        Array(company.state.initiatives.filter { !$0.isTerminal }
            .sorted { $0.progress > $1.progress }
            .prefix(3))
    }

    private var signals: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("KEY METRICS", icon: "chart.line.uptrend.xyaxis")
                metricRow("Products Shipped", "\(shippedCount)", "all time", HermesTheme.emerald)
                Divider().overlay(HermesTheme.hairline)
                metricRow("Initiatives In Flight", "\(inFlightCount)", "live", HermesTheme.steel)
                Divider().overlay(HermesTheme.hairline)
                metricRow("Tasks Completed", "\(tasksDoneCount)", "board", HermesTheme.navy)
            }
            .hermesCard()

            if !topPriorities.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    cardTitle("TOP PRIORITIES", icon: "flag.fill")
                    ForEach(Array(topPriorities.enumerated()), id: \.element.id) { index, initiative in
                        NavigationLink { BoardroomView() } label: {
                            priorityRow(initiative.title, initiative.stageLabel)
                        }
                        .buttonStyle(.plain)
                        if index < topPriorities.count - 1 {
                            Divider().overlay(HermesTheme.hairline)
                        }
                    }
                }
                .hermesCard()
            }

            VStack(alignment: .leading, spacing: 10) {
                cardTitle("SYSTEM ALERTS", icon: "bell.badge.fill")
                ForEach(Array(systemAlerts.enumerated()), id: \.offset) { index, alert in
                    alertRow(alert.text, alert.tint, alert.icon)
                    if index < systemAlerts.count - 1 {
                        Divider().overlay(HermesTheme.hairline)
                    }
                }
            }
            .hermesCard()
        }
    }

    private var systemAlerts: [(text: String, tint: Color, icon: String)] {
        var alerts: [(String, Color, String)] = []
        if !runtime.relayConfiguration.isConfigured {
            alerts.append(("Mac relay not paired — the company is offline", HermesTheme.gold, "bolt.slash.fill"))
        } else if company.errorMessage != nil {
            alerts.append(("Relay unreachable — check the Mac", HermesTheme.gold, "wifi.exclamationmark"))
        }
        if !company.pendingGates.isEmpty {
            alerts.append(("\(company.pendingGates.count) decision\(company.pendingGates.count == 1 ? "" : "s") waiting in the Boardroom", HermesTheme.gold, "building.columns.fill"))
        }
        if runtime.relayConfiguration.isConfigured && !company.state.enabled {
            alerts.append(("Company halted — agents are idle", HermesTheme.silver, "moon.zzz.fill"))
        }
        if alerts.isEmpty {
            alerts.append(("All systems operational", HermesTheme.emerald, "checkmark.circle.fill"))
        }
        return alerts
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

}

/// Off-mission utilities, kept but out of the company's way.
struct LabsView: View {
    var body: some View {
        List {
            Section {
                NavigationLink { EarthquakeReadyHomeView() } label: {
                    Label("Earthquake Ready", systemImage: "waveform.path.ecg.rectangle.fill")
                }
                NavigationLink { AirQualityWindowHomeView() } label: {
                    Label("Air Quality Window", systemImage: "wind")
                }
                NavigationLink { TravelPackingHomeView() } label: {
                    Label("Travel Packing Lists", systemImage: "suitcase.fill")
                }
            } footer: {
                Text("Standalone utilities that live outside the company.")
            }
        }
        .navigationTitle("Labs")
        .navigationBarTitleDisplayMode(.inline)
    }
}
