import XCTest
@testable import HermesMobile

@MainActor
final class ArchiveStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let storageKey = "boardroom.archivedInitiatives.tests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ArchiveStoreTests-\(UUID().uuidString)")!
    }

    override func tearDown() {
        defaults.removeObject(forKey: storageKey)
        defaults = nil
        super.tearDown()
    }

    private func initiative(_ id: String, stage: String, title: String = "Idea") -> CompanyInitiative {
        CompanyInitiative(id: id, title: title, pitch: "pitch", stage: stage, created: "",
                          score: nil, callsUsed: 0, brief: "", artifacts: [], note: "",
                          repoUrl: stage == "shipped" ? "https://example.com/repo" : nil,
                          origin: nil, minutes: nil)
    }

    func testArchivesFileByOutcomeAndPersistAcrossReload() {
        let store = ArchiveStore(defaults: defaults, storageKey: storageKey)
        store.archive(initiative("a", stage: "killed"))
        store.archive(initiative("b", stage: "shipped"))
        store.archive(initiative("c", stage: "blocked"))

        XCTAssertEqual(store.items(in: .killed).map(\.id), ["a"])
        XCTAssertEqual(store.items(in: .shipped).map(\.id), ["b"])
        XCTAssertEqual(store.items(in: .blocked).map(\.id), ["c"])
        // Auto-filed shelves appear in canonical order, only when populated.
        XCTAssertEqual(store.populatedCategories, [.shipped, .killed, .blocked])

        let reloaded = ArchiveStore(defaults: defaults, storageKey: storageKey)
        XCTAssertEqual(reloaded.archivedIDs, ["a", "b", "c"])
        XCTAssertEqual(reloaded.items(in: .shipped).first?.repoUrl, "https://example.com/repo")
    }

    func testArchiveIsIdempotentAndRestoreRemovesEverywhere() {
        let store = ArchiveStore(defaults: defaults, storageKey: storageKey)
        store.archive(initiative("a", stage: "killed"))
        store.archive(initiative("a", stage: "killed"))   // duplicate — must be ignored
        XCTAssertEqual(store.archived.count, 1)
        XCTAssertTrue(store.isArchived("a"))

        store.restore(id: "a")
        XCTAssertFalse(store.isArchived("a"))
        XCTAssertTrue(store.archived.isEmpty)

        let reloaded = ArchiveStore(defaults: defaults, storageKey: storageKey)
        XCTAssertTrue(reloaded.archived.isEmpty)
    }
}
