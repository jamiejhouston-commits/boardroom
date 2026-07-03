import Foundation
import UserNotifications

@MainActor
final class EarthquakeReadyStore: ObservableObject {
    @Published private(set) var plan: EarthquakeReadyPlan

    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, storageKey: String = "earthquakeReadyAlert.plan") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let saved = try? decoder.decode(EarthquakeReadyPlan.self, from: data) {
            self.plan = saved
        } else {
            self.plan = .starter
        }
    }

    func toggleTask(id: EarthquakeReadyTask.ID) {
        guard let index = plan.tasks.firstIndex(where: { $0.id == id }) else { return }
        plan.tasks[index].isDone.toggle()
        save()
    }

    func updateMeetingPlace(_ value: String) {
        plan.meetingPlace = value.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    @discardableResult
    func addContact(name rawName: String, phone rawPhone: String) -> EmergencyContact? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = rawPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !phone.isEmpty else { return nil }
        let contact = EmergencyContact(name: name, phone: phone)
        plan.contacts.append(contact)
        save()
        return contact
    }

    func deleteContact(id: EmergencyContact.ID) {
        plan.contacts.removeAll { $0.id == id }
        save()
    }

    func markDrillNow() {
        plan.lastDrillAt = Date()
        save()
    }

    func reset() {
        plan = .starter
        save()
    }

    func scheduleDrillReminder(after interval: TimeInterval = 8 * 60 * 60) async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Earthquake drill check"
            content.body = "Run a 60-second drop, cover, hold drill and verify your kit."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 60), repeats: false)
            let request = UNNotificationRequest(identifier: "earthquake-ready-drill", content: content, trigger: trigger)
            try await center.add(request)
        } catch {
            // Notifications are a convenience; the saved preparedness plan is the core MVP.
        }
    }

    private func save() {
        guard let data = try? encoder.encode(plan) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
