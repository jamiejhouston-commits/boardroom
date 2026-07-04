import XCTest
@testable import HermesMobile

final class HQRoamTests: XCTestCase {

    func testFullStickForwardWalksIntoTheRoom() {
        // yaw 0 faces -Z; pushing the stick forward must decrease z.
        let start = HQRoamState(position: [0, HQRoamMath.eyeHeight, 10], yaw: 0, pitch: 0)
        let out = HQRoamMath.step(start, stick: [0, 1], look: .zero, dt: 1)
        XCTAssertEqual(out.position.z, 10 - HQRoamMath.walkSpeed, accuracy: 0.001)
        XCTAssertEqual(out.position.x, 0, accuracy: 0.001)
    }

    func testStrafeRightAtYawZeroIncreasesX() {
        let start = HQRoamState(position: [0, HQRoamMath.eyeHeight, 10], yaw: 0, pitch: 0)
        let out = HQRoamMath.step(start, stick: [1, 0], look: .zero, dt: 1)
        XCTAssertEqual(out.position.x, HQRoamMath.walkSpeed, accuracy: 0.001)
        XCTAssertEqual(out.position.z, 10, accuracy: 0.001)
    }

    func testWallsClampTheWalk() {
        let start = HQRoamState(position: [0, HQRoamMath.eyeHeight, 14.5], yaw: .pi, pitch: 0)
        // Facing +Z (yaw π) and walking forward — must stop at the south wall.
        let out = HQRoamMath.step(start, stick: [0, 1], look: .zero, dt: 5)
        XCTAssertLessThanOrEqual(out.position.z, HQRoamMath.bounds.maxZ + 0.001)
    }

    func testExecutivePlatformIsSolid() {
        // Marching straight at the platform face: z stops at the block edge.
        let start = HQRoamState(position: [0, HQRoamMath.eyeHeight, -6.0], yaw: 0, pitch: 0)
        let out = HQRoamMath.step(start, stick: [0, 1], look: .zero, dt: 1)
        XCTAssertGreaterThanOrEqual(out.position.z, HQRoamMath.execBlock.minZ)
        // The x axis stays free — you can slide along the platform face.
        let slide = HQRoamMath.step(out, stick: [1, 0], look: .zero, dt: 0.5)
        XCTAssertGreaterThan(slide.position.x, out.position.x)
    }

    func testPitchClampsToRange() {
        let start = HQRoamState(position: [0, HQRoamMath.eyeHeight, 10], yaw: 0, pitch: 0)
        let up = HQRoamMath.step(start, stick: .zero, look: [0, -10_000], dt: 0.016)
        XCTAssertEqual(up.pitch, HQRoamMath.pitchRange.upperBound, accuracy: 0.001)
        let down = HQRoamMath.step(start, stick: .zero, look: [0, 10_000], dt: 0.016)
        XCTAssertEqual(down.pitch, HQRoamMath.pitchRange.lowerBound, accuracy: 0.001)
    }

    func testEyeHeightIsPinned() {
        var state = HQRoamState()
        state.position.y = 9
        let out = HQRoamMath.step(state, stick: [0.4, 0.4], look: [3, 3], dt: 0.016)
        XCTAssertEqual(out.position.y, HQRoamMath.eyeHeight)
    }

    func testControlLifecycle() {
        let control = HQRoamControl()
        XCTAssertNil(control.step(now: 0), "inactive control must not step")
        control.activate(from: HQRoamState())
        XCTAssertTrue(control.isActive)
        control.setStick([0, 1])
        _ = control.step(now: 0)                  // first frame establishes dt
        let second = control.step(now: 0.1)
        XCTAssertNotNil(second)
        XCTAssertLessThan(second!.position.z, HQRoamState().position.z)
        control.deactivate()
        XCTAssertNil(control.step(now: 0.2))
    }
}
