# Meeting Intake (v1) Implementation Plan

> Spec'd ahead of build — execution starts after the launch demo video is posted.
> Interface-level plan; full code lands in commits, one per task.

**Goal:** Boardroom attends your real-world meetings without any Teams/Zoom
integration: (a) "phone on the table" live listening, (b) import the
transcript/recording Teams & Zoom already produce. Either way the secretary
agent files minutes into Memos — summary, decisions, action items — and can
dispatch the action items to the right agents as a memo.

**Explicitly out of scope (v2+):** joining meetings as a bot participant
(Recall.ai-style service, paid tier), auto-creating company initiatives from
meetings, speaker diarization beyond what transcripts already contain.

**Architecture:** `LiveTranscriber` (AVAudioEngine tap → chunked
`SFSpeechAudioBufferRecognitionRequest`, auto-restarting every ~50s to dodge
Apple's per-request limit, on-device recognition when available) and
`TranscriptParser` (pure functions: VTT/SRT/TXT → clean speaker-preserving
text) feed a shared `MeetingHub.fileMeetingMinutes(transcript:title:relay:)`
which prompts the secretary agent (executive_assistant → ceo fallback) and
files the result via the existing `fileMinutes` + optional `sendMemo` for
action items. UI: `MeetingCaptureView` reached from MeetingsView — big
record button with live transcript preview, or file importer accepting
.vtt/.srt/.txt (audio files best-effort via file transcription).

### Task 1: TranscriptParser (pure logic)
- Create `Models/TranscriptParser.swift`: `parseVTT`, `parseSRT`, `parseplain`
  → strip timestamps/cue numbers, keep `Speaker: text` lines, collapse blanks.
- Compile-check. (Pure functions — unit-testable in HermesMobileTests later.)

### Task 2: LiveTranscriber service
- Create `Services/LiveTranscriber.swift`: `@MainActor ObservableObject` —
  `start()`, `stop() -> String`, `@Published liveText/elapsed/state`.
  AVAudioEngine input tap → SFSpeechAudioBufferRecognitionRequest with
  `requiresOnDeviceRecognition` when supported; rotate the recognition request
  every ~50s (or on final result), accumulating segments. Reuses the
  permission patterns from VoiceNoteRecorder (@Sendable callbacks — the
  dispatch_assert lesson).

### Task 3: Secretary pipeline in MeetingHub
- Modify `Services/MeetingHub.swift`: `fileMeetingMinutes(transcript:title:recipients:relay:)`
  — chunk transcripts >12k chars (summarize parts, merge), prompt the
  secretary for: 1-paragraph summary, decisions, action items with owners;
  `fileMinutes` the result; optional follow-up `sendMemo` of action items to
  chosen agents.

### Task 4: MeetingCaptureView + entry point
- Create `Views/MeetingCaptureView.swift`: Listen tab (record button, live
  transcript, elapsed, stop → "File minutes") and Import tab (fileImporter:
  .vtt/.srt/.txt parsed; audio via SFSpeechURLRecognitionRequest best-effort);
  recipient picker for the action-items memo; progress + error states.
- Modify `Views/MeetingsView.swift`: "Capture a meeting" button → sheet.
- xcodegen + compile-check + commit.

### Task 5: Owner device test checklist (30s each)
1. Listen mode: record 1 min of talk → stop → minutes appear in Memos.
2. Import a Teams .vtt export → minutes appear with speakers preserved.
3. Action-items memo lands with chosen agents and replies stream in.
