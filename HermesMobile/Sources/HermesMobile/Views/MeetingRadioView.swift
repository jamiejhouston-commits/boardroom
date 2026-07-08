import SwiftUI

/// Now-playing screen for the Meeting Radio — a compact broadcast console for
/// one company meeting. Shows the topic, who's on the air (with a subtle level
/// animation), the last few spoken lines, and play/pause · skip · stop.
/// Presented as a sheet from `MeetingsView`; audio continues screen-locked.
struct MeetingRadioView: View {
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @Environment(\.dismiss) private var dismiss
    let meeting: CompanyMeeting

    @StateObject private var radio = MeetingRadio()

    var body: some View {
        VStack(spacing: 20) {
            header
            nowPlayingCard
            recentLines
            Spacer(minLength: 0)
            controls
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HermesTheme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            radio.start(meetingID: meeting.id,
                        relay: runtime.relayConfiguration,
                        agents: org.agents)
        }
        .onDisappear { radio.stop() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "radio.fill")
                    .font(.caption)
                    .foregroundStyle(HermesTheme.gold)
                Text("MEETING RADIO")
                    .font(.caption.weight(.black)).tracking(1.2)
                    .foregroundStyle(HermesTheme.textSecondary)
                Spacer()
                if radio.hasEnded {
                    Text("ENDED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(HermesTheme.textSecondary)
                } else if radio.isLive {
                    HStack(spacing: 5) {
                        Circle().fill(HermesTheme.emerald).frame(width: 7, height: 7)
                        Text("LIVE").font(.caption2.weight(.bold))
                            .foregroundStyle(HermesTheme.emerald)
                    }
                }
            }
            Text(meeting.topic)
                .font(.title3.weight(.semibold))
                .foregroundStyle(HermesTheme.textPrimary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Now playing

    @ViewBuilder
    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let line = radio.nowSpeaking {
                HStack(spacing: 10) {
                    RadioLevelBars(active: !radio.isPaused)
                    Text(speakerName(for: line.role))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(HermesTheme.emerald)
                    Spacer()
                    if radio.queuedCount > 0 {
                        Text("\(radio.queuedCount) queued")
                            .font(.caption2)
                            .foregroundStyle(HermesTheme.textSecondary)
                    }
                }
                Text(line.text)
                    .font(.subheadline)
                    .foregroundStyle(HermesTheme.textPrimary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            } else if radio.hasEnded {
                Text("That's the whole meeting — you're caught up.")
                    .font(.subheadline)
                    .foregroundStyle(HermesTheme.textSecondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the next speaker…")
                        .font(.subheadline)
                        .foregroundStyle(HermesTheme.textSecondary)
                }
            }
        }
        .hermesCard()
        .animation(.easeInOut(duration: 0.2), value: radio.nowSpeaking)
    }

    // MARK: Recent lines

    @ViewBuilder
    private var recentLines: some View {
        if !radio.spoken.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recently on the air")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HermesTheme.textSecondary)
                ForEach(radio.spoken.suffix(3)) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(speakerName(for: line.role))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(HermesTheme.steel)
                        Text(line.text)
                            .font(.caption)
                            .foregroundStyle(HermesTheme.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 36) {
            // Stop — end the broadcast and put the radio away.
            Button {
                radio.stop()
                dismiss()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.title3)
                    .foregroundStyle(HermesTheme.textSecondary)
                    .frame(width: 52, height: 52)
                    .background(HermesTheme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(HermesTheme.hairline, lineWidth: 1))
            }
            .accessibilityLabel("Stop")

            Button { radio.playPause() } label: {
                Image(systemName: radio.isPaused ? "play.fill" : "pause.fill")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(HermesTheme.emerald, in: Circle())
            }
            .accessibilityLabel(radio.isPaused ? "Play" : "Pause")

            Button { radio.skip() } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .foregroundStyle(HermesTheme.textPrimary)
                    .frame(width: 52, height: 52)
                    .background(HermesTheme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(HermesTheme.hairline, lineWidth: 1))
            }
            .accessibilityLabel("Skip")
            .disabled(radio.nowSpeaking == nil)
        }
        .padding(.bottom, 8)
    }

    private func speakerName(for role: String) -> String {
        if role == "owner" { return "You" }
        return org.agents.first { $0.companyRole == role }?.name ?? role.uppercased()
    }
}

/// Five quiet capsules that breathe while someone speaks — a level meter with
/// the neon dialed all the way out, per the Hermes palette.
private struct RadioLevelBars: View {
    var active: Bool
    @State private var phase = false
    private let tall: [CGFloat] = [12, 20, 15, 22, 13]
    private let short: [CGFloat] = [16, 10, 21, 12, 19]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(HermesTheme.emerald.opacity(active ? 0.9 : 0.35))
                    .frame(width: 3, height: active ? (phase ? tall[i] : short[i]) : 6)
                    .animation(
                        active
                            ? .easeInOut(duration: 0.45)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.07)
                            : .default,
                        value: phase
                    )
            }
        }
        .frame(height: 22)
        .onAppear { phase = true }
    }
}
