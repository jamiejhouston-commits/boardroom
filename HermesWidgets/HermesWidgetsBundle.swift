import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HermesWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CompanyStatusWidget()
        LenaWidget()
        CompanyPulseLiveActivity()
        MeetingLiveActivity()
        DebateLiveActivity()
    }
}

// MARK: - Ask Lena (home + lock screen → opens the app to your assistant)

struct LenaEntry: TimelineEntry { let date: Date }

struct LenaProvider: TimelineProvider {
    func placeholder(in context: Context) -> LenaEntry { LenaEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (LenaEntry) -> Void) {
        completion(LenaEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LenaEntry>) -> Void) {
        completion(Timeline(entries: [LenaEntry(date: Date())], policy: .never))
    }
}

struct LenaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LenaWidget", provider: LenaProvider()) { _ in
            LenaWidgetView()
        }
        .configurationDisplayName("Ask Lena")
        .description("Your personal assistant — one tap away.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

private struct LenaWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(URL(string: "boardroom://lena"))
            .containerBackground(for: .widget) { container }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title2).widgetAccentable()
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lena").font(.headline)
                    Text("Tap to talk").font(.caption2)
                }
            }
            .widgetAccentable()
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.title).foregroundStyle(.white)
                Spacer()
                Text("Lena").font(.headline.weight(.bold)).foregroundStyle(.white)
                Text("Your assistant — tap to talk")
                    .font(.caption2).foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var container: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            Color.clear
        default:
            LinearGradient(colors: [Color(hexString: "7E4E9E"), Color(hexString: "3F2A57")],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

// MARK: - Company pulse (the company at work — lock screen + Dynamic Island)

private let emeraldHex = "1C7A55"
private let goldHex = "C7A35A"

struct CompanyPulseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CompanyPulseAttributes.self) { context in
            let accent = context.state.pendingGates > 0 ? goldHex : emeraldHex
            HStack(spacing: 12) {
                pulseDot(working: context.state.working,
                         color: Color(hexString: accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.headline)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text(context.state.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if context.state.pendingGates > 0 {
                    gateBadge(context.state.pendingGates)
                } else {
                    Text(context.attributes.company.uppercased())
                        .font(.caption2.weight(.black))
                        .tracking(1)
                        .foregroundStyle(Color(hexString: accent))
                }
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(Color(hexString: accent))
        } dynamicIsland: { context in
            let accent = context.state.pendingGates > 0 ? goldHex : emeraldHex
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.pendingGates > 0 ? "gavel.fill" : "building.2.fill")
                        .font(.title2)
                        .foregroundStyle(Color(hexString: accent))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.pendingGates > 0 {
                        gateBadge(context.state.pendingGates)
                    } else {
                        pulseDot(working: context.state.working, color: Color(hexString: accent))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.headline)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                        Text(context.state.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.pendingGates > 0 ? "gavel.fill" : "building.2.fill")
                    .foregroundStyle(Color(hexString: accent))
            } compactTrailing: {
                if context.state.pendingGates > 0 {
                    Text("\(context.state.pendingGates)")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(Color(hexString: goldHex))
                } else {
                    pulseDot(working: context.state.working, color: Color(hexString: accent))
                }
            } minimal: {
                Image(systemName: context.state.pendingGates > 0 ? "gavel.fill" : "building.2.fill")
                    .foregroundStyle(Color(hexString: accent))
            }
        }
    }

    private func pulseDot(working: Bool, color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .opacity(working ? 1 : 0.4)
    }

    private func gateBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption.weight(.black))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Color(hexString: goldHex), in: Circle())
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

// MARK: - Helpers (widget target-wide)

extension Color {
    init(hexString: String) {
        let clean = hexString.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
