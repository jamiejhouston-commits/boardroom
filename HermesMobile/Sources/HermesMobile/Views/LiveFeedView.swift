import SwiftUI

/// Over the shoulder: what each working initiative's agent last produced,
/// refreshed every 8 seconds from `GET /company/live`. Honest per-turn feed —
/// the engine records minutes per finished agent turn, so this is the latest
/// real output at every desk, not a simulated ticker.
struct LiveFeedView: View {
    @EnvironmentObject private var runtime: HermesRuntimeController

    @State private var entries: [LiveWorkEntry] = []
    @State private var loaded = false

    private let ticker = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            HermesTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if entries.isEmpty {
                        emptyState
                    } else {
                        ForEach(entries) { entry in
                            deskCard(entry)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("At their desks")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onReceive(ticker) { _ in
            Task { await load() }
        }
    }

    private func deskCard(_ entry: LiveWorkEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(HermesTheme.emerald).frame(width: 7, height: 7)
                Text(entry.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(HermesTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(stageLabel(entry))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HermesTheme.textSecondary)
            }

            if let role = entry.role, !role.isEmpty {
                HStack {
                    Text(role.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(HermesTheme.emerald)
                    if let ts = entry.ts, !ts.isEmpty {
                        Text("last turn \(ts)")
                            .font(.caption2)
                            .foregroundStyle(HermesTheme.textSecondary)
                    }
                    Spacer()
                    if let calls = entry.callsUsed {
                        Text("\(calls) calls")
                            .font(.caption2)
                            .foregroundStyle(HermesTheme.textSecondary)
                    }
                }
            }

            if let text = entry.text, !text.isEmpty {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(HermesTheme.textSecondary)
                    .lineLimit(14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .hermesCard()
    }

    private func stageLabel(_ entry: LiveWorkEntry) -> String {
        if let phase = entry.phase, !phase.isEmpty {
            return "\(entry.stage) · \(phase)"
        }
        return entry.stage
    }

    @ViewBuilder
    private var emptyState: some View {
        if !loaded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking over their shoulders…")
                    .font(.caption)
                    .foregroundStyle(HermesTheme.textSecondary)
            }
            .hermesCard()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Nobody's at a desk right now", systemImage: "moon.zzz")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HermesTheme.textPrimary)
                Text("This screen shows each working initiative's latest agent output the moment a build is in flight.")
                    .font(.caption)
                    .foregroundStyle(HermesTheme.textSecondary)
            }
            .hermesCard()
        }
    }

    private func load() async {
        guard runtime.relayConfiguration.isConfigured else {
            loaded = true
            return
        }
        // Older relays 404 here — the empty state already explains itself.
        if let fresh = try? await HermesRelayClient(configuration: runtime.relayConfiguration)
            .companyLive() {
            entries = fresh
        }
        loaded = true
    }
}
