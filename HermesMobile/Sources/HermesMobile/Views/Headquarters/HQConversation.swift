import SwiftUI
import simd

/// Talk to an agent right where they stand on the HQ floor — no teleporting to
/// a separate chat screen. Replies stream into a comic-style speech bubble;
/// holding the mic turns the same conversation into a voice exchange (Apple
/// on-device STT in, the agent's own Piper voice out). Rides the agent's
/// normal `chatRouting` session, so the in-room conversation and the classic
/// chat are ONE memory, not two.

// MARK: - Model

@MainActor
final class HQConversationModel: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        let fromUser: Bool
        var text: String
    }

    enum Phase: Equatable {
        case idle
        case streaming     // reply arriving
        case listening     // mic held
        case transcribing  // hold released, STT running
        case speaking      // TTS playing
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var errorText: String?

    let agent: OrgAgent
    private var introSent = false
    private let recorder = VoiceNoteRecorder()
    private let voice = AgentVoice()
    private var streamTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?

    init(agent: OrgAgent) {
        self.agent = agent
    }

    var latestAgentLine: Line? { lines.last(where: { !$0.fromUser }) }
    var latestUserLine: Line? { lines.last(where: { $0.fromUser }) }

    // MARK: Typed turn

    func send(_ text: String, relay base: HermesRelayConfiguration, context: String,
              spoken: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .idle || phase == .speaking else { return }
        voice.stop()                                     // barge-in on our own TTS
        errorText = nil
        guard base.isConfigured else {
            errorText = "Connect your relay first (Settings → Mac Relay)."
            return
        }

        lines.append(Line(fromUser: true, text: trimmed))
        let replyID = appendAgentPlaceholder()

        var config = base
        let routing = agent.chatRouting                  // same brain as chat + company
        config.profile = routing.profile
        let persona = agent.soul.isEmpty ? agent.summary : agent.soul
        let ctx = context.isEmpty ? "" : context + "\n\n"
        let style = spoken
            ? "You are \(agent.name), talking FACE TO FACE with the owner on the headquarters floor. Reply in natural spoken style — 1–3 sentences, under 60 words, no markdown."
            : "You are \(agent.name), talking face to face with the owner on the headquarters floor. Keep replies tight and conversational — a few sentences, no markdown headers."
        let payload: String
        if introSent {
            payload = ctx + (spoken ? style + "\n\nThe owner said: \"\(trimmed)\"" : trimmed)
        } else {
            introSent = true
            payload = ctx + style + " Your remit: \(persona)\n\n\(trimmed)"
        }

        phase = .streaming
        let wantsVoiceReply = spoken
        streamTask = Task { [weak self] in
            guard let self else { return }
            var collected = ""
            do {
                // Voice turns use fast:true (single model turn — call latency);
                // typed turns run the full agent loop like AgentChatView.
                for try await event in HermesRelayClient(configuration: config)
                    .stream(payload, sessionKey: routing.session, fast: wantsVoiceReply,
                            skills: agent.skills) {
                    if Task.isCancelled { return }
                    switch event.type {
                    case .start: break
                    case .delta:
                        collected += event.text ?? ""
                        self.setText(collected, for: replyID)
                    case .done:
                        if collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let reply = event.reply {
                            collected = reply
                            self.setText(collected, for: replyID)
                        }
                    case .error:
                        throw HermesRelayError.server(event.message ?? "Stream failed.")
                    }
                }
            } catch {
                self.dropIfEmpty(replyID)
                self.errorText = error.localizedDescription
                self.phase = .idle
                return
            }
            let reply = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            if reply.isEmpty {
                self.setText("(no response — try again)", for: replyID)
                self.phase = .idle
                return
            }
            if wantsVoiceReply {
                self.phase = .speaking
                await self.voice.speak(reply, seedFrom: self.agent.id,
                                       voice: self.agent.voiceModel, relay: config)
            }
            if self.phase != .listening { self.phase = .idle }
        }
    }

    // MARK: Voice turn (hold to talk)

    func beginHold() {
        switch phase {
        case .idle, .speaking: break
        default: return
        }
        voice.stop()                                     // talking interrupts the agent
        errorText = nil
        phase = .listening
        recordingTask = Task { await recorder.beginRecording() }
    }

    func endHold(relay: HermesRelayConfiguration, context: String) {
        guard phase == .listening else { return }
        phase = .transcribing
        Task { [weak self] in
            guard let self else { return }
            await self.recordingTask?.value              // recorder must have started
            guard let transcript = await self.recorder.finishRecordingAndTranscribe(),
                  !transcript.isEmpty else {
                self.errorText = "Didn't catch that — hold the mic while you speak."
                self.phase = .idle
                return
            }
            self.phase = .idle
            self.send(transcript, relay: relay, context: context, spoken: true)
        }
    }

    /// Full teardown — call when the overlay closes or the HQ is dismissed.
    func stop() {
        streamTask?.cancel()
        recordingTask?.cancel()
        voice.stop()
        recorder.cancelRecording()
        phase = .idle
    }

    // MARK: Line bookkeeping

    private func appendAgentPlaceholder() -> UUID {
        let line = Line(fromUser: false, text: "")
        lines.append(line)
        return line.id
    }

    private func setText(_ text: String, for id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].text = text
    }

    private func dropIfEmpty(_ id: UUID) {
        if let index = lines.firstIndex(where: { $0.id == id }),
           lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.remove(at: index)
        }
    }
}

