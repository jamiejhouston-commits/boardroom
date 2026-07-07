import AVFoundation
import Foundation

extension Notification.Name {
    /// Posted when the active debate speaker changes
    /// (userInfo: "agentID" → String; empty string = nobody speaking).
    static let hermesDebateSpeaker = Notification.Name("hermesDebateSpeaker")
}

/// One spoken contribution in a boardroom debate.
struct DebateTurn: Identifiable, Hashable {
    var id = UUID()
    var agentID: String
    var agentName: String
    var accentHex: String
    var text: String
    var round: Int
}

/// Runs a live multi-agent boardroom debate: round-robin turns where each
/// agent receives the running transcript and argues in its role — optionally
/// spoken aloud with a distinct synthesized voice per agent — then the
/// Executive Secretary writes the minutes and files them into Memos.
@MainActor
final class DebateEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case running(round: Int, total: Int)
        case concluding
        case finished
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var turns: [DebateTurn] = []
    @Published private(set) var currentSpeakerID: String?
    @Published var voicesOn = true

    private var task: Task<Void, Never>?
    private let voice = AgentVoice()

    func start(topic: String, rounds: Int, attendees: [OrgAgent],
               relay: HermesRelayConfiguration, org: OrgStore, hub: MeetingHub) {
        guard case .idle = state, !attendees.isEmpty else { return }
        turns = []
        state = .running(round: 1, total: rounds)

        task = Task { [weak self] in
            await self?.run(topic: topic, rounds: rounds, attendees: attendees,
                            relay: relay, org: org, hub: hub)
        }
    }

    func stop() {
        task?.cancel()
        voice.stop()
        announceSpeaker(nil)
        if state != .finished { state = .finished }
    }

    private func run(topic: String, rounds: Int, attendees: [OrgAgent],
                     relay: HermesRelayConfiguration, org: OrgStore, hub: MeetingHub) async {
        guard relay.isConfigured else {
            state = .failed("Connect your relay first (Settings → Mac Relay).")
            return
        }
        LiveActivityManager.startDebate(topic: topic)

        for round in 1...rounds {
            state = .running(round: round, total: rounds)
            for agent in attendees {
                if Task.isCancelled { return }
                currentSpeakerID = agent.id
                announceSpeaker(agent.id)
                LiveActivityManager.updateDebate(speaker: agent.name, accentHex: agent.accentHex,
                                                 round: round, totalRounds: rounds)

                do {
                    let text = try await fetchTurn(agent: agent, topic: topic,
                                                   round: round, relay: relay)
                    if Task.isCancelled { return }
                    let turn = DebateTurn(agentID: agent.id, agentName: agent.name,
                                          accentHex: agent.accentHex, text: text, round: round)
                    turns.append(turn)

                    if voicesOn {
                        await voice.speak(text, seedFrom: agent.id,
                                          voice: agent.voiceModel, relay: relay)
                    }
                } catch {
                    turns.append(DebateTurn(agentID: agent.id, agentName: agent.name,
                                            accentHex: agent.accentHex,
                                            text: "⚠️ \(error.localizedDescription)", round: round))
                }
            }
        }

        announceSpeaker(nil)
        currentSpeakerID = nil
        LiveActivityManager.endDebate()
        guard !Task.isCancelled else { return }

        // The Secretary writes and files the minutes.
        state = .concluding
        await fileMinutes(topic: topic, attendees: attendees, relay: relay, org: org, hub: hub)
        state = .finished
    }

    // MARK: One agent's turn

    private func fetchTurn(agent: OrgAgent, topic: String, round: Int,
                           relay: HermesRelayConfiguration) async throws -> String {
        var config = relay
        config.profile = agent.profileSlug
        let persona = agent.soul.isEmpty ? agent.summary : agent.soul

        var payload = "You are \(agent.name) (\(agent.title)) in a LIVE BOARDROOM DEBATE with the company's leadership. Your remit: \(persona)\n\n"
        payload += "Debate topic: \"\(topic)\"\n\n"
        if turns.isEmpty {
            payload += "You speak FIRST. Open the debate with your position.\n"
        } else {
            payload += "Transcript so far:\n"
            for turn in turns.suffix(14) {
                payload += "\(turn.agentName): \(turn.text)\n"
            }
            payload += "\nYour turn. Respond DIRECTLY to points already raised — agree, push back, or sharpen them — and advance your own position.\n"
        }
        payload += "Speak as \(agent.name) in round \(round). 2–4 sentences, natural spoken style. No markdown, no lists, no stage directions."

        let session = "hermes-mobile-debate-\(agent.id)"
        return try await HermesRelayClient(configuration: config)
            .collect(payload, sessionKey: session)
    }

    // MARK: Minutes

    private func fileMinutes(topic: String, attendees: [OrgAgent],
                             relay: HermesRelayConfiguration, org: OrgStore, hub: MeetingHub) async {
        let secretary = org.agent(id: "executive_assistant") ?? org.ceo ?? attendees[0]
        var config = relay
        config.profile = secretary.profileSlug

        var payload = "You are \(secretary.name), taking minutes for a leadership debate on \"\(topic)\".\n\nFull transcript:\n"
        for turn in turns {
            payload += "\(turn.agentName): \(turn.text)\n"
        }
        payload += "\nWrite the minutes: 1) one-paragraph summary, 2) decisions or points of consensus, 3) open disagreements, 4) action items with owners. Be concise and plain."

        var collected: String
        do {
            collected = try await HermesRelayClient(configuration: config)
                .collect(payload, sessionKey: "hermes-mobile-minutes")
        } catch {
            collected = "Minutes unavailable: \(error.localizedDescription)\n\nTranscript:\n"
                + turns.map { "\($0.agentName): \($0.text)" }.joined(separator: "\n")
        }

        hub.fileMinutes(subject: "Minutes — \(topic)",
                        body: collected,
                        recipients: attendees)
    }

    private func announceSpeaker(_ agentID: String?) {
        NotificationCenter.default.post(name: .hermesDebateSpeaker, object: nil,
                                        userInfo: ["agentID": agentID ?? ""])
    }
}

// (Per-agent synthesized voices live in Services/AgentVoice.swift — shared
// with voice calls and the morning briefing.)
