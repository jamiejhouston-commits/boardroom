import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HermesWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MeetingLiveActivity()
        DebateLiveActivity()
    }
}

// MARK: - Meeting countdown (lock screen + Dynamic Island)

struct MeetingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingCountdownAttributes.self) { context in
            // Lock screen banner.
            HStack(spacing: 12) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.title3)
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.topic)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text("\(context.attributes.attendeeCount) attendees · Hermes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("starts in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(timerInterval: Date()...context.state.startDate, countsDown: true)
                        .font(.headline.weight(.bold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 70)
                }
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(.teal)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.title2)
                        .foregroundStyle(.teal)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.topic)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...context.state.startDate, countsDown: true)
                        .font(.headline.weight(.bold))
                        .monospacedDigit()
                        .frame(maxWidth: 60)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(context.attributes.attendeeCount) attendees · alert 15 min before")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "person.2.wave.2.fill")
                    .foregroundStyle(.teal)
            } compactTrailing: {
                Text(timerInterval: Date()...context.state.startDate, countsDown: true)
                    .monospacedDigit()
                    .font(.caption2.weight(.bold))
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "person.2.wave.2.fill")
                    .foregroundStyle(.teal)
            }
        }
    }
}

// MARK: - Debate in progress (who's speaking now)

struct DebateLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DebateActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.title3)
                    .foregroundStyle(Color(hexString: context.state.accentHex))
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.speakerName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color(hexString: context.state.accentHex))
                    Text("debating: \(context.attributes.topic)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("R\(context.state.round)/\(context.state.totalRounds)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(.teal)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(Color(hexString: context.state.accentHex))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.speakerName)
                            .font(.subheadline.weight(.bold))
                        Text(context.attributes.topic)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("R\(context.state.round)/\(context.state.totalRounds)")
                        .font(.caption.weight(.bold))
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .foregroundStyle(Color(hexString: context.state.accentHex))
            } compactTrailing: {
                Text(initials(context.state.speakerName))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color(hexString: context.state.accentHex))
            } minimal: {
                Image(systemName: "waveform")
                    .foregroundStyle(Color(hexString: context.state.accentHex))
            }
        }
    }

    private func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

// MARK: - Helpers (widget-local)

private extension Color {
    init(hexString: String) {
        let clean = hexString.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
