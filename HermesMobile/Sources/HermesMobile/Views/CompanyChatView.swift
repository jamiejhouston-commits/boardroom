import SwiftUI

// MARK: - Company / team chat with CEO routing

@MainActor
final class CompanyConversation: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isSending = false
    private var introSent = Set<String>()

    init() {
        messages = [ChatMessage(
            author: .system,
            text: "Company chat. Address a department — \"CFO, what's our runway?\" — and that agent answers. No name, and the CEO routes it.",
            date: Date()
        )]
    }

    func send(_ text: String, attachments: [ChatAttachment] = [], relay base: HermesRelayConfiguration, org: [OrgAgent]) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !attachments.isEmpty { trimmed = "Please review the attached." }
        guard !trimmed.isEmpty, !isSending else { return }
        var userMessage = ChatMessage(author: .user, text: text.trimmingCharacters(in: .whitespacesAndNewlines), date: Date())
        userMessage.attachments = attachments
        messages.append(userMessage)

        guard base.isConfigured else {
            messages.append(ChatMessage(author: .system, text: "Connect your relay first (Settings → Mac Relay).", date: Date()))
            return
        }

        guard let target = Self.resolveTarget(trimmed, org: org) else {
            messages.append(ChatMessage(author: .system, text: "Your org has no agents yet — add some in the Agents tab.", date: Date()))
            return
        }
        var config = base
        config.profile = target.profileSlug

        let body = trimmed + attachments.payloadSuffix
        let persona = target.soul.isEmpty ? target.summary : target.soul
        let payload: String
        if introSent.contains(target.id) {
            payload = body
        } else {
            introSent.insert(target.id)
            payload = "You are the \(target.name) in a multi-agent company. Your remit: \(persona) Answer in that role.\n\n\(body)"
        }

        isSending = true
        let responseID = UUID()
        var reply = ChatMessage(id: responseID, author: .hermes, text: "", date: Date())
        reply.speaker = target.name
        reply.accentHex = target.accentHex
        messages.append(reply)
        let session = "hermes-mobile-company-\(target.id)"

        Task {
            do {
                for try await event in HermesRelayClient(configuration: config).stream(payload, sessionKey: session, fast: true) {
                    switch event.type {
                    case .start: break
                    case .delta: appendTo(responseID, event.text ?? "")
                    case .done:
                        if let r = event.reply, currentText(responseID).isEmpty { appendTo(responseID, r) }
                    case .error:
                        throw HermesRelayError.server(event.message ?? "Hermes stream failed.")
                    }
                }
                if currentText(responseID).isEmpty { appendTo(responseID, "(no response)") }
            } catch {
                messages.append(ChatMessage(author: .system, text: error.localizedDescription, date: Date()))
            }
            isSending = false
        }
    }

    /// Pick the department head the message addresses; default to the CEO (who routes).
    /// Pick the agent the message addresses; default to the CEO (who routes). Works for any custom org.
    static func resolveTarget(_ text: String, org: [OrgAgent]) -> OrgAgent? {
        guard !org.isEmpty else { return nil }
        let lower = text.lowercased()
        for agent in org where agent.tier != .ceo {
            if routingKeys(agent).contains(where: { lower.contains($0) }) {
                return agent
            }
        }
        return org.first { $0.tier == .ceo } ?? org.first
    }

    /// Address-keywords derived from an agent's name + role label (so custom agents route too).
    static func routingKeys(_ agent: OrgAgent) -> [String] {
        var keys = Set<String>()
        keys.insert(agent.id.lowercased())
        let words = (agent.name + " " + agent.title).lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        for word in words where word.count > 2 && word != "agent" && word != "the" {
            keys.insert(word)
        }
        return Array(keys)
    }

    private func appendTo(_ id: UUID, _ text: String) {
        guard !text.isEmpty, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += text
    }

    private func currentText(_ id: UUID) -> String {
        messages.first { $0.id == id }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct CompanyChatView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController
    @EnvironmentObject private var org: OrgStore
    @StateObject private var convo = CompanyConversation()
    @State private var draft = ""
    @FocusState private var focused: Bool

    private static let bottomID = "company-bottom"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(convo.messages) { message in
                                ChatBubble(message: message, speaker: "Hermes", accentHex: "C7A35A")
                            }
                            if convo.isSending {
                                TypingIndicator(name: "Hermes", accent: HermesTheme.emerald)
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
                             placeholder: "Message the company — try “CFO, …”") { attachments in
                    convo.send(draft, attachments: attachments, relay: runtime.relayConfiguration, org: org.leadership)
                    draft = ""
                }
            }
            .background(HermesTheme.background)
            .navigationTitle("Company")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
