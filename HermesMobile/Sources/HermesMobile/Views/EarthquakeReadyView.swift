import SwiftUI

struct EarthquakeReadyHomeView: View {
    @StateObject private var store = EarthquakeReadyStore()
    @State private var meetingPlaceDraft = ""
    @State private var contactName = ""
    @State private var contactPhone = ""

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Earthquake Ready Alert", systemImage: "waveform.path.ecg.rectangle.fill")
                            .font(.headline.weight(.bold))
                        Spacer()
                        Text(store.plan.readinessStatus.rawValue)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(statusColor.opacity(0.16), in: Capsule())
                            .foregroundStyle(statusColor)
                    }
                    ProgressView(value: Double(store.plan.completedCount), total: Double(max(store.plan.totalCount, 1)))
                        .tint(statusColor)
                    Text(store.plan.progressText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HermesTheme.textPrimary)
                    Text("A fast local readiness checklist, emergency contact list, meeting place, and drill reminder. No account, no network, no fake emergency data.")
                        .font(.caption)
                        .foregroundStyle(HermesTheme.textSecondary)
                }
                .padding(.vertical, 6)
            }

            Section("Readiness checklist") {
                ForEach(store.plan.tasks) { task in
                    Button { store.toggleTask(id: task.id) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(task.isDone ? HermesTheme.emerald : HermesTheme.textSecondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(HermesTheme.textPrimary)
                                Text(task.detail)
                                    .font(.caption)
                                    .foregroundStyle(HermesTheme.textSecondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(task.isDone ? "Mark \(task.title) not ready" : "Mark \(task.title) ready")
                }
            }

            Section("Family meeting place") {
                TextField("Example: front gate / nearest open field", text: $meetingPlaceDraft, axis: .vertical)
                    .lineLimit(1...3)
                Button("Save meeting place") {
                    store.updateMeetingPlace(meetingPlaceDraft)
                }
                .disabled(meetingPlaceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !store.plan.meetingPlace.isEmpty {
                    Label(store.plan.meetingPlace, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                }
            }

            Section("Emergency contacts") {
                TextField("Name", text: $contactName)
                    .textInputAutocapitalization(.words)
                TextField("Phone", text: $contactPhone)
                    .keyboardType(.phonePad)
                Button("Add contact") {
                    if store.addContact(name: contactName, phone: contactPhone) != nil {
                        contactName = ""
                        contactPhone = ""
                    }
                }
                .disabled(contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || contactPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                ForEach(store.plan.contacts) { contact in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(contact.name).font(.subheadline.weight(.semibold))
                            Text(contact.phone).font(.caption).foregroundStyle(HermesTheme.textSecondary)
                        }
                        Spacer()
                        Link(destination: URL(string: "tel://\(contact.phone.filter(\.isNumber))") ?? URL(string: "tel://")!) {
                            Image(systemName: "phone.fill")
                        }
                        .disabled(contact.phone.filter(\.isNumber).isEmpty)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { store.deleteContact(id: store.plan.contacts[index].id) }
                }
            }

            Section("Alert") {
                Button {
                    store.markDrillNow()
                    Task { await store.scheduleDrillReminder() }
                } label: {
                    Label("Mark drill done + remind me later", systemImage: "bell.badge.fill")
                }
                if let lastDrillAt = store.plan.lastDrillAt {
                    Text("Last drill: \(lastDrillAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(HermesTheme.textSecondary)
                }
            }
        }
        .navigationTitle("Earthquake Ready")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { meetingPlaceDraft = store.plan.meetingPlace }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset", role: .destructive) {
                    store.reset()
                    meetingPlaceDraft = ""
                }
            }
        }
    }

    private var statusColor: Color {
        switch store.plan.readinessStatus {
        case .notStarted: .orange
        case .inProgress: HermesTheme.gold
        case .ready: HermesTheme.emerald
        }
    }
}

#Preview {
    NavigationStack { EarthquakeReadyHomeView() }
}
