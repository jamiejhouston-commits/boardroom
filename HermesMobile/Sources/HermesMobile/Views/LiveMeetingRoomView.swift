import SwiftUI

/// THE conference room doing its real job: a live autonomous meeting rendered
/// in the 3D boardroom. The seats are the actual attendees, the speaker halo
/// fires as each real turn lands, the transcript scrolls beneath the scene,
/// and the owner can weigh in by keyboard or by holding the mic. A Live
/// Activity mirrors the current speaker on the lock screen.
struct LiveMeetingRoomView: View {
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var runtime: HermesRuntimeController

    let meetingID: String
    let topic: String

    @State private var meeting: CompanyMeeting?
    @State private var seenTurns = 0
    @State private var draft = ""
    @State private var sending = false
    @State private var showRadio = false
    @State private var actionsRequested = false
    @StateObject private var recorder = VoiceNoteRecorder()
    @FocusState private var focused: Bool

    private let refresh = Timer.publish(every: 6, on: .main, in: .common).autoconnect()
    private static let bottomID = "live-meeting-bottom"

    /// The real people in the room: meeting roles mapped to org agents.
    private var attendees: [OrgAgent] {
        let roles = meeting?.attendees ?? []
        let mapped = roles.compactMap { role in
            org.agents.first { $0.companyRole == role }
        }
        return mapped.isEmpty ? Array(org.leadership.prefix(4)) : mapped
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                MeetingRoomSceneView(attendees: attendees,
                                     stats: RoomStats.from(state: company.state,
                                                           liveTopic: topic))
                HStack(spacing: 8) {
                    Circle()
                        .fill(meeting?.isLive == true ? HermesTheme.emerald : Color.white.opacity(0.3))
                        .frame(width: 7, height: 7)
                    Text(meeting?.isLive == true ? "In session" : "Concluded")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(meeting?.turns?.count ?? 0) turns")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.4))
            }
            .frame(height: focused ? 140 : 300)
            .clipped()
            .animation(.easeInOut(duration: 0.28), value: focused)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(meeting?.turns ?? []) { turn in
                            turnRow(turn)
                        }
                        if (meeting?.turns ?? []).isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("The room is convening…")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if meeting?.isLive == false {
                            concludedFooter
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.immediately)
                .onChange(of: meeting?.turns?.count ?? 0) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
            }

