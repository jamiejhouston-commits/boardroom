import XCTest
import simd
@testable import HermesMobile

/// Pure walk-math for the generalized division rooms (Games Studio and beyond).
/// Mirrors `HQRoamTests` but exercises `RoamField` bounds + interior blockers.
final class RoamFieldTests: XCTestCase {

    private func field(blockers: [RoamBlocker] = []) -> RoamField {
        RoamField(minX: -12, maxX: 12, minZ: -10, maxZ: 10,
                  blockers: blockers,
                  startPosition: SIMD3(0, 1.6, 8), startYaw: 0)
    }

    func testForwardWalksIntoTheRoom() {
        // yaw 0 faces -Z; pushing the stick forward decreases z.
        let f = field()
        let start = RoamState(position: SIMD3(0, f.eyeHeight, 6), yaw: 0)
        let out = RoamMath.step(start, field: f, stick: [0, 1], look: .zero, dt: 1)
        XCTAssertEqual(out.position.z, 6 - f.walkSpeed, accuracy: 0.001)
        XCTAssertEqual(out.position.x, 0, accuracy: 0.001)
    }

    func testStrafeRightIncreasesX() {
        let f = field()
        let start = RoamState(position: SIMD3(0, f.eyeHeight, 6), yaw: 0)
        let out = RoamMath.step(start, field: f, stick: [1, 0], look: .zero, dt: 1)
        XCTAssertEqual(out.position.x, f.walkSpeed, accuracy: 0.001)
        XCTAssertEqual(out.position.z, 6, accuracy: 0.001)
    }

    func testWallsClampTheWalk() {
        let f = field()
        // Facing +Z (yaw π), walk forward hard — must stop at the south wall.
        let start = RoamState(position: SIMD3(0, f.eyeHeight, 9.5), yaw: .pi)
        let out = RoamMath.step(start, field: f, stick: [0, 1], look: .zero, dt: 5)
        XCTAssertLessThanOrEqual(out.position.z, f.maxZ + 0.001)
    }

    func testBlockerIsSolidAndSlides() {
        // A cabinet-like blocker centered at (5,-2). March into its +Z face over
        // realistic per-frame steps (the controller clamps dt to 1/20s, so a
        // single step is ≤0.16m and can never tunnel a 2.2m-deep solid).
        let blocker = RoamBlocker(centerX: 5, centerZ: -2, halfX: 1.2, halfZ: 1.1)
        let f = field(blockers: [blocker])
        var out = RoamState(position: SIMD3(5, f.eyeHeight, 0.4), yaw: 0)   // north of it
        for _ in 0..<40 {
            out = RoamMath.step(out, field: f, stick: [0, 1], look: .zero, dt: 1.0 / 20)
        }
        // The walker never penetrates the solid and is held at its near (+Z) face.
        XCTAssertFalse(blocker.contains(out.position.x, out.position.z))
        XCTAssertGreaterThanOrEqual(out.position.z, blocker.maxZ - 0.001)
        // The x axis stays free — you can slide along the face.
        let slide = RoamMath.step(out, field: f, stick: [1, 0], look: .zero, dt: 1.0 / 20)
        XCTAssertGreaterThan(slide.position.x, out.position.x)
    }

    func testPitchClampsToRange() {
        let f = field()
        let start = RoamState(position: SIMD3(0, f.eyeHeight, 6), yaw: 0, pitch: 0)
        let up = RoamMath.step(start, field: f, stick: .zero, look: [0, -10_000], dt: 0.016)
        XCTAssertEqual(up.pitch, f.pitchRange.upperBound, accuracy: 0.001)
        let down = RoamMath.step(start, field: f, stick: .zero, look: [0, 10_000], dt: 0.016)
        XCTAssertEqual(down.pitch, f.pitchRange.lowerBound, accuracy: 0.001)
    }

    func testEyeHeightIsPinned() {
        let f = field()
        var start = RoamState(field: f)
        start.position.y = 9
        let out = RoamMath.step(start, field: f, stick: [0.4, 0.4], look: [3, 3], dt: 0.016)
        XCTAssertEqual(out.position.y, f.eyeHeight)
    }

    func testControllerLifecycle() {
        let control = RoamController(field: field())
        XCTAssertNil(control.step(now: 0), "inactive controller must not step")
        control.activate()
        XCTAssertTrue(control.isActive)
        control.setStick([0, 1])
        _ = control.step(now: 0)                 // first frame establishes dt
        let second = control.step(now: 0.1)
        XCTAssertNotNil(second)
        XCTAssertLessThan(second!.position.z, RoamState(field: field()).position.z)
        control.deactivate()
        XCTAssertNil(control.step(now: 0.2))
    }
}
