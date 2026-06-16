import SwiftUI
import WidgetKit

/// Home- and lock-screen widgets showing the Boardroom company at a glance.
/// Reads the precomputed CompanySnapshot from the shared App Group container
/// (written by the app) — no network in the widget process.

struct CompanyStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: CompanySnapshot
}

struct CompanyStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> CompanyStatusEntry {
        CompanyStatusEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (CompanyStatusEntry) -> Void) {
        completion(CompanyStatusEntry(date: Date(), snapshot: CompanySharedStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CompanyStatusEntry>) -> Void) {
        let entry = CompanyStatusEntry(date: Date(), snapshot: CompanySharedStore.read())
        // The app pushes reloads via WidgetCenter on every refresh; this periodic
        // re-read is just a safety net so the widget never goes fully stale.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct CompanyStatusWidget: Widget {
    private let emerald = Color(hexString: "1C7A55")

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CompanyStatusWidget", provider: CompanyStatusProvider()) { entry in
            CompanyStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Company Status")
        .description("Your Boardroom company at a glance — decisions waiting, what's building, task progress.")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

private struct CompanyStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CompanyStatusEntry

    private var snap: CompanySnapshot { entry.snapshot }
    private var emerald: Color { Color(hexString: "1C7A55") }
    private var gold: Color { Color(hexString: "C7A35A") }
    private var accent: Color { snap.pendingGates > 0 ? gold : emerald }

    var body: some View {
        content
            .containerBackground(for: .widget) { containerBackground }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:        small
        case .systemMedium:       medium
        case .accessoryRectangular: rectangular
        case .accessoryCircular:  circular
        case .accessoryInline:    inline
        default:                  small
        }
    }

    @ViewBuilder
    private var containerBackground: some View {
        switch family {
        case .accessoryRectangular, .accessoryCircular, .accessoryInline:
            Color.clear
        default:
            LinearGradient(colors: [Color(hexString: "0E1726"), Color(hexString: "182338")],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: Home — small

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusDot
                Text("BOARDROOM")
                    .font(.caption2.weight(.black)).tracking(1)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if snap.pendingGates > 0 { gateBadge }
            }
            Spacer(minLength: 0)
            Text(snap.headline)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(snap.detail)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
            Spacer(minLength: 0)
            if snap.tasksTotal > 0 { taskBar } else { Text(snap.statusLine).font(.caption2.weight(.semibold)).foregroundStyle(accent) }
        }
    }

    // MARK: Home — medium

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    statusDot
                    Text("BOARDROOM").font(.caption2.weight(.black)).tracking(1)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
                Text(snap.headline).font(.headline.weight(.bold))
                    .foregroundStyle(.white).lineLimit(2)
                Text(snap.detail).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                Spacer(minLength: 0)
                Text(snap.statusLine).font(.caption2.weight(.semibold)).foregroundStyle(accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                if snap.pendingGates > 0 {
                    VStack(spacing: 2) {
                        Text("\(snap.pendingGates)").font(.title.weight(.black)).foregroundStyle(gold)
                        Text(snap.pendingGates == 1 ? "decision" : "decisions")
                            .font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
                stat("To Do", snap.tasksTodo, .white.opacity(0.7))
                stat("Building", snap.tasksDoing, gold)
                stat("Done", snap.tasksDone, emerald)
            }
            .frame(width: 92)
            .padding(.vertical, 2)
        }
    }

    // MARK: Lock — accessories

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: snap.pendingGates > 0 ? "gavel.fill" : "building.2.fill")
                    .font(.caption2)
                Text(snap.statusLine).font(.caption.weight(.bold))
            }
            Text(snap.headline).font(.caption2).lineLimit(2)
        }
        .widgetAccentable()
    }

    private var circular: some View {
        Group {
            if snap.tasksTotal > 0 {
                Gauge(value: Double(snap.tasksDone), in: 0...Double(max(snap.tasksTotal, 1))) {
                    Image(systemName: "checklist")
                } currentValueLabel: {
                    Text("\(snap.tasksDone)")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else if snap.pendingGates > 0 {
                VStack(spacing: 0) {
                    Image(systemName: "gavel.fill").font(.caption2)
                    Text("\(snap.pendingGates)").font(.headline.weight(.bold))
                }
            } else {
                Image(systemName: snap.enabled ? "building.2.fill" : "building.2")
                    .font(.title3)
            }
        }
        .widgetAccentable()
    }

    private var inline: some View {
        Label("Boardroom: \(snap.statusLine)",
              systemImage: snap.pendingGates > 0 ? "gavel.fill" : "building.2.fill")
    }

    // MARK: Pieces

    private var statusDot: some View {
        Circle().fill(snap.enabled ? accent : Color.gray)
            .frame(width: 7, height: 7)
    }

    private var gateBadge: some View {
        Text("\(snap.pendingGates)")
            .font(.caption2.weight(.black)).foregroundStyle(.white)
            .frame(width: 18, height: 18).background(gold, in: Circle())
    }

    private var taskBar: some View {
        HStack(spacing: 3) {
            bar(snap.tasksDone, emerald)
            bar(snap.tasksDoing, gold)
            bar(snap.tasksTodo, .white.opacity(0.25))
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }

    private func bar(_ count: Int, _ color: Color) -> some View {
        color.frame(maxWidth: .infinity).opacity(count > 0 ? 1 : 0.15)
    }

    private func stat(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text("\(value)").font(.caption.weight(.bold)).foregroundStyle(color)
        }
    }
}
