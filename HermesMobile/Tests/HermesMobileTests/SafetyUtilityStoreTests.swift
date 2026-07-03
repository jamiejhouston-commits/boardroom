import XCTest
@testable import HermesMobile

@MainActor
final class SafetyUtilityStoreTests: XCTestCase {
    func testEarthquakePlanPersistsChecklistMeetingPlaceAndContacts() {
        let suite = "EarthquakeReadyStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = EarthquakeReadyStore(defaults: defaults, storageKey: "earthquake.tests")
        let taskID = store.plan.tasks[0].id
        store.toggleTask(id: taskID)
        store.updateMeetingPlace("  Front gate  ")
        let contact = store.addContact(name: "  Neighbor  ", phone: " 555-0100 ")

        XCTAssertEqual(store.plan.completedCount, 1)
        XCTAssertEqual(store.plan.meetingPlace, "Front gate")
        XCTAssertEqual(contact?.name, "Neighbor")
        XCTAssertEqual(contact?.phone, "555-0100")

        let reloaded = EarthquakeReadyStore(defaults: defaults, storageKey: "earthquake.tests")
        XCTAssertEqual(reloaded.plan.completedCount, 1)
        XCTAssertEqual(reloaded.plan.meetingPlace, "Front gate")
        XCTAssertEqual(reloaded.plan.contacts.first?.name, "Neighbor")
    }

    func testAirQualityRecommendationPersistsAndRejectsInvalidReadings() {
        let suite = "AirQualityWindowStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AirQualityWindowStore(defaults: defaults, storageKey: "air.tests")
        XCTAssertNil(store.saveReading(outdoorAQI: 501, indoorAQI: 40, safeOutdoorLimit: 50))

        let openReading = store.saveReading(outdoorAQI: 30, indoorAQI: 55, safeOutdoorLimit: 50)
        let cautionReading = store.saveReading(outdoorAQI: 60, indoorAQI: 70, safeOutdoorLimit: 50)
        let closedReading = store.saveReading(outdoorAQI: 120, indoorAQI: 45, safeOutdoorLimit: 50)

        XCTAssertEqual(openReading?.recommendation, .open)
        XCTAssertEqual(cautionReading?.recommendation, .caution)
        XCTAssertEqual(closedReading?.recommendation, .keepClosed)
        XCTAssertEqual(store.readings.count, 3)

        let reloaded = AirQualityWindowStore(defaults: defaults, storageKey: "air.tests")
        XCTAssertEqual(reloaded.readings.count, 3)
        XCTAssertEqual(reloaded.latest?.recommendation, .keepClosed)
    }
}
