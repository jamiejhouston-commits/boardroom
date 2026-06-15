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

    func send(_ text: String, attachments: [ChatAttachment] = [], relay base: HermesRelayConfiguration, org: [OrgAgent], context: String = "") {
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
        let routing = target.chatRouting   // one brain per agent, shared with the company
        config.profile = routing.profile

        let body = trimmed + attachments.payloadSuffix
        let persona = target.soul.isEmpty ? target.summary : target.soul
        let rank = target.tier == .ceo
            ? "You are the CEO — the final authority in this company; every department head and their team reports to you."
            : "You report to the GM/CEO and defer to their direction. Stay strictly in your own lane — do not speak for other departments or over the GM."
        let ctx = context.isEmpty ? "" : context + "\n\n"
        let payload: String
        if introSent.contains(target.id) {
            payload = ctx + body
        } else {
            introSent.insert(target.id)
            payload = ctx + "You are the \(target.name) in a multi-agent company. \(rank) Your remit: \(persona) Answer in that role.\n\n\(body)"
        }

        isSending = true
        let responseID = UUID()
        var reply = ChatMessage(id: responseID, author: .hermes, text: "", date: Date())
        reply.speaker = target.name
        reply.accentHex = target.accentHex
        messages.append(reply)
        let session = routing.session

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

    /// Pick the agent explicitly addressed at the start of the message; default to the CEO/GM.
    /// Important: do not substring-match short IDs like "ar" inside words such as "are" or
    /// "addressed". That was letting AR answer messages addressed to the GM.
    static func resolveTarget(_ text: String, org: [OrgAgent]) -> OrgAgent? {
        guard !org.isEmpty else { return nil }
        let fallback = org.first { $0.tier == .ceo } ?? org.first
        let normalized = normalizedAddressText(text)
        let tokens = normalized.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return fallback }

        // Chain of command: if the owner opens with the GM/CEO, that is the addressee even
        // when another department is mentioned later in the sentence.
        if let ceo = fallback, isAddressed(ceo, tokens: tokens) {
            return ceo
        }

        for agent in org where agent.id != fallback?.id {
            if isAddressed(agent, tokens: tokens) {
                return agent
            }
        }
        return fallback
    }

    private static func normalizedAddressText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAddressed(_ agent: OrgAgent, tokens: [String]) -> Bool {
        let keys = routingKeys(agent)
        let opening = tokens.prefix(4).joined(separator: " ")
        return keys.contains { key in
            if key.count <= 2 {
                return tokens.first == key || opening.hasPrefix("hey \(key)") || opening.hasPrefix("ok \(key)")
            }
            return opening == key || opening.hasPrefix("\(key) ") || opening.hasPrefix("hey \(key) ") || opening.hasPrefix("ok \(key) ")
        }
    }

    /// Address-keywords derived from an agent's id, name, and role label.
    /// Multi-word names are kept as exact opening phrases; short IDs only match standalone tokens.
    static func routingKeys(_ agent: OrgAgent) -> [String] {
        var keys = Set<String>()
        let normalizedID = normalizedAddressText(agent.id.replacingOccurrences(of: "_", with: " "))
        if !normalizedID.isEmpty { keys.insert(normalizedID) }
        let idToken = agent.id.lowercased()
        if idToken.count <= 3 { keys.insert(idToken) }

        let normalizedName = normalizedAddressText(agent.name)
        if !normalizedName.isEmpty { keys.insert(normalizedName) }
        if normalizedName.hasSuffix(" agent") {
            keys.insert(String(normalizedName.dropLast(" agent".count)))
        }
        if agent.tier == .ceo {
            keys.formUnion(["gm", "general manager", "ceo", "boss"])
        }

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
    @EnvironmentObject private var hub: MeetingHub
    @EnvironmentObject private var company: CompanyStore
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
                    convo.send(draft, attachments: attachments, relay: runtime.relayConfiguration, org: org.leadership,
                               context: CompanyContext.brief(org: org, hub: hub, company: company))
                    draft = ""
                }
            }
            .background(HermesTheme.background)
            .navigationTitle("Company")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
