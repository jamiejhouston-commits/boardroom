import Foundation

@MainActor
final class TravelPackingStore: ObservableObject {
    @Published private(set) var trips: [PackingTrip] = []

    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, storageKey: String = "travelPackingChecklistLite.trips") {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    @discardableResult
    func createTrip(name rawName: String, type: PackingTripType) -> PackingTrip? {
        let name = sanitized(rawName)
        guard !name.isEmpty else { return nil }

        let now = Date()
        let trip = PackingTrip(
            name: name,
            tripType: type,
            createdAt: now,
            updatedAt: now,
            items: type.makeItems(createdAt: now)
        )
        trips.insert(trip, at: 0)
        save()
        return trip
    }

    func deleteTrip(id: PackingTrip.ID) {
        trips.removeAll { $0.id == id }
        save()
    }

    func toggleItem(tripID: PackingTrip.ID, itemID: PackingChecklistItem.ID) {
        guard let tripIndex = trips.firstIndex(where: { $0.id == tripID }),
              let itemIndex = trips[tripIndex].items.firstIndex(where: { $0.id == itemID }) else { return }
        trips[tripIndex].items[itemIndex].isPacked.toggle()
        touchTrip(at: tripIndex)
    }

    @discardableResult
    func addItem(to tripID: PackingTrip.ID, title rawTitle: String) -> PackingChecklistItem? {
        let title = sanitized(rawTitle)
        guard !title.isEmpty, let tripIndex = trips.firstIndex(where: { $0.id == tripID }) else { return nil }

        let item = PackingChecklistItem(title: title)
        trips[tripIndex].items.append(item)
        touchTrip(at: tripIndex)
        return item
    }

    func updateItem(tripID: PackingTrip.ID, itemID: PackingChecklistItem.ID, title rawTitle: String) -> Bool {
        let title = sanitized(rawTitle)
        guard !title.isEmpty,
              let tripIndex = trips.firstIndex(where: { $0.id == tripID }),
              let itemIndex = trips[tripIndex].items.firstIndex(where: { $0.id == itemID }) else { return false }

        trips[tripIndex].items[itemIndex].title = title
        touchTrip(at: tripIndex)
        return true
    }

    func deleteItem(tripID: PackingTrip.ID, itemID: PackingChecklistItem.ID) {
        guard let tripIndex = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[tripIndex].items.removeAll { $0.id == itemID }
        touchTrip(at: tripIndex)
    }

    func trip(with id: PackingTrip.ID) -> PackingTrip? {
        trips.first { $0.id == id }
    }

    func resetAllTrips() {
        trips = []
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            trips = []
            return
        }

        do {
            trips = try decoder.decode([PackingTrip].self, from: data)
        } catch {
            trips = []
        }
    }

    private func save() {
        guard let data = try? encoder.encode(trips) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func touchTrip(at index: Int) {
        trips[index].updatedAt = Date()
        save()
    }

    private func sanitized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
