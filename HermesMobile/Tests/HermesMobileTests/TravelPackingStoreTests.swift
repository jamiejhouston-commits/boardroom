import XCTest
@testable import HermesMobile

@MainActor
final class TravelPackingStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let storageKey = "travelPackingChecklistLite.tests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "TravelPackingStoreTests-\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removeObject(forKey: storageKey)
        defaults = nil
        super.tearDown()
    }

    private var defaultsSuiteName: String {
        defaults.dictionaryRepresentation()["suiteName"] as? String ?? "TravelPackingStoreTests"
    }

    func testCreatesTripFromExactTemplateAndPersistsPackedState() {
        let store = TravelPackingStore(defaults: defaults, storageKey: storageKey)
        let trip = store.createTrip(name: "  Client conference  ", type: .business)

        XCTAssertEqual(trip?.name, "Client conference")
        XCTAssertEqual(trip?.tripType, .business)
        XCTAssertEqual(trip?.items.map(\.title), ["Dress shirts", "Dress pants", "Blazer", "Laptop", "Laptop charger", "Business shoes", "Toiletries"])

        guard let tripID = trip?.id, let firstItemID = trip?.items.first?.id else {
            return XCTFail("Expected created trip and first item")
        }

        store.toggleItem(tripID: tripID, itemID: firstItemID)
        XCTAssertEqual(store.trip(with: tripID)?.packedCount, 1)

        let reloaded = TravelPackingStore(defaults: defaults, storageKey: storageKey)
        XCTAssertEqual(reloaded.trip(with: tripID)?.packedCount, 1)
        XCTAssertEqual(reloaded.trip(with: tripID)?.items.first?.isPacked, true)
    }

    func testBlocksEmptyNamesAndPreservesPackedStateWhenEditingItem() {
        let store = TravelPackingStore(defaults: defaults, storageKey: storageKey)
        XCTAssertNil(store.createTrip(name: "   ", type: .weekend))

        let trip = store.createTrip(name: "Weekend", type: .weekend)!
        let custom = store.addItem(to: trip.id, title: "  Camera  ")!
        store.toggleItem(tripID: trip.id, itemID: custom.id)

        XCTAssertFalse(store.updateItem(tripID: trip.id, itemID: custom.id, title: "   "))
        XCTAssertTrue(store.updateItem(tripID: trip.id, itemID: custom.id, title: "Camera batteries"))

        let updated = store.trip(with: trip.id)?.items.first { $0.id == custom.id }
        XCTAssertEqual(updated?.title, "Camera batteries")
        XCTAssertEqual(updated?.isPacked, true)
    }

    func testDeletesOneItemAndOneTripOnly() {
        let store = TravelPackingStore(defaults: defaults, storageKey: storageKey)
        let beach = store.createTrip(name: "Beach", type: .beach)!
        let camping = store.createTrip(name: "Camping", type: .camping)!

        let beachFirst = beach.items[0]
        store.deleteItem(tripID: beach.id, itemID: beachFirst.id)

        XCTAssertNil(store.trip(with: beach.id)?.items.first { $0.id == beachFirst.id })
        XCTAssertEqual(store.trip(with: camping.id)?.items.count, PackingTripType.camping.templateItems.count)

        store.deleteTrip(id: beach.id)
        XCTAssertNil(store.trip(with: beach.id))
        XCTAssertNotNil(store.trip(with: camping.id))
    }
}
