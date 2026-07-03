import Foundation
import UserNotifications

@MainActor
final class AirQualityWindowStore: ObservableObject {
    @Published private(set) var readings: [AirQualityReading]

    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, storageKey: String = "airQualityWindowAlert.readings") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let saved = try? decoder.decode([AirQualityReading].self, from: data) {
            self.readings = saved
        } else {
            self.readings = []
        }
    }

    var latest: AirQualityReading? { readings.first }

    @discardableResult
    func saveReading(outdoorAQI: Int, indoorAQI: Int, safeOutdoorLimit: Int = 50) -> AirQualityReading? {
        guard (0...500).contains(outdoorAQI),
              (0...500).contains(indoorAQI),
              (0...500).contains(safeOutdoorLimit) else { return nil }
        let reading = AirQualityReading(outdoorAQI: outdoorAQI, indoorAQI: indoorAQI, safeOutdoorLimit: safeOutdoorLimit)
        readings.insert(reading, at: 0)
        readings = Array(readings.prefix(20))
        save()
        return reading
    }

    func deleteReading(id: AirQualityReading.ID) {
        readings.removeAll { $0.id == id }
        save()
    }

    func reset() {
        readings = []
        save()
    }

    func notifyForLatestReading() async {
        guard let latest else { return }
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = latest.recommendation.rawValue
            content.body = latest.summary + " — " + latest.recommendation.explanation
            content.sound = .default
            let request = UNNotificationRequest(identifier: "air-quality-window-latest", content: content, trigger: nil)
            try await center.add(request)
        } catch {
            // Manual reading and recommendation still remain available if notifications are denied.
        }
    }

    private func save() {
        guard let data = try? encoder.encode(readings) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
