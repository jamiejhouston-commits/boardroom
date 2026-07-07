import SwiftUI

/// A voice call with an agent. Hold to talk; your speech is transcribed,
/// answered through the relay, and spoken back in the agent's own voice
/// while its live 3D office fills the screen.
struct AgentCallView: View {
    let agent: OrgAgent
    @EnvironmentObject private var runtime: HermesRuntimeController
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var hub: MeetingHub
    @EnvironmentObject private var company: CompanyStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var call = CallModel()
    @State private var elapsed = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The agent, live in its office.
            AgentRoomSceneView(agent: agent)
                .ignoresSafeArea()

            LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.05), .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header — who you're talking to + call timer.
                VStack(spacing: 4) {
                    Text(agent.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.top, 24)

                Spacer()

                // Live state + last exchange.
                VStack(spacing: 10) {
                    stateBadge
                    if !call.lastUserLine.isEmpty {
                        Text("You: \(call.lastUserLine)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    if !call.lastAgentLine.isEmpty {
                        Text(call.lastAgentLine)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(4)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(.horizontal, 24)
                .animation(.easeOut(duration: 0.2), value: call.state)

                Spacer()

                // Controls: mute · hold-to-talk · end.
                HStack(spacing: 44) {
                    Button {
                        call.voiceOn.toggle()
                    } label: {
                        Image(systemName: call.voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(.white.opacity(0.14), in: Circle())
                    }

                    talkButton

                    Button {
                        call.hangUp()
                        dismiss()
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(.red, in: Circle())
                    }
                }
                .padding(.bottom, 46)
            }
        }
        .statusBarHidden()
        .keepScreenAwake()
        .onAppear {
            call.connect(agent: agent, relay: runtime.relayConfiguration,
                         context: CompanyContext.brief(org: org, hub: hub, company: company))
            RobotCommand.send(.wave, to: agent.id)   // it greets you
        }
        .onDisappear { call.hangUp() }
        .onReceive(ticker) { _ in elapsed += 1 }
    }

    private var accent: Color { Color(hex: agent.accentHex) }

    @ViewBuilder
    private var stateBadge: some View {
        switch call.state {
        case .idle:
            Label("Hold the button and speak", systemImage: "hand.tap.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
        case .listening:
            Label("Listening…", systemImage: "waveform")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .thinking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("\(agent.name) is thinking…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        case .speaking:
            Label("\(agent.name) is speaking", systemImage: "speaker.wave.3.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(accent)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .error(let why):
            Text(why)
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        }
    }

    private var talkButton: some View {
        let active = call.state == .listening
        return Circle()
            .fill(active ? Color.red : accent)
            .frame(width: 84, height: 84)
            .overlay(
                Image(systemName: "mic.fill")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
            )
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: active ? 4 : 1.5))
            .scaleEffect(active ? 1.12 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: active)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in call.beginTalking() }
                    .onEnded { _ in call.endTalking() }
            )
    }
}

// MARK: - Call session model

@MainActor
private final class CallModel: ObservableObject {
    enum CallState: Equatable {
        case idle, listening, thinking, speaking
        case error(String)
    }

    @Published private(set) var state: CallState = .idle
    @Published private(set) var lastUserLine = ""
    @Published private(set) var lastAgentLine = ""
    @Published var voiceOn = true

    private let recorder = VoiceNoteRecorder()
    private let voice = AgentVoice()
    private var agent: OrgAgent?
    private var relay: HermesRelayConfiguration?
    private var turnTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var context = ""

    func connect(agent: OrgAgent, relay: HermesRelayConfiguration, context: String = "") {
        self.agent = agent
        self.relay = relay
        self.context = context
        if !relay.isConfigured {
            state = .error("Connect your relay first (Settings → Mac Relay).")
        }
    }

    func beginTalking() {
        // .error is recoverable — the next hold always works.
        switch state {
        case .idle, .speaking, .error: break
        default: return
        }
        voice.stop()                       // barge-in: talking interrupts it
        state = .listening
        recordingTask = Task { await recorder.beginRecording() }
    }

    func endTalking() {
        guard state == .listening else { return }
        state = .thinking
        turnTask = Task { [weak self] in
            // Don't ask for the transcript before the recorder has started.
            await self?.recordingTask?.value
            await self?.completeTurn()
        }
    }

    func hangUp() {
        turnTask?.cancel()
        recordingTask?.cancel()
        voice.stop()
        recorder.cancelRecording()
        state = .idle   // never leave the call stuck on "thinking…"
    }

    private func completeTurn() async {
        guard !Task.isCancelled else { state = .idle; return }
        guard let agent, let relay else { return }
        guard let transcript = await recorder.finishRecordingAndTranscribe(),
              !transcript.isEmpty else {
            // Recoverable — the next hold starts fresh.
            state = .error("Didn't catch that — hold the button while you speak, release when done.")
            return
        }
        lastUserLine = transcript

        var config = relay
        let routing = agent.chatRouting   // same brain as chat + the company
        config.profile = routing.profile
        let persona = agent.soul.isEmpty ? agent.summary : agent.soul
        let ctx = context.isEmpty ? "" : context + "\n\n"
        let payload = ctx + "You are \(agent.name) in a multi-agent company, ON A VOICE CALL with the owner. Your remit: \(persona)\n\nThe owner just said: \"\(transcript)\"\n\nReply as \(agent.name) in natural spoken style — 1–3 sentences, under 50 words, no markdown, no lists."

        let reply: String
        do {
            // Same session as 1:1 chat AND the autonomous company.
            // fast: true = single model turn on the relay (~half the latency).
            reply = try await HermesRelayClient(configuration: config)
                .collect(payload, sessionKey: routing.session, fast: true, skills: agent.skills)
        } catch {
            voice.stop()
            state = .error(error.localizedDescription)
            return
        }
        if Task.isCancelled { return }

        guard reply != HermesRelayClient.noResponseFallback else {
            // Empty relay reply on a VOICE call — never leave the owner with a
            // silent "…". Give a visible + audible cue; .error is recoverable
            // (holding the mic starts the next turn).
            lastAgentLine = "No reply came back — hold the mic and try again."
            state = .error("No reply came back — hold the mic and try again.")
            if voiceOn {
                await voice.speak("Sorry, I didn't catch that. Please try again.",
                                  seedFrom: agent.id, voice: agent.voiceModel, relay: config)
            }
            return
        }
        lastAgentLine = reply

        // Speak the whole reply in the agent's own neural voice (relay TTS),
        // falling back to the on-device voice if the relay can't render it.
        if voiceOn {
            state = .speaking
            await voice.speak(reply, seedFrom: agent.id, voice: agent.voiceModel, relay: config)
        }
        if state != .listening { state = .idle }
    }
}
