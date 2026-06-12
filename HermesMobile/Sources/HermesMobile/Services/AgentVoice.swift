import AVFoundation

/// Shared speech engine: every agent speaks with a stable, distinct voice —
/// the voice, pitch, and rate are seeded from the agent's id. Used by
/// boardroom debates, voice calls, and the morning briefing.
///
/// Voices are picked from the BEST quality installed on the device
/// (premium → enhanced → compact). Tip: downloading a premium voice in
/// iOS Settings → Accessibility → Spoken Content → Voices upgrades every
/// agent automatically.
final class AgentVoice: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let queue = SpeechQueueBox()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Speak and suspend until finished (or stopped).
    func speak(_ text: String, seedFrom id: String) async {
        enqueue(text, seedFrom: id)
        await waitUntilFinished()
    }

    /// Queue a chunk for immediate playback and return — the synthesizer
    /// plays queued utterances back-to-back. Lets a streamed reply start
    /// speaking at the first sentence instead of waiting for the whole text.
    func enqueue(_ text: String, seedFrom id: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Without an explicit .playback session, speech obeys the silent
        // switch — i.e. most iPhones hear NOTHING. Claim the session first.
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audioSession.setActive(true)
        // NOTE: deliberately never deactivating the session — releasing it
        // can race with the voice-call recorder grabbing the mic and kill the
        // recording. The recorder reconfigures the session itself when needed.

        queue.increment()
        synthesizer.speak(Self.utterance(for: trimmed, seedFrom: id))
    }

    /// Suspend until everything queued has been spoken (or stopped).
    func waitUntilFinished() async {
        await queue.waitUntilIdle()
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        queue.drain()
    }

    private static func utterance(for text: String, seedFrom id: String) -> AVSpeechUtterance {
        let seed = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let utterance = AVSpeechUtterance(string: text)

        if let voice = bestVoice(seed: seed) {
            utterance.voice = voice
        }

        // Subtle per-agent identity. The old 0.85–1.2 pitch warp made the
        // compact voices unintelligible — keep it close to natural.
        utterance.pitchMultiplier = 0.97 + Float(seed % 4) / 50.0    // 0.97–1.03
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * (0.97 + Float(seed % 3) / 50.0)
        return utterance
    }

    /// Pick a distinct-but-intelligible voice, seeded per agent.
    /// Excludes the legacy "Eloquence" + novelty synths (the robotic,
    /// hard-to-understand ones), restricts to mainstream English locales,
    /// and always prefers the best installed quality tier.
    private static func bestVoice(seed: Int) -> AVSpeechSynthesisVoice? {
        let mainstreamLocales: Set<String> = ["en-US", "en-GB", "en-AU", "en-IE"]
        let usable = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            let id = voice.identifier.lowercased()
            return mainstreamLocales.contains(voice.language)
                && !id.contains("eloquence")   // legacy screen-reader synth → robotic
                && !id.contains("novelty")      // joke voices (Bells, Bubbles, Wobble…)
        }
        guard !usable.isEmpty else {
            // Fall back to the platform default rather than a random bad voice.
            return AVSpeechSynthesisVoice(language: "en-US")
        }
        // Best tier present wins; Siri/premium voices sort to the front.
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            let id = v.identifier.lowercased()
            var score = 0
            switch v.quality {
            case .premium: score += 300
            case .enhanced: score += 200
            default: score += 100
            }
            if id.contains("siri") { score += 50 }   // Siri voices are the most natural
            return score
        }
        let topScore = usable.map(rank).max() ?? 0
        let pool = usable.filter { rank($0) == topScore }
            .sorted { $0.identifier < $1.identifier }
        return pool.isEmpty ? usable.first : pool[seed % pool.count]
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        queue.decrement()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        queue.decrement()
    }
}

/// Thread-safe pending-utterance counter with a single idle-waiter.
/// `waitUntilIdle` suspends until the queue empties; `drain` force-releases.
final class SpeechQueueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func increment() {
        lock.lock()
        pending += 1
        lock.unlock()
    }

    func decrement() {
        lock.lock()
        pending = max(0, pending - 1)
        let waiter = pending == 0 ? continuation : nil
        if pending == 0 { continuation = nil }
        lock.unlock()
        waiter?.resume()
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { (new: CheckedContinuation<Void, Never>) in
            lock.lock()
            if pending == 0 {
                lock.unlock()
                new.resume()
                return
            }
            let old = continuation     // resume-once: displace any old waiter
            continuation = new
            lock.unlock()
            old?.resume()
        }
    }

    func drain() {
        lock.lock()
        pending = 0
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume()
    }
}
