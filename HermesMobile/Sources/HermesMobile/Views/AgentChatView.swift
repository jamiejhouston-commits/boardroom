import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Shared chat UI

/// One message row. System notes are centered pills; user/agent messages are
/// avatar + bubble, on the muted Hermes palette.
struct ChatBubble: View {
    let message: ChatMessage
    var speaker: String
    var accentHex: String

    private var accent: Color { Color(hex: message.accentHex ?? accentHex) }

    var body: some View {
        switch message.author {
        case .system:
            HStack {
                Spacer(minLength: 0)
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(HermesTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(HermesTheme.hairline, lineWidth: 1))
                Spacer(minLength: 0)
            }
        case .user:
            HStack(alignment: .bottom) {
                Spacer(minLength: 44)
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        attachmentView(attachment)
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.body)
                            .foregroundStyle(HermesTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(HermesTheme.emerald.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(HermesTheme.emerald.opacity(0.30), lineWidth: 1))
                    }
                }
            }
        case .hermes:
            HStack(alignment: .top, spacing: 9) {
                avatar
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.speaker ?? speaker)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                    Text(message.text.isEmpty ? "…" : message.text)
                        .font(.body)
                        .foregroundStyle(HermesTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(HermesTheme.hairline, lineWidth: 1))
                }
                Spacer(minLength: 36)
            }
        }
    }

    private var avatar: some View {
        Text(initials)
            .font(.caption2.weight(.bold))
            .foregroundStyle(accent)
            .frame(width: 30, height: 30)
            .background(accent.opacity(0.14), in: Circle())
            .overlay(Circle().strokeBorder(accent.opacity(0.30), lineWidth: 1))
    }

    @ViewBuilder
    private func attachmentView(_ attachment: ChatAttachment) -> some View {
        if attachment.kind == .image, let image = UIImage(data: attachment.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HermesTheme.hairline, lineWidth: 1))
        } else {
            HStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .font(.subheadline)
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HermesTheme.textPrimary)
                        .lineLimit(1)
                    Text("\(max(1, attachment.data.count / 1024)) KB")
                        .font(.caption2)
                        .foregroundStyle(HermesTheme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(HermesTheme.hairline, lineWidth: 1))
        }
    }

    private var initials: String {
        let words = (message.speaker ?? speaker).split(separator: " ")
        let letters = words.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }
}

/// The shared chat composer: text, voice notes, photo & file attachments,
/// and an always-available keyboard-dismiss control.
///
/// Note: NO `submitLabel(.send)`/`onSubmit` on the multiline field — that
/// combination with dictation is a known UIKit crasher; return = newline,
/// sending is the arrow button.
struct ChatComposer: View {
    @Binding var draft: String
    @FocusState.Binding var focused: Bool
    var disabled: Bool
    var placeholder: String
    var accent: Color = HermesTheme.emerald
    /// Called with the attachments staged for this message.
    var send: ([ChatAttachment]) -> Void

    @StateObject private var voice = VoiceNoteRecorder()
    @State private var pending: [ChatAttachment] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoSelection: [PhotosPickerItem] = []

    /// The real Hermes slash commands (from `hermes chat` /help). They already
    /// work when typed — this just surfaces them with an autocomplete menu.
    private static let slashCommands: [(name: String, hint: String, takesArg: Bool)] = [
        ("/help",     "Show commands",            false),
        ("/new",      "Start a fresh session",    false),
        ("/reset",    "Fresh session",            false),
        ("/model",    "Change the model",         false),
        ("/tools",    "Manage available tools",   false),
        ("/skills",   "Search / install skills",  false),
        ("/skill",    "Load a skill by name",     true),
        ("/memory",   "Memory status & config",   false),
        ("/cron",     "Manage scheduled jobs",    false),
        ("/agents",   "Active agents & tasks",    false),
        ("/stop",     "Stop background processes", false),
        ("/undo",     "Remove the last exchange", false),
        ("/retry",    "Retry the last response",  false),
        ("/compress", "Compress the context",     false)
    ]

    /// Matching commands while the draft is a single "/token" (no space yet).
    private var slashMatches: [(name: String, hint: String, takesArg: Bool)] {
        guard draft.hasPrefix("/"), !draft.contains(" ") else { return [] }
        let query = draft.lowercased()
        return Self.slashCommands.filter { query == "/" || $0.name.hasPrefix(query) }
    }

