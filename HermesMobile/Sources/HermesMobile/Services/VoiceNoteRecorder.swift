import AVFoundation
import Speech

@MainActor
final class VoiceNoteRecorder: NSObject, ObservableObject {
    enum RecorderState: Equatable {
        case idle
        case recording
        case transcribing
        case unavailable(String)

        var status: String? {
            switch self {
            case .idle:
                nil
            case .recording:
                "Recording voice note"
            case .transcribing:
                "Transcribing voice note"
            case .unavailable(let message):
                message
            }
        }
    }

    @Published private(set) var state: RecorderState = .idle

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private let recognizer = SFSpeechRecognizer()

    var isBusy: Bool {
        state == .recording || state == .transcribing
    }

    func beginRecording() async {
        guard state != .recording else { return }

        do {
            try await requestMicrophonePermission()
            // The call may have been hung up while the permission dialog was
            // up — starting the recorder now would leak a live audio session.
            guard !Task.isCancelled else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hermes-voice-\(UUID().uuidString)")
                .appendingPathExtension("m4a")

            let session = AVAudioSession.sharedInstance()
            // `.allowBluetooth` is the long-standing, broadly supported option.
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw VoiceNoteError.recorderFailed
            }

            self.recorder = recorder
            recordingURL = url
            state = .recording
        } catch {
            // Never crash — clean up and surface a readable message.
            recorder?.stop()
            recorder = nil
            state = .unavailable(error.localizedDescription)
        }
    }

    func finishRecordingAndTranscribe() async -> String? {
        guard state == .recording, let url = recordingURL else { return nil }

        recorder?.stop()
        recorder = nil
        // Deliberately NOT deactivating the shared session: deactivating while
        // the speech synthesizer / Bluetooth route is mid-teardown raises an
        // uncatchable CoreAudio exception on device. The next user of the
        // session (speech playback or another recording) reconfigures it.
        state = .transcribing

        do {
            try await requestSpeechPermission()
            let transcript = try await transcribe(url: url)
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
            state = .idle
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
            state = .unavailable(error.localizedDescription)
            return nil
        }
    }

    func cancelRecording() {
        recorder?.stop()
        recorder = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        state = .idle
    }

    private func requestMicrophonePermission() async throws {
        // Native async API (iOS 17+). The completion-handler variant calls
        // back on a background queue; from a @MainActor context the closure
        // gets main-actor-inferred and the runtime traps with
        // _dispatch_assert_queue_fail the moment recording starts.
        guard await AVAudioApplication.requestRecordPermission() else {
            throw VoiceNoteError.microphoneDenied
        }
    }

    private func requestSpeechPermission() async throws {
        // @Sendable keeps the closure nonisolated — Speech invokes it on a
        // background queue, which traps if the closure is main-actor-inferred.
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw VoiceNoteError.speechDenied
        }
        guard recognizer?.isAvailable == true else {
            throw VoiceNoteError.speechUnavailable
        }
    }

    private func transcribe(url: URL) async throws -> String {
        guard let recognizer else {
            throw VoiceNoteError.speechUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            let box = RecognitionContinuationBox(continuation: continuation)
            // @Sendable: Speech delivers results on its own queue — a
            // main-actor-inferred closure here is the _dispatch_assert_queue
            // crash when the user holds the mic.
            let task = recognizer.recognitionTask(with: request) { @Sendable result, error in
                if let error {
                    box.resume(throwing: error)
                    return
                }

                guard let result, result.isFinal else { return }
                box.resume(returning: result.bestTranscription.formattedString)
            }

            // Safety net: if recognition never reports final (e.g. silent/empty
            // clip), don't leave the UI stuck in "Transcribing" forever.
            Task {
                try? await Task.sleep(for: .seconds(20))
                task.cancel()
                box.resume(throwing: VoiceNoteError.transcriptionTimedOut)
            }
        }
    }
}

private final class RecognitionContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: String) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

private enum VoiceNoteError: LocalizedError {
    case microphoneDenied
    case speechDenied
    case speechUnavailable
    case recorderFailed
    case transcriptionTimedOut

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is off. Enable it in Settings › Hermes."
        case .speechDenied:
            "Speech recognition is off. Enable it in Settings › Hermes."
        case .speechUnavailable:
            "Speech recognition isn't available right now."
        case .recorderFailed:
            "Couldn't start recording. Try again."
        case .transcriptionTimedOut:
            "Didn't catch that — try recording again."
        }
    }
}
