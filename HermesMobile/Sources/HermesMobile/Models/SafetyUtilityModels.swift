import Foundation

enum EarthquakeReadinessStatus: String, Codable, CaseIterable, Identifiable {
    case notStarted = "Not started"
    case inProgress = "In progress"
    case ready = "Ready"

    var id: String { rawValue }
}

struct EarthquakeReadyTask: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var detail: String
    var isDone: Bool

    init(id: UUID = UUID(), title: String, detail: String, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isDone = isDone
    }
}

struct EmergencyContact: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var phone: String

    init(id: UUID = UUID(), name: String, phone: String) {
        self.id = id
        self.name = name
        self.phone = phone
    }
}

struct EarthquakeReadyPlan: Codable, Equatable {
    var tasks: [EarthquakeReadyTask]
    var contacts: [EmergencyContact]
    var meetingPlace: String
    var lastDrillAt: Date?

    var completedCount: Int { tasks.filter(\.isDone).count }
    var totalCount: Int { tasks.count }
    var progressText: String { "\(completedCount)/\(totalCount) ready" }
    var readinessStatus: EarthquakeReadinessStatus {
        if completedCount == 0 { return .notStarted }
        if completedCount == totalCount { return .ready }
        return .inProgress
    }

    static let starter = EarthquakeReadyPlan(
        tasks: [
            EarthquakeReadyTask(title: "Water stored", detail: "Keep at least 3 days of drinking water for the household."),
            EarthquakeReadyTask(title: "First aid kit ready", detail: "Bandages, antiseptic, pain relief, gloves, and prescriptions."),
            EarthquakeReadyTask(title: "Flashlight and batteries", detail: "Place a flashlight where everyone can find it in the dark."),
            EarthquakeReadyTask(title: "Family meeting place", detail: "Choose one safe outdoor meeting point after shaking stops."),
            EarthquakeReadyTask(title: "Emergency contacts", detail: "Save at least one local and one out-of-area contact."),
            EarthquakeReadyTask(title: "Heavy items secured", detail: "Move or secure shelves, mirrors, and heavy objects that can fall."),
            EarthquakeReadyTask(title: "Drop, cover, hold drill", detail: "Practice the 60-second response with everyone at home.")
        ],
        contacts: [],
        meetingPlace: "",
        lastDrillAt: nil
    )
}

enum AirQualityWindowRecommendation: String, Codable, Equatable {
    case open = "Open windows"
    case keepClosed = "Keep windows closed"
    case caution = "Ventilate briefly"

    var systemImage: String {
        switch self {
        case .open: "wind"
        case .keepClosed: "window.ceiling.closed"
        case .caution: "exclamationmark.triangle.fill"
        }
    }

    var explanation: String {
        switch self {
        case .open: "Outdoor air is clean enough compared with your indoor reading."
        case .keepClosed: "Outdoor air is above your safe threshold or worse than indoors."
        case .caution: "Air is borderline. Open briefly only if you need ventilation."
        }
    }
}

struct AirQualityReading: Identifiable, Codable, Equatable {
    let id: UUID
    var outdoorAQI: Int
    var indoorAQI: Int
    var safeOutdoorLimit: Int
    var createdAt: Date

    init(id: UUID = UUID(), outdoorAQI: Int, indoorAQI: Int, safeOutdoorLimit: Int = 50, createdAt: Date = Date()) {
        self.id = id
        self.outdoorAQI = outdoorAQI
        self.indoorAQI = indoorAQI
        self.safeOutdoorLimit = safeOutdoorLimit
        self.createdAt = createdAt
    }

    var recommendation: AirQualityWindowRecommendation {
        if outdoorAQI <= safeOutdoorLimit && outdoorAQI + 10 < indoorAQI {
            return .open
        }
        if outdoorAQI <= safeOutdoorLimit + 25 && outdoorAQI < indoorAQI {
            return .caution
        }
        return .keepClosed
    }

    var summary: String {
        "Outside \(outdoorAQI) · Inside \(indoorAQI) · Limit \(safeOutdoorLimit)"
    }
}
