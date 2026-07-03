import Foundation

struct PackingChecklistItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var isPacked: Bool
    let createdAt: Date

    init(id: UUID = UUID(), title: String, isPacked: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.isPacked = isPacked
        self.createdAt = createdAt
    }
}

struct PackingTrip: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var tripType: PackingTripType
    let createdAt: Date
    var updatedAt: Date
    var items: [PackingChecklistItem]

    var packedCount: Int { items.filter(\.isPacked).count }
    var progressText: String { "\(packedCount)/\(items.count) packed" }

    init(
        id: UUID = UUID(),
        name: String,
        tripType: PackingTripType,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        items: [PackingChecklistItem]
    ) {
        self.id = id
        self.name = name
        self.tripType = tripType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.items = items
    }
}

enum PackingTripType: String, CaseIterable, Codable, Identifiable, Equatable {
    case weekend = "Weekend Trip"
    case business = "Business Trip"
    case beach = "Beach Trip"
    case camping = "Camping Trip"
    case international = "International Trip"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .weekend: "bag.fill"
        case .business: "briefcase.fill"
        case .beach: "sun.max.fill"
        case .camping: "tent.fill"
        case .international: "globe.europe.africa.fill"
        }
    }

    var templateItems: [String] {
        switch self {
        case .weekend:
            ["Shirts", "Pants", "Underwear", "Socks", "Toiletries", "Phone charger", "Pajamas"]
        case .business:
            ["Dress shirts", "Dress pants", "Blazer", "Laptop", "Laptop charger", "Business shoes", "Toiletries"]
        case .beach:
            ["Swimsuit", "Towel", "Sunscreen", "Sandals", "Sunglasses", "Hat", "Toiletries"]
        case .camping:
            ["Tent", "Sleeping bag", "Flashlight", "Water bottle", "Snacks", "Jacket", "Toiletries"]
        case .international:
            ["Passport", "Travel adapter", "Phone charger", "Toiletries", "Underwear", "Socks", "Medications"]
        }
    }

    func makeItems(createdAt: Date = Date()) -> [PackingChecklistItem] {
        templateItems.map { PackingChecklistItem(title: $0, createdAt: createdAt) }
    }
}
