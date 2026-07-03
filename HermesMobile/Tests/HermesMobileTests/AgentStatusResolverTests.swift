import XCTest
@testable import HermesMobile

final class AgentStatusResolverTests: XCTestCase {

    private func agent(_ id: String, _ tier: OrgAgent.Tier, title: String) -> OrgAgent {
        OrgAgent(id: id, name: id, title: title, summary: "", tier: tier,
                 parent: nil, accentHex: "1C7A55", profileSlug: "default")
    }

    private func initiative(_ stage: String) -> CompanyInitiative {
        CompanyInitiative(id: UUID().uuidString, title: "t", pitch: "p", stage: stage,
                          created: "", score: nil, callsUsed: 0, brief: "", artifacts: [],
                          note: "", repoUrl: nil, origin: nil, minutes: nil)
    }

    private func state(_ stages: [String]) -> CompanyState {
        var s = CompanyState.empty
        s.initiatives = stages.map(initiative)
        return s
    }

    func testCEOWaitsForOwnerAtGate() {
        let ceo = agent("gm", .ceo, title: "General Manager")
        XCTAssertEqual(AgentStatusResolver.status(for: ceo, in: state(["gate1"])), .waitingForUser)
    }

    func testTechLeadActiveDuringExecution() {
        let cto = agent("cto", .manager, title: "CTO")
        XCTAssertEqual(AgentStatusResolver.status(for: cto, in: state(["execution"])), .active)
    }

    func testBlockedInitiativeBlocksTechLead() {
        let cto = agent("cto", .manager, title: "CTO")
        XCTAssertEqual(AgentStatusResolver.status(for: cto, in: state(["blocked"])), .blocked)
    }

    func testIdleWhenNothingAssigned() {
        let cto = agent("cto", .manager, title: "CTO")
        XCTAssertEqual(AgentStatusResolver.status(for: cto, in: state([])), .idle)
    }
}
