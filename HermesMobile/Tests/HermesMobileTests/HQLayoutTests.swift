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

    func testFloorCapsAtMaxAgents() {
        // A big org fills every seat but never exceeds the GPU-budget cap.
        let org = (0..<14).map { agent("m\($0)", $0 == 0 ? .ceo : ($0 < 4 ? .manager : .sub)) }
        let placements = HQLayout.placements(for: org)
        XCTAssertEqual(placements.count, HQLayout.maxAgents)
    }

    func testStaffFillsOverflowSeatsInOrder() {
        // CEO + 2 pod leads first, then everyone else takes the console posts,
        // second pod desks, and lounge — in org order.
        let org = [agent("gm", .ceo),
                   agent("cto", .manager), agent("research", .manager),
                   agent("dev1", .sub), agent("dev2", .sub), agent("dev3", .sub)]
        let placements = HQLayout.placements(for: org)
        XCTAssertEqual(placements.first { $0.agent.id == "dev1" }?.archetype, .commandEast)
        XCTAssertEqual(placements.first { $0.agent.id == "dev2" }?.archetype, .commandWest)
        XCTAssertEqual(placements.first { $0.agent.id == "dev3" }?.archetype, .researchLab2)
    }

    func testEverySeatHasAnAnchorAndYaw() {
        // The layout leans on the builder's anchor tables — a new archetype
        // without an anchor would silently drop an agent from the floor.
        for archetype in HQOfficeArchetype.allCases where archetype != .command {
            XCTAssertNotNil(HQSceneBuilder.zoneAnchors[archetype], "\(archetype) missing anchor")
            XCTAssertNotNil(HQSceneBuilder.zoneYaw[archetype], "\(archetype) missing yaw")
        }
    }

    func testNoAgentSeatedTwiceAndNoSeatReused() {
        let org = (0..<10).map { agent("a\($0)", $0 == 0 ? .ceo : ($0 < 3 ? .manager : .sub)) }
        let placements = HQLayout.placements(for: org)
        XCTAssertEqual(Set(placements.map(\.agent.id)).count, placements.count)
        XCTAssertEqual(Set(placements.map(\.archetype)).count, placements.count)
    }
}
