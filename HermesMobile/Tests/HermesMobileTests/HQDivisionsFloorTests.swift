import XCTest
@testable import HermesMobile

final class HQDivisionsFloorTests: XCTestCase {

    // MARK: Roam invariants on the Divisions Floor

    func testDivisionsFloorWallsClampTheWalk() {
        // Facing -X (yaw π/2), a long march must stop at the west wall.
        var start = HQRoamState.spawn(on: .divisions)
        start.yaw = .pi / 2
        let out = HQRoamMath.step(start, stick: [0, 1], look: .zero, dt: 30)
        XCTAssertGreaterThanOrEqual(out.position.x, HQRoamMath.divisionsBounds.minX - 0.001)
        XCTAssertEqual(out.floor, .divisions, "clamping must never change floors")
    }

    func testDivisionsEyeHeightIsPinnedAboveTheGroundFloor() {
        var start = HQRoamState.spawn(on: .divisions)
        start.position.y = 0    // corrupt it — step must re-pin
        let out = HQRoamMath.step(start, stick: [0.4, 0.4], look: [3, 3], dt: 0.016)
        XCTAssertEqual(out.position.y, HQRoamMath.eyeY(on: .divisions))
        XCTAssertGreaterThan(out.position.y, HQRoamMath.divisionsElevation)
    }

    func testExecutivePlatformDoesNotBlockUpstairs() {
        // On the ground floor this march is stopped by the exec platform;
        // the same coordinates upstairs are open floor.
        let start = HQRoamState(position: [0, HQRoamMath.eyeY(on: .divisions), -6.0],
                                yaw: 0, pitch: 0, floor: .divisions)
        let out = HQRoamMath.step(start, stick: [0, 1], look: .zero, dt: 1)
        XCTAssertLessThan(out.position.z, HQRoamMath.execBlock.maxZ)
    }

    func testSpawnsLandInBoundsAndOutsideTheElevator() {
        for floor in [HQFloor.ground, .divisions] {
            let spawn = HQRoamState.spawn(on: floor)
            let bounds = HQRoamMath.bounds(on: floor)
            XCTAssertTrue((bounds.minX...bounds.maxX).contains(spawn.position.x))
            XCTAssertTrue((bounds.minZ...bounds.maxZ).contains(spawn.position.z))
            XCTAssertEqual(spawn.position.y, HQRoamMath.eyeY(on: floor))
            XCTAssertEqual(spawn.floor, floor)
            // Landing inside the trigger would ride the lift straight back.
            XCTAssertFalse(HQRoamMath.inElevator(spawn))
        }
    }

    func testElevatorZoneDetectsTheRiderPerFloor() {
        let groundZone = HQRoamMath.groundElevatorZone
        let onPad = HQRoamState(
            position: [(groundZone.minX + groundZone.maxX) / 2, HQRoamMath.eyeHeight,
                       (groundZone.minZ + groundZone.maxZ) / 2],
            yaw: 0, pitch: 0, floor: .ground)
        XCTAssertTrue(HQRoamMath.inElevator(onPad))

        // Same XZ upstairs is NOT that floor's elevator.
        var upstairs = onPad
        upstairs.floor = .divisions
        XCTAssertFalse(HQRoamMath.inElevator(upstairs))

        let upZone = HQRoamMath.divisionsElevatorZone
        let onLift = HQRoamState(
            position: [(upZone.minX + upZone.maxX) / 2, HQRoamMath.eyeY(on: .divisions),
                       (upZone.minZ + upZone.maxZ) / 2],
            yaw: 0, pitch: 0, floor: .divisions)
        XCTAssertTrue(HQRoamMath.inElevator(onLift))
    }

    // MARK: Division bays

    private func initiative(title: String, pitch: String) -> CompanyInitiative {
        CompanyInitiative(id: UUID().uuidString, title: title, pitch: pitch, stage: "research",
                          created: "", score: nil, callsUsed: 0, brief: "", artifacts: [],
                          note: "", repoUrl: nil, origin: nil, minutes: nil)
    }

    func testSevenBaysWithRelayMatchingIDs() {
        XCTAssertEqual(HQDivision.allCases.count, 7)
        // Bay ids must equal the relay's `division` tags exactly.
        XCTAssertEqual(HQDivision.allCases.map(\.id),
                       ["webapps", "saas", "ecommerce", "automations",
                        "consulting", "accounting", "legal"])
    }

    func testDivisionKeywordMatchIsHonest() {
        let saas = initiative(title: "Launch a SaaS metrics dashboard", pitch: "")
        XCTAssertTrue(HQDivision.saas.matches(saas))
        XCTAssertFalse(HQDivision.accounting.matches(saas))

        let books = initiative(title: "Client tool", pitch: "Automated bookkeeping and ledger sync")
        XCTAssertTrue(HQDivision.accounting.matches(books))

        let unrelated = initiative(title: "Untitled", pitch: "A mystery")
        XCTAssertTrue(HQDivision.allCases.allSatisfy { !$0.matches(unrelated) },
                      "no division may claim work that never mentions it")
    }

    func testRealDivisionTagBeatsTheKeywordHeuristic() {
        var tagged = initiative(title: "SaaS privacy policy generator", pitch: "")
        tagged.division = "legal"
        XCTAssertTrue(HQDivision.legal.owns(tagged))
        XCTAssertFalse(HQDivision.saas.owns(tagged),
                       "a relay tag must beat keyword matches on other bays")

        // Untagged (legacy) initiatives still fall back to keywords.
        let legacy = initiative(title: "Launch a SaaS metrics dashboard", pitch: "")
        XCTAssertTrue(HQDivision.saas.owns(legacy))
        XCTAssertFalse(HQDivision.legal.owns(legacy))
    }

    func testDivisionTapRoutingRoundTrips() {
        XCTAssertEqual(Set(HQDivision.allCases.map(\.tapName)).count,
                       HQDivision.allCases.count, "tap names must be unique")
        for division in HQDivision.allCases {
            XCTAssertEqual(HQDivision.division(forNodeName: division.tapName), division)
        }
        XCTAssertNil(HQDivision.division(forNodeName: HQSceneBuilder.productionBayName))
        XCTAssertNil(HQDivision.division(forNodeName: nil))
    }
}
