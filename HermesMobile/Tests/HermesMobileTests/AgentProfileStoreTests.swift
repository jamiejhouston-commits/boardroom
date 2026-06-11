import XCTest
@testable import HermesMobile

@MainActor
final class AgentProfileStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testLoadSeedsProfilesAndSoulFiles() throws {
        let store = AgentProfileStore(rootURL: tempRoot)
        store.load()

        XCTAssertEqual(store.agents.count, 3)

        let first = try XCTUnwrap(store.agents.first)
        let soulPath = store.fileLocationLabel(for: first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: soulPath))
        XCTAssertTrue(try String(contentsOfFile: soulPath).contains("# \(first.handle)"))
    }

    func testSoulUpdatePersistsAcrossStoreReload() throws {
        let store = AgentProfileStore(rootURL: tempRoot)
        store.load()

        let agent = try XCTUnwrap(store.agents.first)
        let updatedSoul = "# \(agent.handle)\n\nRun as the iPhone-native Hermes coordinator."
        store.updateSoul(for: agent, soulMarkdown: updatedSoul)

        let reloaded = AgentProfileStore(rootURL: tempRoot)
        reloaded.load()

        let reloadedAgent = try XCTUnwrap(reloaded.agents.first { $0.id == agent.id })
        XCTAssertEqual(reloadedAgent.soulMarkdown, updatedSoul)
    }
}