    var body: some View {
        VStack(spacing: 7) {
            if let status = voice.state.status {
                HStack(spacing: 7) {
                    Image(systemName: statusIcon).font(.caption2.weight(.bold))
                    Text(status).font(.caption2.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(statusColor)
                .padding(.horizontal, 6)
            }

            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pending) { attachment in
                            pendingChip(attachment)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            // Slash-command autocomplete — appears as you type "/".
            if focused && !slashMatches.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(slashMatches, id: \.name) { command in
                            Button {
                                draft = command.takesArg ? command.name + " " : command.name
                            } label: {
                                HStack(spacing: 8) {
                                    Text(command.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(accent)
                                    Text(command.hint)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if command.name != slashMatches.last?.name { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 230)
                .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(HermesTheme.hairline, lineWidth: 1))
                .padding(.horizontal, 4)
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Attach photos / files / slash commands.
                Menu {
                    Button { showPhotoPicker = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    Button { showFileImporter = true } label: { Label("Choose File", systemImage: "folder") }
                    Divider()
                    Button { draft = "/"; focused = true } label: { Label("Slash commands", systemImage: "command") }
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accent)
                        .frame(width: 36, height: 36)
                        .background(accent.opacity(0.12), in: Circle())
                }
                .disabled(disabled)
                .accessibilityLabel("Add attachment")

                Button(action: micTapped) {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isRecording ? Color.red : accent)
                        .frame(width: 36, height: 36)
                        .background((isRecording ? Color.red : accent).opacity(0.12), in: Circle())
                }
                .disabled(disabled || isTranscribing)
                .accessibilityLabel(isRecording ? "Stop recording" : "Record voice note")

                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .strokeBorder(focused ? accent.opacity(0.55) : HermesTheme.hairline, lineWidth: focused ? 1.5 : 1)
                    )
                    .animation(.easeOut(duration: 0.18), value: focused)
                    .disabled(isRecording || isTranscribing)

                if focused {
                    // Explicit, always-works keyboard dismissal.
                    Button { focused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(HermesTheme.textSecondary)
                            .frame(width: 34, height: 34)
                    }
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Hide keyboard")
                }

                Button(action: sendTapped) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(canSend ? accent : HermesTheme.textSecondary.opacity(0.4))
                        .scaleEffect(canSend ? 1.0 : 0.88)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: canSend)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            .animation(.easeOut(duration: 0.18), value: focused)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelection, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { loadFiles(urls) }
        }
    }

    private func pendingChip(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 6) {
            if attachment.kind == .image, let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: "doc.fill")
                    .font(.caption)
                    .foregroundStyle(accent)
            }
            Text(attachment.filename)
                .font(.caption2.weight(.medium))
                .foregroundStyle(HermesTheme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: 110, alignment: .leading)
            Button {
                pending.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(HermesTheme.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(HermesTheme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(HermesTheme.hairline, lineWidth: 1))
    }

    /// Haptic tick + hand the staged attachments to the chat.
    private func sendTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        send(pending)
        pending = []
    }

    private var isRecording: Bool { voice.state == .recording }
    private var isTranscribing: Bool { voice.state == .transcribing }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty)
            && !disabled && !isRecording && !isTranscribing
    }

    private var statusIcon: String {
        switch voice.state {
        case .recording: "waveform"
        case .transcribing: "text.bubble"
        default: "exclamationmark.circle"
        }
    }

    private var statusColor: Color {
        switch voice.state {
        case .recording: .red
        case .transcribing: accent
        default: .orange
        }
    }

    private func micTapped() {
        focused = false
        Task {
            if isRecording {
                if let transcript = await voice.finishRecordingAndTranscribe(), !transcript.isEmpty {
                    draft = draft.isEmpty ? transcript : draft + " " + transcript
                }
            } else {
                await voice.beginRecording()
            }
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let name = "photo-\(pending.count + 1).jpg"
                pending.append(ChatAttachment(kind: .image, filename: name, data: data))
            }
        }
        photoSelection = []
    }

    private func loadFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count <= 5_000_000 else { continue }

            var text: String? = nil
            if data.count <= 250_000, let s = String(data: data, encoding: .utf8) {
                text = String(s.prefix(12_000))
            }
            pending.append(ChatAttachment(kind: .file, filename: url.lastPathComponent, data: data, textContent: text))
        }
    }
}

// MARK: - 1:1 conversation with a single agent

