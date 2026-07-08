import SwiftUI

struct MeetingsView: View {
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @State private var showPicker = false
    @State private var showSchedule = false
    @State private var active: [OrgAgent] = []
    @State private var radioMeeting: CompanyMeeting?
    @State private var showConvene = false
    @State private var conveneTopic = ""
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let companyTicker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var roomAttendees: [OrgAgent] {
        if !active.isEmpty {
            return active
        }

        let seeded = org.leadership + org.agents.filter { $0.tier == .sub }
        return Array(seeded.prefix(13))
    }

    /// Real elapsed time of the LIVE meeting — from its actual start stamp.
    /// nil when nothing is in session (the room shows honest idle state).
    private var liveElapsedText: String? {
        guard let live = company.liveMeeting,
              let start = CompanyMeeting.parseStarted(live.started) else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                MeetingRoomSceneView(attendees: roomAttendees,
                                     stats: RoomStats.from(state: company.state,
                                                           liveTopic: company.liveMeeting?.topic))
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        .black.opacity(0.94),
                        .black.opacity(0.22),
                        .black.opacity(0.08),
                        .black.opacity(0.60),
                        .black.opacity(0.88)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    topChrome
                        .padding(.horizontal, 24)
                        .padding(.top, 12)

                    statusStrip
                        .padding(.horizontal, 64)
                        .padding(.top, 24)

                    autonomousMeetingBanner
                        .padding(.horizontal, 24)
                        .padding(.top, 16)

                    Spacer()

                    NavigationLink {
                        MeetingRoomView(attendees: roomAttendees)
                    } label: {
                        meetingStatsPanel
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 62)
                    .padding(.bottom, 88)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showPicker) {
                AttendeePickerView(confirmTitle: "Update Room") { chosen in
                    active = chosen
                }
            }
            .sheet(isPresented: $showSchedule) { ScheduleMeetingView() }
            .sheet(item: $radioMeeting) { MeetingRadioView(meeting: $0) }
            .onReceive(ticker) { _ in now = Date() }
            .onReceive(companyTicker) { _ in
                Task { await company.refresh(relay: runtime.relayConfiguration) }
            }
            .task { await company.refresh(relay: runtime.relayConfiguration) }
            .alert("Convene a meeting now", isPresented: $showConvene) {
                TextField("Topic (e.g. This week's priorities)", text: $conveneTopic)
                Button("Convene") { convene() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The leadership meets on your topic immediately — the room goes live within a minute.")
            }
        }
    }

    private func convene() {
        let topic = conveneTopic.trimmingCharacters(in: .whitespaces)
        guard !topic.isEmpty, runtime.relayConfiguration.isConfigured else { return }
        conveneTopic = ""
        Task {
            try? await HermesRelayClient(configuration: runtime.relayConfiguration)
                .conveneMeeting(topic: topic)
            await company.refresh(relay: runtime.relayConfiguration)
        }
    }

    // The org's own meetings — live now (walk into the room) or recent.
    @ViewBuilder
    private var autonomousMeetingBanner: some View {
        if let live = company.liveMeeting {
            HStack(spacing: 12) {
                NavigationLink {
                    LiveMeetingRoomView(meetingID: live.id, topic: live.topic)
                } label: {
                    HStack(spacing: 12) {
                        Circle().fill(HermesTheme.emerald).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your team is meeting now")
                                .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            Text(live.topic).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)

                // The Meeting Radio — spoken turns, hands-free, screen-locked.
                Button { radioMeeting = live } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "radio.fill")
                        Text("Listen")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(HermesTheme.emerald)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(HermesTheme.emerald.opacity(0.16), in: Capsule())
                    .overlay(Capsule().stroke(HermesTheme.emerald.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(HermesTheme.emerald.opacity(0.4), lineWidth: 1))
        } else {
            HStack(spacing: 12) {
                if let recent = company.meetings.first {
                    NavigationLink {
                        MeetingTranscriptView(meetingID: recent.id, topic: recent.topic)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.2.wave.2.fill").foregroundStyle(HermesTheme.emerald)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Last team meeting").font(.caption).foregroundStyle(.white.opacity(0.6))
                                Text(recent.topic).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("No meetings yet — your team convenes on its own once the company is on.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 8)
                }

                // Convene now — the org meets on YOUR topic immediately.
                Button { showConvene = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "person.3.fill")
                        Text("Convene")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(HermesTheme.emerald)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(HermesTheme.emerald.opacity(0.16), in: Capsule())
                    .overlay(Capsule().stroke(HermesTheme.emerald.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.1), lineWidth: 1))
        }
    }

    private var topChrome: some View {
        HStack {
            // Attendee picker — a people icon, not a back chevron (that read
            // as "go back" and surprised everyone who tapped it).
            Button {
                showPicker = true
            } label: {
                Image(systemName: "person.3.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.44), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
            }
            .accessibilityLabel("Change attendees")

            Spacer()

            Text("Conference Room")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 8, y: 2)

            Spacer()

            HStack(spacing: 10) {
                // All meetings — live, scheduled, and history with minutes.
                NavigationLink {
                    MeetingsListView()
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.44), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
                }
                .accessibilityLabel("All meetings")

                // Schedule a meeting → Apple Calendar + 15-min alert + prep memo.
                Button { showSchedule = true } label: {
                    Image(systemName: "calendar.badge.plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.44), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
                }
                .accessibilityLabel("Schedule meeting")

                // The internal mail room.
                NavigationLink {
                    MemosView()
                } label: {
                    Image(systemName: "envelope.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.44), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
                }
                .accessibilityLabel("Memos")
            }
        }
    }

    // HONEST status: green + "Meeting in progress" ONLY while the org is
    // actually in session; otherwise the room says it's idle.
    private var statusStrip: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                Circle()
                    .fill(company.liveMeeting != nil ? HermesTheme.emerald : Color.white.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(company.liveMeeting != nil ? "Meeting in progress" : "Room idle")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 8)

            Button {
                showPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.3.fill")
                    Text("\(roomAttendees.count) Participants")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .buttonStyle(.plain)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 17)
        .frame(height: 42)
        .background(.black.opacity(0.42), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }

    // HONEST panel: the live topic + real elapsed time, or the truth that
    // nothing is in session (the fake "Q2 Strategy Review" at 32:47 is gone).
    private var meetingStatsPanel: some View {
        HStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "chart.bar.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(HermesTheme.emerald)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(company.liveMeeting != nil ? "Current Topic" : "Walk-in Room")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.64))
                    Text(company.liveMeeting?.topic ?? "No meeting right now")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 1, height: 44)

            HStack(spacing: 12) {
                Image(systemName: "clock")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(HermesTheme.emerald)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Time Elapsed")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.64))
                    Text(liveElapsedText ?? "—")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 72)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }
}

// MARK: - Autonomous meeting transcript (listen in)

struct MeetingTranscriptView: View {
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    let meetingID: String
    let topic: String

    @State private var meeting: CompanyMeeting?
    @State private var speaking = false
    @State private var draft = ""
    @State private var sending = false
    @State private var actionsRequested = false
    @FocusState private var focused: Bool
    private let voice = AgentVoice()
    private let refresh = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section {
                ForEach(meeting?.turns ?? []) { turn in
                    let isOwner = turn.role == "owner"
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isOwner ? "YOU" : turn.role.uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isOwner ? HermesTheme.gold : HermesTheme.emerald)
                        Text(turn.text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
                if sending {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("The room is responding to you…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if (meeting?.turns ?? []).isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("The meeting is starting…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack {
                    Text(meeting?.isLive == true ? "🟢 In session" : "Minutes")
                    Spacer()
                    if !(meeting?.turns ?? []).isEmpty {
                        Button(speaking ? "Stop" : "Read aloud") { toggleSpeak() }
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .navigationTitle(topic)
        .navigationBarTitleDisplayMode(.inline)
        .keepScreenAwake()
        .toolbar {
            // Talk becomes tracked work: the CEO distills a finished meeting
            // into Kanban action items.
            if meeting?.isLive == false, !(meeting?.turns ?? []).isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        actionsRequested = true
                        Task {
                            try? await HermesRelayClient(configuration: runtime.relayConfiguration)
                                .meetingActions(id: meetingID)
                        }
                    } label: {
                        Label("Turn into tasks", systemImage: "checklist")
                    }
                    .disabled(actionsRequested)
                    .accessibilityLabel("Turn this meeting into action items")
                }
            }
        }
        // Speak into the meeting — the team responds to your steer.
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                TextField("Weigh in — the team will respond…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(HermesTheme.hairline, lineWidth: 1))
                Button(action: sayIntoMeeting) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                        .foregroundStyle(canSend ? HermesTheme.emerald : HermesTheme.textSecondary.opacity(0.4))
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
        .task { await load() }
        .onReceive(refresh) { _ in
            if meeting?.isLive != false || sending { Task { await load() } }
        }
        .onDisappear { voice.stop() }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    private func sayIntoMeeting() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""; focused = false; sending = true
        Task {
            await company.meetingSay(id: meetingID, text: text, relay: runtime.relayConfiguration)
            // Poll until the team's responses land (or ~90s).
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(6))
                await load()
            }
            sending = false
        }
    }

    private func load() async {
        meeting = await company.meetingDetail(id: meetingID, relay: runtime.relayConfiguration)
    }

    private func toggleSpeak() {
        if speaking { voice.stop(); speaking = false; return }
        guard let turns = meeting?.turns, !turns.isEmpty else { return }
        speaking = true
        Task {
            for turn in turns {
                if !speaking { break }
                let model = org.agents.first { $0.companyRole == turn.role }?.voiceModel ?? "en_US-ryan-medium"
                await voice.speak(turn.text, seedFrom: turn.role, voice: model,
                                  relay: runtime.relayConfiguration)
            }
            speaking = false
        }
    }
}
