import SwiftUI

/// Ask the whole company one question: the board answers from each angle (money,
/// tech, market) and the CEO synthesizes a single clear answer. The work runs on
/// the relay in the background, so we submit and then poll until it's done.
struct AskCompanyView: View {
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController

    @StateObject private var recorder = VoiceNoteRecorder()
    @State private var question = ""
    @State private var active: CompanyAsk?
    @State private var polling = false

    var body: some View {
        List {
            askSection
            if let ask = active { answerSection(ask) }
            historySection
        }
        .navigationTitle("Ask the Company")
        .navigationBarTitleDisplayMode(.inline)
        .task { await company.refresh(relay: runtime.relayConfiguration) }
    }

    // MARK: Ask

    private var askSection: some View {
        Section {
            TextField("Ask your leaders anything…", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .font(.subheadline)

            HStack(spacing: 12) {
                Button {
                    Task { await toggleDictation() }
                } label: {
                    Label(recorder.state == .recording ? "Stop" : "Dictate",
                          systemImage: recorder.state == .recording ? "stop.circle.fill" : "mic.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(recorder.state == .recording ? .red : HermesTheme.emerald)
                }
                .buttonStyle(.plain)
                .disabled(recorder.state == .transcribing)

                Spacer()

                Button {
                    submit(question)
                } label: {
                    Label("Ask", systemImage: "paperplane.fill")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(HermesTheme.emerald)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || polling)
            }

            if let status = recorder.state.status, recorder.state != .idle {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Your leaders each answer from their seat, then the CEO gives you one combined answer.")
        }
    }

    // MARK: Live answer

    @ViewBuilder
    private func answerSection(_ ask: CompanyAsk) -> some View {
        Section("\"\(ask.question)\"") {
            ForEach(ask.contributions ?? []) { contribution in
                VStack(alignment: .leading, spacing: 3) {
                    Text(roleLabel(contribution.role))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(HermesTheme.emerald)
                    Text(contribution.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }

            if ask.isLive {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(((ask.contributions ?? []).isEmpty)
                         ? "The team is thinking…"
                         : "CEO is synthesizing the answer…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !ask.answer.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("CEO", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(HermesTheme.gold)
                    Text(ask.answer)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HermesTheme.gold.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        let past = (company.state.asks ?? []).filter { $0.id != active?.id && !$0.isLive }
        if !past.isEmpty {
            Section("Earlier answers") {
                ForEach(past) { ask in
                    DisclosureGroup {
                        Text(ask.answer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } label: {
                        Text(ask.question)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func submit(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        question = ""
        Task {
            guard let ask = await company.ask(q, relay: runtime.relayConfiguration) else { return }
            active = ask
            await poll(ask.id)
        }
    }

    private func poll(_ id: String) async {
        polling = true
        defer { polling = false }
        for _ in 0..<48 {                       // ~2 min ceiling
            if let fresh = await company.askDetail(id: id, relay: runtime.relayConfiguration) {
                active = fresh
                if !fresh.isLive { return }
            }
            try? await Task.sleep(for: .seconds(2.5))
        }
    }

    private func toggleDictation() async {
        if recorder.state == .recording {
            if let text = await recorder.finishRecordingAndTranscribe(), !text.isEmpty {
                question = text
            }
        } else {
            await recorder.beginRecording()
        }
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "cfo":       "CFO"
        case "cto":       "CTO"
        case "marketing": "Marketing"
        case "ceo":       "CEO"
        case "research":  "Research"
        default:          role.capitalized
        }
    }
}
