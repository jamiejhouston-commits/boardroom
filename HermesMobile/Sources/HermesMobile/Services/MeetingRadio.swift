import AVFoundation
import Foundation

/// The Meeting Radio — listen to a company meeting like a broadcast. Polls the
/// meeting detail endpoint every ~8s, queues turns it hasn't heard yet (dedupe
/// by turn id), and reads them aloud sequentially through `AgentVoice` with
/// each role's own voice (same role → voice rule the transcript's "Read aloud"
/// uses). Built for hands-free listening — the audio session is `.playback`
/// and a silent keepalive loop holds it open between turns, so the radio keeps
/// going with the screen locked and the phone pocketed.
@MainActor
final class MeetingRadio: ObservableObject {

    /// One meeting turn on the air (or already aired).
    struct Line: Identifiable, Equatable {
        let id: String
        let role: String
        let text: String
    }

    @Published private(set) var nowSpeaking: Line?
    @Published private(set) var spoken: [Line] = []       // aired lines, oldest first
    @Published private(set) var isPaused = false
    @Published private(set) var isLive = true
    @Published private(set) var queuedCount = 0

    /// Nothing live, nothing queued, nothing on the air — the broadcast is over.
    var hasEnded: Bool { !isLive && queuedCount == 0 && nowSpeaking == nil }

    private let voice = AgentVoice()
    private var relay: HermesRelayConfiguration = .empty
    private var meetingID = ""
    private var voiceByRole: [String: String] = [:]
    private var queue: [Line] = []
    private var seenTurnIDs: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    private var keepalive: AVAudioPlayer?

    private static let pollInterval: Duration = .seconds(8)
    private static let fallbackVoice = "en_US-ryan-medium"

    /// Tune in: begin polling the meeting and speaking new turns as they land.
    /// `agents` provides the role → voice mapping.
    func start(meetingID: String, relay: HermesRelayConfiguration, agents: [OrgAgent]) {
        stop()
        self.meetingID = meetingID
        self.relay = relay
        voiceByRole = agents.reduce(into: [:]) { map, agent in
            if let role = agent.companyRole, map[role] == nil { map[role] = agent.voiceModel }
        }

        // Claim the session for playback so speech survives the lock button —
        // listening while driving is the whole point of the radio.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        startKeepalive()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pull()
                // A finished meeting can't grow — the fetch above banked the
                // final turns, so the poller retires and the queue drains out.
                if !self.isLive { return }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }

        speakTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard !self.isPaused, !self.queue.isEmpty else {
                    try? await Task.sleep(for: .milliseconds(300))
                    continue
                }
                let line = self.queue.removeFirst()
                self.queuedCount = self.queue.count
                self.nowSpeaking = line
                let model = self.voiceByRole[line.role] ?? Self.fallbackVoice
                await self.voice.speak(line.text, seedFrom: line.role,
                                       voice: model, relay: self.relay)
                self.nowSpeaking = nil
                if self.isPaused {
                    // Pause interrupted this line mid-sentence — replay it
                    // from the top on resume rather than losing it.
                    self.queue.insert(line, at: 0)
                    self.queuedCount = self.queue.count
                } else {
                    self.spoken.append(line)
                    if self.spoken.count > 30 { self.spoken.removeFirst() }
                }
            }
        }
    }

    // MARK: Controls

    func playPause() {
        if isPaused {
            isPaused = false
        } else {
            isPaused = true
            voice.stop()          // the speak loop re-queues the cut-off line
        }
    }

    /// Cut off the current line; the loop moves straight to the next one.
    func skip() { voice.stop() }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        speakTask?.cancel(); speakTask = nil
        voice.stop()
        keepalive?.stop(); keepalive = nil
        nowSpeaking = nil
        isPaused = false
        isLive = true
        queue.removeAll()
        seenTurnIDs.removeAll()
        spoken.removeAll()
        queuedCount = 0
    }

    // MARK: Polling

    private func pull() async {
        guard relay.isConfigured else { isLive = false; return }
        guard let meeting = try? await HermesRelayClient(configuration: relay)
            .companyMeetingDetail(id: meetingID) else { return }
        isLive = meeting.isLive
        for turn in meeting.turns ?? [] where !seenTurnIDs.contains(turn.id) {
            seenTurnIDs.insert(turn.id)
            queue.append(Line(id: turn.id, role: turn.role, text: turn.text))
        }
        queuedCount = queue.count
    }

    // MARK: Background keepalive

    /// iOS suspends a locked app the moment its audio goes quiet — and meeting
    /// turns arrive with real gaps between them. A looping silent buffer keeps
    /// the playback session "playing" through the gaps so polling + speech
    /// continue behind the lock screen. Torn down in `stop()`.
    private func startKeepalive() {
        guard let player = try? AVAudioPlayer(data: Self.silentWAV) else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.play()
        keepalive = player
    }

    /// Half a second of silence as an in-memory 16-bit mono 8kHz WAV.
    private static let silentWAV: Data = {
        let sampleCount = 4000                       // 0.5s @ 8kHz
        let dataSize = UInt32(sampleCount * 2)
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(16)
        append16(1); append16(1)                     // PCM, mono
        append(8000); append(16000)                  // sample rate, byte rate
        append16(2); append16(16)                    // block align, bits/sample
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }()
}
