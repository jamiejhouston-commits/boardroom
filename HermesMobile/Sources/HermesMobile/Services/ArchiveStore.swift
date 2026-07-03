import Foundation

/// A finished initiative the owner archived out of the Boardroom History list.
/// A local, phone-side snapshot — archiving is a personal tidy-up layer that
/// never touches the company engine on the Mac.
struct ArchivedInitiative: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var pitch: String
    var stage: String          // "killed" | "shipped" | "blocked" at archive time
    var repoUrl: String?
    var archivedAt: Date

    init(id: String, title: String, pitch: String, stage: String,
         repoUrl: String?, archivedAt: Date) {
        self.id = id
        self.title = title
        self.pitch = pitch
        self.stage = stage
        self.repoUrl = repoUrl
        self.archivedAt = archivedAt
    }

    init(from initiative: CompanyInitiative, at date: Date = Date()) {
        self.init(id: initiative.id, title: initiative.title, pitch: initiative.pitch,
                  stage: initiative.stage, repoUrl: initiative.repoUrl, archivedAt: date)
    }
}

/// The shelf an archived item lands on — auto-filed by outcome, no manual sorting.
enum ArchiveCategory: String, CaseIterable, Identifiable {
    case shipped, killed, blocked, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .shipped: "Shipped"
        case .killed:  "Killed"
        case .blocked: "Blocked"
        case .other:   "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .shipped: "shippingbox.fill"
        case .killed:  "xmark.bin.fill"
        case .blocked: "exclamationmark.octagon.fill"
        case .other:   "archivebox.fill"
        }
    }

    static func of(stage: String) -> ArchiveCategory {
        switch stage {
        case "shipped": .shipped
        case "killed":  .killed
        case "blocked": .blocked
        default:        .other
        }
    }
}

/// Local store of archived initiatives, persisted as JSON in UserDefaults.
/// Boardroom hides these from History; `ArchiveView` shows them grouped by
/// outcome. Fully decoupled from the relay — this is the owner's view layer.
@MainActor
final class ArchiveStore: ObservableObject {
    @Published private(set) var archived: [ArchivedInitiative] = []

    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, storageKey: String = "boardroom.archivedInitiatives") {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    var archivedIDs: Set<String> { Set(archived.map(\.id)) }

    func isArchived(_ id: String) -> Bool { archivedIDs.contains(id) }

    /// File a finished initiative away. No-op if it's already archived.
    func archive(_ initiative: CompanyInitiative) {
        guard !isArchived(initiative.id) else { return }
        archived.insert(ArchivedInitiative(from: initiative), at: 0)
        save()
    }

    /// Bring an item back — it reappears in Boardroom History.
    func restore(id: String) {
        archived.removeAll { $0.id == id }
        save()
    }

    /// Archived items on one shelf, newest first.
    func items(in category: ArchiveCategory) -> [ArchivedInitiative] {
        archived
            .filter { ArchiveCategory.of(stage: $0.stage) == category }
            .sorted { $0.archivedAt > $1.archivedAt }
    }

    /// The shelves that actually have something on them, in display order.
    var populatedCategories: [ArchiveCategory] {
        ArchiveCategory.allCases.filter { !items(in: $0).isEmpty }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            archived = []
            return
        }
        do {
            archived = try decoder.decode([ArchivedInitiative].self, from: data)
        } catch {
            archived = []
        }
    }

    private func save() {
        guard let data = try? encoder.encode(archived) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