            composer
        }
        .keepScreenAwake()
        .navigationTitle(topic)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showRadio = true } label: {
                    Label("Listen", systemImage: "radio.fill")
                }
                .accessibilityLabel("Meeting radio")
            }
        }
        .sheet(isPresented: $showRadio) {
            if let meeting { MeetingRadioView(meeting: meeting) }
        }
        .task {
            await load()
            if meeting?.isLive == true {
                LiveActivityManager.startDebate(topic: topic)
            }
        }
        .onReceive(refresh) { _ in
            if meeting?.isLive != false || sending { Task { await load() } }
        }
        .onDisappear { LiveActivityManager.endDebate() }
    }

    // MARK: Rows

    private func turnRow(_ turn: CompanyMeetingTurn) -> some View {
        let isOwner = turn.role == "owner"
        let agent = org.agents.first { $0.companyRole == turn.role }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(isOwner ? "YOU" : (agent?.name ?? turn.role).uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isOwner ? HermesTheme.gold : HermesTheme.emerald)
                Spacer()
                Text(turn.ts).font(.caption2).foregroundStyle(.secondary)
            }
            Text(turn.text).font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var concludedFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Meeting concluded — minutes are filed in the vault.",
                  systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                actionsRequested = true
                Task {
                    try? await HermesRelayClient(configuration: runtime.relayConfiguration)
                        .meetingActions(id: meetingID)
                }
            } label: {
                Label(actionsRequested ? "The CEO is distilling action items — they land in your Kanban."
                                       : "Turn this into action items",
                      systemImage: "checklist")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(actionsRequested ? HermesTheme.textSecondary : HermesTheme.emerald)
            }
            .disabled(actionsRequested)
        }
        .padding(.top, 8)
    }

    // MARK: Speak in — typed or held-to-talk

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Weigh in — the team responds…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(HermesTheme.hairline, lineWidth: 1))

            // Hold to talk — release sends your words into the meeting.
            Image(systemName: recorder.state == .recording ? "waveform" : "mic.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(recorder.state == .recording ? .white : HermesTheme.emerald)
                .frame(width: 40, height: 40)
                .background(recorder.state == .recording ? HermesTheme.gold : HermesTheme.surface,
                            in: Circle())
                .overlay(Circle().strokeBorder(HermesTheme.emerald.opacity(0.4), lineWidth: 1))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard recorder.state != .recording else { return }
                            Task { await recorder.beginRecording() }
                        }
                        .onEnded { _ in
                            Task {
                                if let transcript = await recorder.finishRecordingAndTranscribe(),
                                   !transcript.isEmpty {
                                    say(transcript)
                                }
                            }
                        }
                )

            Button {
                say(draft)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
                    .foregroundStyle(canSend ? HermesTheme.emerald : HermesTheme.textSecondary.opacity(0.4))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    private func say(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        focused = false
        sending = true
        Task {
            await company.meetingSay(id: meetingID, text: trimmed,
                                     relay: runtime.relayConfiguration)
            for _ in 0..<15 {           // poll until the team's responses land
                try? await Task.sleep(for: .seconds(6))
                await load()
            }
            sending = false
        }
    }

    private func load() async {
        meeting = await company.meetingDetail(id: meetingID, relay: runtime.relayConfiguration)
        highlightNewSpeaker()
    }

    /// New turn since the last poll → the speaker's seat lights up (halo +
    /// console — the exact machinery the debate already drives) and the lock
    /// screen shows who has the floor.
    private func highlightNewSpeaker() {
        guard let turns = meeting?.turns, turns.count > seenTurns else { return }
        seenTurns = turns.count
        guard let last = turns.last, last.role != "owner" else { return }
        let agent = org.agents.first { $0.companyRole == last.role }
        NotificationCenter.default.post(name: .hermesDebateSpeaker, object: nil,
                                        userInfo: ["agentID": agent?.id ?? ""])
        LiveActivityManager.updateDebate(speaker: agent?.name ?? last.role.uppercased(),
                                         accentHex: agent?.accentHex ?? "1C7A55",
                                         round: turns.count,
                                         totalRounds: max(attendees.count, turns.count))
    }
}

// MARK: - Meetings home: live now, scheduled, history with minutes

struct MeetingsListView: View {
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var hub: MeetingHub
    @EnvironmentObject private var runtime: HermesRuntimeController

    var body: some View {
        List {
            if let live = company.liveMeeting {
                Section("Live now") {
                    NavigationLink {
                        LiveMeetingRoomView(meetingID: live.id, topic: live.topic)
                    } label: {
                        row(icon: "dot.radiowaves.left.and.right", tint: HermesTheme.emerald,
                            title: live.topic, subtitle: "In session — walk in")
                    }
                }
            }

            if !hub.upcoming.isEmpty {
                Section("Scheduled") {
                    ForEach(hub.upcoming) { scheduled in
                        row(icon: "calendar", tint: HermesTheme.gold,
                            title: scheduled.topic,
                            subtitle: scheduled.date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            let history = company.meetings.filter { !$0.isLive }
            if !history.isEmpty {
                Section("History") {
                    ForEach(history) { past in
                        NavigationLink {
                            MeetingTranscriptView(meetingID: past.id, topic: past.topic)
                        } label: {
                            row(icon: "person.2.wave.2", tint: HermesTheme.textSecondary,
                                title: past.topic,
                                subtitle: "\(past.turnCount ?? past.turns?.count ?? 0) turns · \(past.started.prefix(10))")
                        }
                    }
                }
            }

            if company.meetings.isEmpty && hub.upcoming.isEmpty {
                Section {
                    Text("No meetings yet. Your team convenes on its own every ~90 minutes while the company is on — or convene one yourself from the Conference Room.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Meetings")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await company.refresh(relay: runtime.relayConfiguration) }
        .task { await company.refresh(relay: runtime.relayConfiguration) }
    }

    private func row(icon: String, tint: Color, title: String,
                     subtitle: some StringProtocol) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(String(subtitle)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
