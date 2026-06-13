import SwiftUI

/// Live boardroom debate: drop a topic, watch the leadership argue it out —
/// round-robin, reacting to each other, each with its own voice — then the
/// Secretary files the minutes into Memos.
struct DebateView: View {
    let attendees: [OrgAgent]
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var hub: MeetingHub
    @EnvironmentObject private var runtime: HermesRuntimeController
    @Environment(\.dismiss) private var dismiss

    @StateObject private var engine = DebateEngine()
    @State private var topic = ""
    @State private var rounds = 2

    var body: some View {
        NavigationStack {
            ZStack {
                HermesTheme.background.ignoresSafeArea()
                switch engine.state {
                case .idle:
                    setup
                default:
                    live
                }
            }
            .keepScreenAwake()
            .navigationTitle("Boardroom Debate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(engine.state == .idle ? "Cancel" : "Close") {
                        engine.stop()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(engine.state != .idle && engine.state != .finished)
    }

    // MARK: Setup stage

    private var setup: some View {
        Form {
            Section("Topic") {
                TextField("e.g. Should we raise prices 20%?", text: $topic, axis: .vertical)
                    .lineLimit(1...3)
            }
            Section {
                Stepper("Rounds: \(rounds)", value: $rounds, in: 1...3)
                Toggle(isOn: $engine.voicesOn) {
                    Label("Spoken voices", systemImage: "speaker.wave.2.fill")
                }
            } footer: {
                Text("\(attendees.count) agents will debate in turn, each responding to what's been said — \(attendees.count * rounds) contributions total. The Secretary files the minutes to Memos afterwards.")
            }
            Section("In the room") {
                ForEach(attendees) { agent in
                    Label(agent.name, systemImage: agent.systemImage)
                        .foregroundStyle(Color(hex: agent.accentHex))
                }
            }
            Section {
                Button {
                    engine.start(topic: topic.trimmingCharacters(in: .whitespaces),
                                 rounds: rounds, attendees: attendees,
                                 relay: runtime.relayConfiguration, org: org, hub: hub)
                } label: {
                    Label("Start the debate", systemImage: "person.wave.2.fill")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty)
                .listRowBackground(HermesTheme.emerald.opacity(0.18))
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Live stage

    private var live: some View {
        VStack(spacing: 0) {
            statusBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(engine.turns) { turn in
                            turnBubble(turn)
                        }
                        if let speakerID = engine.currentSpeakerID,
                           let agent = org.agent(id: speakerID) {
                            HStack(spacing: 8) {
                                Image(systemName: "waveform")
                                    .foregroundStyle(Color(hex: agent.accentHex))
                                    .symbolEffect(.variableColor.iterative, options: .repeating)
                                Text("\(agent.name) is speaking…")
                                    .font(.caption)
                                    .foregroundStyle(HermesTheme.textSecondary)
                            }
                        }
                        if case .concluding = engine.state {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("The Secretary is writing the minutes…")
                                    .font(.caption)
                                    .foregroundStyle(HermesTheme.textSecondary)
                            }
                        }
                        if case .failed(let why) = engine.state {
                            Text(why).font(.caption).foregroundStyle(.orange)
                        }
                        Color.clear.frame(height: 1).id("debate-bottom")
                    }
                    .padding()
                }
                .onChange(of: engine.turns.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("debate-bottom", anchor: .bottom)
                    }
                }
            }

            if case .finished = engine.state {
                VStack(spacing: 10) {
                    Label("Minutes filed to Memos", systemImage: "tray.full.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HermesTheme.emerald)
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(HermesTheme.emerald)
                }
                .padding()
            } else {
                Button(role: .destructive) {
                    engine.stop()
                } label: {
                    Label("End debate", systemImage: "stop.circle.fill")
                }
                .padding()
            }
        }
    }

    private var statusBar: some View {
        HStack {
            switch engine.state {
            case .running(let round, let total):
                Label("Round \(round) of \(total)", systemImage: "arrow.triangle.2.circlepath")
            case .concluding:
                Label("Concluding", systemImage: "doc.text")
            case .finished:
                Label("Debate finished", systemImage: "checkmark.circle.fill")
            default:
                Label("Debate", systemImage: "person.wave.2.fill")
            }
            Spacer()
            Label("\(attendees.count)", systemImage: "person.3.fill")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(HermesTheme.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(HermesTheme.surface)
    }

    private func turnBubble(_ turn: DebateTurn) -> some View {
        let accent = Color(hex: turn.accentHex)
        let speaking = engine.currentSpeakerID == turn.agentID && engine.turns.last?.id == turn.id
        return HStack(alignment: .top, spacing: 10) {
            Text(initials(turn.agentName))
                .font(.caption2.weight(.bold))
                .foregroundStyle(accent)
                .frame(width: 32, height: 32)
                .background(accent.opacity(0.14), in: Circle())
                .overlay(Circle().strokeBorder(accent.opacity(speaking ? 0.9 : 0.3), lineWidth: speaking ? 2 : 1))

            VStack(alignment: .leading, spacing: 4) {
                Text(turn.agentName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)
                Text(turn.text)
                    .font(.body)
                    .foregroundStyle(HermesTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(speaking ? accent.opacity(0.5) : HermesTheme.hairline, lineWidth: 1))
            }
            Spacer(minLength: 24)
        }
    }

    private func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}
