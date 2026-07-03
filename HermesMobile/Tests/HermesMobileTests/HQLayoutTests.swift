import XCTest
import SceneKit
@testable import HermesMobile

final class HQLayoutTests: XCTestCase {

    private func agent(_ id: String, _ tier: OrgAgent.Tier) -> OrgAgent {
        OrgAgent(id: id, name: id, title: id, summary: "", tier: tier,
                 parent: nil, accentHex: "1C7A55", profileSlug: "default")
    }

    func testCEOGoesToExecutiveWing() {
        let org = [agent("gm", .ceo), agent("cto", .manager), agent("research", .manager)]
        let placements = HQLayout.placements(for: org)
        XCTAssertEqual(placements.first { $0.agent.id == "gm" }?.archetype, .executive)
    }

    func testTwoManagersFillResearchAndEngineering() {
        let org = [agent("gm", .ceo), agent("cto", .manager), agent("research", .manager)]
        let archetypes = Set(HQLayout.placements(for: org)
            .filter { $0.agent.tier == .manager }
            .map { $0.archetype })
        XCTAssertEqual(archetypes, [.researchLab, .engineeringDen])
    }

    func testSliceCapsAtThreeAgents() {
        let org = (0..<9).map { agent("m\($0)", $0 == 0 ? .ceo : .manager) }
        XCTAssertLessThanOrEqual(HQLayout.placements(for: org).count, 3)
    }
}