// MARK: - Overlay (the bubble + input bar)

struct HQConversationOverlay: View {
    @ObservedObject var model: HQConversationModel
    var status: HQAgentStatus
    var relay: HermesRelayConfiguration
    var contextProvider: @MainActor () -> String   // CompanyContext.brief is MainActor
    var onFullChat: () -> Void
    var onClose: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            bubbleColumn
                .padding(.top, 64)
            Spacer(minLength: 0)
            inputBar
        }
    }

    // MARK: Speech bubble

    private var bubbleColumn: some View {
        VStack(spacing: 10) {
            header
            if let line = model.latestAgentLine, !line.text.isEmpty || model.phase == .streaming {
                bubble(text: line.text.isEmpty ? "…" : line.text)
            } else if model.phase == .listening {
                bubble(text: "👂 Listening…")
            } else if let error = model.errorText {
                bubble(text: error)
            } else {
                bubble(text: "You're face to face with \(model.agent.name). Say something.")
            }
            if let user = model.latestUserLine {
                Text(user.text)
                    .font(.footnote)
                    .foregroundStyle(HermesTheme.textPrimary.opacity(0.9))
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(HermesTheme.emerald.opacity(0.22), in: Capsule())
                    .overlay(Capsule().strokeBorder(HermesTheme.emerald.opacity(0.4), lineWidth: 1))
            }
        }
        .frame(maxWidth: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.agent.systemImage)
                .font(.caption)
                .foregroundStyle(Color(hex: model.agent.accentHex))
            Text(model.agent.name)
                .font(.caption.weight(.bold))
                .foregroundStyle(HermesTheme.textPrimary)
            Text(status.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            phaseBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch model.phase {
        case .streaming:
            ProgressView().controlSize(.mini)
        case .speaking:
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption2)
                .foregroundStyle(HermesTheme.emerald)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .listening:
            Image(systemName: "waveform")
                .font(.caption2)
                .foregroundStyle(HermesTheme.gold)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .transcribing:
            Image(systemName: "ellipsis")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }

    private func bubble(text: String) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(HermesTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .id("tail")
                }
                .onChange(of: text) {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("tail", anchor: .bottom) }
                }
            }
            .frame(maxHeight: 190)
            .fixedSize(horizontal: false, vertical: true)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(HermesTheme.hairline, lineWidth: 1))

            // The comic tail, pointing down at the agent framed by the camera.
            BubbleTail()
                .fill(.ultraThinMaterial)
                .frame(width: 26, height: 14)
                .overlay(BubbleTail().stroke(HermesTheme.hairline, lineWidth: 1))
                .offset(y: -1)
        }
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            Button(action: { model.stop(); onClose() }) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(HermesTheme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            TextField("Say something…", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(HermesTheme.hairline, lineWidth: 1))

            if draft.trimmingCharacters(in: .whitespaces).isEmpty {
                micButton
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(HermesTheme.emerald, in: Circle())
                }
                .buttonStyle(.plain)
            }

            Button(action: onFullChat) {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HermesTheme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Hold to talk; release to send. The classic call interaction, in-room.
    private var micButton: some View {
        Image(systemName: model.phase == .listening ? "mic.fill" : "mic")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(model.phase == .listening ? .white : HermesTheme.textPrimary)
            .frame(width: 40, height: 40)
            .background(model.phase == .listening ? AnyShapeStyle(HermesTheme.gold)
                                                  : AnyShapeStyle(.ultraThinMaterial),
                        in: Circle())
            .scaleEffect(model.phase == .listening ? 1.15 : 1)
            .animation(.spring(duration: 0.25), value: model.phase)
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 60) {
                // never fires — we only care about press state changes
            } onPressingChanged: { pressing in
                if pressing {
                    model.beginHold()
                } else {
                    model.endHold(relay: relay, context: contextProvider())
                }
            }
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        focused = false
        model.send(text, relay: relay, context: contextProvider(), spoken: false)
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Virtual joystick (roam mode)

/// A classic left-thumb stick: drag inside the base to walk, release to stop.
/// Writes straight into `HQRoamControl`; the SceneKit render loop consumes it.
struct HQJoystick: View {
    let control: HQRoamControl
    @State private var thumb: CGSize = .zero

    private let baseSize: CGFloat = 112
    private let thumbSize: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(HermesTheme.hairline, lineWidth: 1))
            Circle()
                .fill(HermesTheme.emerald.opacity(0.85))
                .frame(width: thumbSize, height: thumbSize)
                .offset(thumb)
                .shadow(radius: 3, y: 1)
            Image(systemName: "figure.walk")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))
                .offset(thumb)
        }
        .frame(width: baseSize, height: baseSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let radius = (baseSize - thumbSize) / 2
                    var dx = value.translation.width
                    var dy = value.translation.height
                    let len = sqrt(dx * dx + dy * dy)
                    if len > radius { dx = dx / len * radius; dy = dy / len * radius }
                    thumb = CGSize(width: dx, height: dy)
                    // +y on screen is down; +y on the stick is forward.
                    control.setStick(SIMD2(Float(dx / radius), Float(-dy / radius)))
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.2)) { thumb = .zero }
                    control.setStick(.zero)
                }
        )
    }
}
