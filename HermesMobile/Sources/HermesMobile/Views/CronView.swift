import SwiftUI

/// The Cron: recurring automations the owner sets so the company acts on its
/// own schedule — pitch a fresh idea every morning, ask for a status summary
/// every Monday, and so on. Fired by the relay heartbeat.
struct CronView: View {
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @State private var showAdd = false

    var body: some View {
        List {
            if company.schedules.isEmpty {
                Section {
                    Text("No automations yet. Tap + to have the company pitch fresh ideas or answer a recurring question on a schedule — all on its own.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Automations") {
                    ForEach(company.schedules) { schedule in
                        row(schedule)
                    }
                }
            }

            if !company.state.enabled {
                Section {
                    Label("Switch Company running on (Boardroom) — automations only fire while it's on.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .task { await company.refresh(relay: runtime.relayConfiguration) }
        .sheet(isPresented: $showAdd) { AddScheduleSheet() }
    }

    private func row(_ schedule: CompanySchedule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: scheduleIcon(schedule.kind))
                .foregroundStyle(HermesTheme.emerald)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.title).font(.subheadline.weight(.semibold))
                Text("\(schedule.kindLabel) · \(schedule.cadenceSummary)")
                    .font(.caption).foregroundStyle(HermesTheme.emerald)
                Text(schedule.text).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { schedule.enabled },
                set: { on in
                    Task { await company.toggleSchedule(id: schedule.id, enabled: on,
                                                        relay: runtime.relayConfiguration) }
                }
            ))
            .labelsHidden()
            .tint(HermesTheme.emerald)
        }
        .swipeActions {
            Button(role: .destructive) {
                Task { await company.deleteSchedule(id: schedule.id, relay: runtime.relayConfiguration) }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func scheduleIcon(_ kind: String) -> String {
        switch kind {
        case "ask":     return "bubble.left.and.text.bubble.right.fill"
        case "meeting": return "person.2.wave.2.fill"
        default:        return "lightbulb.fill"
        }
    }
}

private struct AddScheduleSheet: View {
    @EnvironmentObject private var company: CompanyStore
    @EnvironmentObject private var runtime: HermesRuntimeController
    @Environment(\.dismiss) private var dismiss

    @State private var kind = "directive"
    @State private var title = ""
    @State private var text = ""
    @State private var cadence = "daily"
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var weekday = 0

    private let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private var placeholder: String {
        switch kind {
        case "ask":     return "The question to ask"
        case "meeting": return "Meeting topic — e.g. weekly review of our initiatives"
        default:        return "The idea or directive"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    Text("Pitch an idea").tag("directive")
                    Text("Ask the company").tag("ask")
                    Text("Office hours").tag("meeting")
                }
                .pickerStyle(.segmented)

                Section("What to run") {
                    TextField("Short title", text: $title)
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("When") {
                    Picker("Repeat", selection: $cadence) {
                        Text("Hourly").tag("hourly")
                        Text("Daily").tag("daily")
                        Text("Weekly").tag("weekly")
                    }
                    if cadence == "weekly" {
                        Picker("Day", selection: $weekday) {
                            ForEach(0..<7, id: \.self) { Text(weekdays[$0]).tag($0) }
                        }
                    }
                    DatePicker(cadence == "hourly" ? "Minute past the hour" : "Time",
                               selection: $time, displayedComponents: .hourAndMinute)
                }
            }
            .navigationTitle("New automation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func add() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        Task {
            await company.addSchedule(title: title, kind: kind, text: text, cadence: cadence,
                                      atHour: comps.hour ?? 9, atMinute: comps.minute ?? 0,
                                      weekday: weekday, relay: runtime.relayConfiguration)
            dismiss()
        }
    }
}
