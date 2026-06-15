import SwiftUI

/// Schedule a meeting with agents: picks attendees, syncs to the user's
/// Apple Calendar (15-minute alarm) and optionally sends a prep memo with
/// expectations and deliverables.
struct ScheduleMeetingView: View {
    @EnvironmentObject private var org: OrgStore
    @EnvironmentObject private var hub: MeetingHub
    @EnvironmentObject private var runtime: HermesRuntimeController
    @Environment(\.dismiss) private var dismiss

    var prefillTopic: String = ""
    @State private var topic = ""
    @State private var date = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @State private var selected: Set<String> = []
    @State private var sendBrief = true
    @State private var briefBody = ""
    @State private var scheduling = false
    @State private var resultMessage: String?

    private var canSchedule: Bool {
        !topic.trimmingCharacters(in: .whitespaces).isEmpty && !selected.isEmpty && !scheduling
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Meeting") {
                    TextField("Topic (e.g. Q2 Strategy Review)", text: $topic)
                    DatePicker("When", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }

                Section {
                    ForEach(org.leadership + org.agents.filter { $0.tier == .sub }) { agent in
                        Button {
                            if selected.contains(agent.id) { selected.remove(agent.id) }
                            else { selected.insert(agent.id) }
                        } label: {
                            HStack {
                                Image(systemName: agent.systemImage)
                                    .foregroundStyle(Color(hex: agent.accentHex))
                                    .frame(width: 26)
                                Text(agent.name).foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(agent.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(HermesTheme.emerald)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Attendees (\(selected.count))")
                }

                Section {
                    Toggle("Send prep memo", isOn: $sendBrief)
                    if sendBrief {
                        TextEditor(text: $briefBody)
                            .frame(minHeight: 110)
                            .overlay(alignment: .topLeading) {
                                if briefBody.isEmpty {
                                    Text("What to prepare, what you expect, deliverables…")
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 8).padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                } header: {
                    Text("Internal memo")
                } footer: {
                    Text("Each attendee receives the memo and replies with what they'll prepare and the deliverables they'll bring. Replies land in Memos.")
                }
            }
            .navigationTitle("Schedule Meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(scheduling ? "Scheduling…" : "Schedule") { Task { await schedule() } }
                        .disabled(!canSchedule)
                }
            }
            .alert("Meeting scheduled", isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil; dismiss() } }
            )) {
                Button("Done") { resultMessage = nil; dismiss() }
            } message: {
                Text(resultMessage ?? "")
            }
            .onAppear { if topic.isEmpty { topic = prefillTopic } }
        }
    }

    private func schedule() async {
        scheduling = true
        let attendees = org.agents.filter { selected.contains($0.id) }
        let outcome = await hub.schedule(
            topic: topic.trimmingCharacters(in: .whitespaces),
            date: date,
            attendees: attendees,
            memoSubject: sendBrief ? topic : nil,
            memoBody: sendBrief ? briefBody : nil,
            relay: runtime.relayConfiguration
        )
        scheduling = false
        // Only claim the memo went out if it actually could: relay connected.
        let memoNote: String
        if sendBrief {
            memoNote = runtime.relayConfiguration.isConfigured
                ? " Prep memo sent to \(attendees.count) agents — replies land in Memos."
                : " Prep memo saved, but it was NOT delivered: connect your relay (Settings → Mac Relay)."
        } else {
            memoNote = ""
        }
        switch outcome {
        case .added:
            resultMessage = "Added to your calendar with a 15-minute alert." + memoNote
        case .denied:
            resultMessage = "Calendar access was declined — the meeting is saved in Hermes and you'll still get the 15-minute notification." + memoNote
        case .failed(let why):
            resultMessage = "Saved in Hermes, but the calendar event failed: \(why)" + memoNote
        }
    }
}
