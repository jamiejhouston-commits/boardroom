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

        // Best installed tier wins: premium → enhanced → whatever's there.
        let english = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        let premium = english.filter { $0.quality == .premium }
        let enhanced = english.filter { $0.quality == .enhanced }
        let pool = (premium.isEmpty ? (enhanced.isEmpty ? english : enhanced) : premium)
            .sorted { $0.identifier < $1.identifier }
        if !pool.isEmpty {
            utterance.voice = pool[seed % pool.count]
        }

        // Subtle per-agent identity. The old 0.85–1.2 pitch warp made the
        // compact voices unintelligible — keep it close to natural.
        utterance.pitchMultiplier = 0.96 + Float(seed % 5) / 50.0    // 0.96–1.04
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * (0.98 + Float(seed % 3) / 50.0)
        return utterance
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
