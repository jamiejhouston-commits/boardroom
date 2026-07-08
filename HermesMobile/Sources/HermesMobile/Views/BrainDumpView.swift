import SwiftUI

/// Brain dump — hold the mic (or type), and the thought lands as a markdown
/// note in the owner's Obsidian vault (Inbox/), instantly part of the second
/// brain: visible in the knowledge graph and readable by the agents.
struct BrainDumpView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceNoteRecorder()

    @State private var text = ""
    @State private var saving = false
    @State private var savedPath: String?
    @State private var errorMessage: String?
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let savedPath {
                    ContentUnavailableView {
                        Label("Captured", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("Saved to your vault as\n\(savedPath)")
                    } actions: {
                        Button("Dump another") { self.savedPath = nil; text = "" }
                            .buttonStyle(.borderedProminent)
                            .tint(HermesTheme.emerald)
                    }
                } else {
                    TextEditor(text: $text)
                        .focused($editing)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(maxHeight: .infinity)
                        .background(HermesTheme.surface,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Speak or type what's on your mind…")
                                    .foregroundStyle(HermesTheme.textSecondary)
                                    .padding(18)
                                    .allowsHitTesting(false)
                            }
                        }

                    if let status = recorder.state.status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(HermesTheme.textSecondary)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack(spacing: 14) {
                        // Hold to talk — release to transcribe into the editor.
                        micButton
                        Button {
                            Task { await save() }
                        } label: {
                            if saving {
                                ProgressView().tint(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            } else {
                                Label("Save to vault", systemImage: "brain.head.profile")
                                    .font(.subheadline.weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            }
                        }
                        .background(HermesTheme.emerald, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                        .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(16)
            .background(HermesTheme.background.ignoresSafeArea())
            .navigationTitle("Brain Dump")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var micButton: some View {
        Image(systemName: recorder.state == .recording ? "waveform" : "mic.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(recorder.state == .recording ? .white : HermesTheme.emerald)
            .frame(width: 52, height: 52)
            .background(recorder.state == .recording ? HermesTheme.gold : HermesTheme.surface,
                        in: Circle())
            .overlay(Circle().strokeBorder(HermesTheme.emerald.opacity(0.4), lineWidth: 1))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard recorder.state != .recording else { return }
                        editing = false
                        Task { await recorder.beginRecording() }
                    }
                    .onEnded { _ in
                        Task {
                            if let transcript = await recorder.finishRecordingAndTranscribe(),
                               !transcript.isEmpty {
                                text = text.isEmpty ? transcript : text + "\n" + transcript
                            }
                        }
                    }
            )
    }

    private func save() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard runtime.relayConfiguration.isConfigured else {
            errorMessage = "Connect your Mac relay first — the vault lives on the Mac."
            return
        }
        saving = true
        defer { saving = false }
        errorMessage = nil
        do {
            let result = try await HermesRelayClient(configuration: runtime.relayConfiguration)
                .vaultCapture(text: body)
            savedPath = result.path
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Client call for the capture endpoint. Lives here (not in HermesRelayClient.swift)
/// only to keep this feature self-contained; the shape mirrors companyPOSTJSON.
extension HermesRelayClient {
    struct VaultCaptureResult: Codable {
        var ok: Bool
        var path: String
        var id: String?
    }

    func vaultCapture(text: String, title: String? = nil) async throws -> VaultCaptureResult {
        guard let baseURL = configuration.baseURL else {
            throw HermesRelayError.invalidURL
        }
        var request = URLRequest(url: baseURL.appending(path: "vault/capture"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        var payload: [String: String] = ["text": text]
        if let title { payload["title"] = title }
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw HermesRelayError.unauthorized
            }
            throw HermesRelayError.server("Capture failed (HTTP \(http.statusCode)).")
        }
        return try JSONDecoder().decode(VaultCaptureResult.self, from: data)
    }
}
