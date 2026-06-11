import Foundation

@MainActor
final class HermesRuntimeController: ObservableObject {
    @Published var selectedMode: HermesRuntimeMode = .embedded
    @Published private(set) var state: HermesRuntimeState = .booting
    @Published private(set) var relayConfiguration: HermesRelayConfiguration = .empty
    @Published private(set) var relayHealth: RelayHealth?
    @Published private(set) var isSending = false
    @Published private(set) var messages: [ChatMessage] = [
        ChatMessage(author: .system, text: "Hermes Mobile is preparing the agent runtime.", date: Date())
    ]

    private let relayConfigKey = "HermesRelayConfiguration"
    private let relayTokenKey = "HermesRelayToken"

    /// Relay config for contexts without the SwiftUI environment
    /// (e.g. BGAppRefresh). Mirrors loadRelayConfiguration().
    nonisolated static func persistedRelayConfiguration() -> HermesRelayConfiguration {
        guard let data = UserDefaults.standard.data(forKey: "HermesRelayConfiguration"),
              var configuration = try? JSONDecoder().decode(HermesRelayConfiguration.self, from: data) else {
            return .empty
        }
        if let token = KeychainStore.read(account: "HermesRelayToken"), !token.isEmpty {
            configuration.token = token
        }
        return configuration
    }

    let capabilities: [HermesRuntimeCapability] = [
        .init(id: "chat", title: "Chat Sessions", detail: "Shared Hermes sessions and streaming responses.", isAvailableOnDevice: true),
        .init(id: "memory", title: "Persistent Memory", detail: "Profiles, skills, summaries, and `soul.md` files.", isAvailableOnDevice: true),
        .init(id: "skills", title: "Skills", detail: "Browse, install, and generate reusable Hermes skills.", isAvailableOnDevice: true),
        .init(id: "cron", title: "Cron", detail: "Natural-language scheduled jobs through Hermes gateway.", isAvailableOnDevice: true),
        .init(id: "browser", title: "Browser Automation", detail: "Use iOS-safe browser tooling or remote browser workers.", isAvailableOnDevice: true),
        .init(id: "terminal", title: "Terminal", detail: "Requires a paired desktop, SSH host, or remote sandbox.", isAvailableOnDevice: false),
        .init(id: "docker", title: "Docker Sandbox", detail: "Runs through a remote Hermes host; iOS cannot host Docker locally.", isAvailableOnDevice: false),
        .init(id: "modal", title: "Modal Sandbox", detail: "Cloud sandbox backend exposed through Hermes Agent.", isAvailableOnDevice: true)
    ]

    func boot() {
        loadRelayConfiguration()
        if relayConfiguration.isConfigured {
            selectedMode = .desktopRelay
            state = .degraded("Mac relay configured. Test the connection from Gateway before sending work.")
        } else {
            state = .degraded("Run the Mac relay, then add its URL and token in Gateway > Mac Relay.")
        }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(ChatMessage(author: .user, text: trimmed, date: Date()))

        guard selectedMode == .desktopRelay, relayConfiguration.isConfigured else {
            messages.append(
                ChatMessage(
                    author: .system,
                    text: "Configure the Mac relay in Gateway before sending messages to Hermes.",
                    date: Date()
                )
            )
            return
        }

        isSending = true
        Task {
            do {
                let responseID = UUID()
                messages.append(ChatMessage(id: responseID, author: .hermes, text: "", date: Date()))

                for try await event in HermesRelayClient(configuration: relayConfiguration).stream(trimmed) {
                    switch event.type {
                    case .start:
                        state = .ready
                    case .delta:
                        appendToMessage(id: responseID, text: event.text ?? "")
                    case .done:
                        if let reply = event.reply, messageText(id: responseID).isEmpty {
                            appendToMessage(id: responseID, text: reply)
                        }
                        state = .ready
                    case .error:
                        throw HermesRelayError.server(event.message ?? "Hermes stream failed.")
                    }
                }

                if messageText(id: responseID).isEmpty {
                    appendToMessage(id: responseID, text: "Hermes completed without text output.")
                }
                state = .ready
            } catch {
                state = .offline(error.localizedDescription)
                messages.append(ChatMessage(author: .system, text: error.localizedDescription, date: Date()))
            }
            isSending = false
        }
    }

    private func appendToMessage(id: UUID, text: String) {
        guard !text.isEmpty, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += text
    }

    private func messageText(id: UUID) -> String {
        messages.first { $0.id == id }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func saveRelayConfiguration(_ configuration: HermesRelayConfiguration) {
        relayConfiguration = configuration
        selectedMode = .desktopRelay

        if !configuration.token.isEmpty {
            KeychainStore.save(configuration.token, account: relayTokenKey)
        }

        var persisted = configuration
        persisted.token = ""
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: relayConfigKey)
        }

        state = configuration.isConfigured
            ? .degraded("Mac relay saved. Test the connection to verify Hermes is reachable.")
            : .degraded("Run the Mac relay, then add its URL and token in Gateway > Mac Relay.")
    }

    func savePairingPayload(_ payload: HermesPairingPayload) {
        let deviceID = relayConfiguration.deviceID.isEmpty ? UUID().uuidString : relayConfiguration.deviceID
        saveRelayConfiguration(HermesRelayConfiguration(pairingPayload: payload, deviceID: deviceID))
        testRelayConnection()
    }

    func testRelayConnection() {
        guard relayConfiguration.isConfigured else {
            state = .offline("Mac relay URL and token are required.")
            return
        }

        state = .booting
        Task {
            do {
                let health = try await HermesRelayClient(configuration: relayConfiguration).health()
                relayHealth = health
                state = health.ok ? .ready : .degraded("Relay responded but did not report healthy.")
            } catch {
                relayHealth = nil
                state = .offline(error.localizedDescription)
            }
        }
    }

    private func loadRelayConfiguration() {
        guard let data = UserDefaults.standard.data(forKey: relayConfigKey),
              var configuration = try? JSONDecoder().decode(HermesRelayConfiguration.self, from: data) else {
            relayConfiguration = .empty
            return
        }
        if configuration.deviceID.isEmpty {
            configuration.deviceID = UUID().uuidString
        }
        if let token = KeychainStore.read(account: relayTokenKey), !token.isEmpty {
            configuration.token = token
        } else if !configuration.token.isEmpty {
            KeychainStore.save(configuration.token, account: relayTokenKey)
            configuration.token = ""
            if let data = try? JSONEncoder().encode(configuration) {
                UserDefaults.standard.set(data, forKey: relayConfigKey)
            }
            configuration.token = KeychainStore.read(account: relayTokenKey) ?? ""
        }
        relayConfiguration = configuration
    }
}