@MainActor
final class AgentConversation: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isSending = false

    let agent: OrgAgent
    private var introSent = false

    init(agent: OrgAgent) {
        self.agent = agent
        // Resume where the relay-side session already is — history survives
        // closing the view, and the persona intro is only ever sent once.
        if let saved = ChatArchive.load(key: agent.chatRouting.session) {
            messages = saved.messages
            introSent = saved.introSent
        } else {
            messages = [ChatMessage(author: .system,
                                    text: "Direct line to \(agent.name).",
                                    date: Date())]
        }
    }

    private func persist() {
        ChatArchive.save(key: agent.chatRouting.session, messages: messages, introSent: introSent)
    }

    func send(_ text: String, attachments: [ChatAttachment] = [], relay base: HermesRelayConfiguration, context: String = "") {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !attachments.isEmpty { trimmed = "Please review the attached." }
        guard !trimmed.isEmpty, !isSending else { return }
        var userMessage = ChatMessage(author: .user, text: text.trimmingCharacters(in: .whitespacesAndNewlines), date: Date())
        userMessage.attachments = attachments
        messages.append(userMessage)

        // Physical orders: the robot in the room above obeys immediately.
        if let command = RobotCommand.parse(trimmed) {
            RobotCommand.send(command, to: agent.id)
        }

        guard base.isConfigured else {
            messages.append(ChatMessage(author: .system, text: "Connect your relay first (Settings → Mac Relay).", date: Date()))
            return
        }

        var config = base
        let routing = agent.chatRouting   // CEO/leads share the company's brain
        config.profile = routing.profile

        let body = trimmed + attachments.payloadSuffix
        let persona = agent.soul.isEmpty ? agent.summary : agent.soul
        // Shared company knowledge prepended every turn so the agent always
        // knows the org, your memos, scheduled meetings, and active work.
        let ctx = context.isEmpty ? "" : context + "\n\n"
        let payload: String
        if introSent {
            payload = ctx + body
        } else {
            introSent = true
            payload = ctx + "You are the \(agent.name) in a multi-agent company. Your remit: \(persona) Answer in that role.\n\n\(body)"
        }

        isSending = true
        let responseID = UUID()
        messages.append(ChatMessage(id: responseID, author: .hermes, text: "", date: Date()))
        let session = routing.session

        Task {
            do {
                // fast: false — TEXT chat runs the FULL agent loop (fast caps
                // the CLI at 2 turns, which truncates tool-using replies).
                let reply = try await HermesRelayClient(configuration: config)
                    .collect(payload, sessionKey: session, fast: false, skills: agent.skills) { [weak self] text in
                        self?.setText(responseID, text)
                    }
                setText(responseID, reply)
            } catch {
                // The placeholder bubble never received a delta — drop it so it
                // doesn't linger forever as a dead "…". (Partial replies kept.)
                if currentText(responseID).isEmpty,
                   let idx = messages.firstIndex(where: { $0.id == responseID }) {
                    messages.remove(at: idx)
                }
                messages.append(ChatMessage(author: .system, text: error.localizedDescription, date: Date()))
            }
            isSending = false
            persist()
        }
    }

    private func setText(_ id: UUID, _ text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    private func currentText(_ id: UUID) -> String {
        messages.first { $0.id == id }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct AgentChatView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var hub: MeetingHub
    @EnvironmentObject private var company: CompanyStore
    @StateObject private var convo: AgentConversation
    @State private var draft = ""
    @FocusState private var focused: Bool

    init(agent: OrgAgent) {
        _convo = StateObject(wrappedValue: AgentConversation(agent: agent))
    }

    var body: some View {
        VStack(spacing: 0) {
            // The agent's live 3D office — it obeys chat orders
            // ("get up and walk around the office", "dance", "wave"…).
            // Collapses while typing so the conversation keeps the space.
            AgentRoomSceneView(agent: convo.agent, paused: focused)
                .frame(height: focused ? 0 : 215)
                .clipped()
                .animation(.easeInOut(duration: 0.28), value: focused)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(convo.messages) { message in
                            ChatBubble(message: message, speaker: convo.agent.name, accentHex: convo.agent.accentHex)
                        }
                        if convo.isSending {
                            TypingIndicator(name: convo.agent.name, accent: Color(hex: convo.agent.accentHex))
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture { focused = false }     // tap anywhere → keyboard drops
                .background(HermesTheme.background)
                .onChange(of: convo.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
                .onChange(of: focused) { _, isUp in
                    if isUp {
                        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
            }

            ChatComposer(draft: $draft, focused: $focused, disabled: convo.isSending,
                         placeholder: "Message \(convo.agent.name)",
                         accent: Color(hex: convo.agent.accentHex)) { attachments in
                convo.send(draft, attachments: attachments, relay: runtime.relayConfiguration,
                           context: CompanyContext.brief(org: org, hub: hub, company: company))
                draft = ""
            }
        }
        .background(HermesTheme.background)
        .navigationTitle(convo.agent.name)
        .navigationBarTitleDisplayMode(.inline)
        // No keyboard "Done" toolbar: iOS 18 renders it as a floating pill
        // that covers the send button. The composer has its own dismiss
        // control, plus tap-anywhere and scroll both drop the keyboard.
    }

    private static let bottomID = "chat-bottom"
}

/// "… is working" row with a small animated emphasis.
struct TypingIndicator: View {
    var name: String
    var accent: Color
    @State private var on = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(accent).frame(width: 7, height: 7).opacity(on ? 1 : 0.3)
            Text("\(name) is working…")
                .font(.caption)
                .foregroundStyle(HermesTheme.textSecondary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
        }
    }
}
