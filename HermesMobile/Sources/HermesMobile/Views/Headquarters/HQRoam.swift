import Foundation
import QuartzCore
import simd

/// First-person walkthrough for the HQ floor.
///
/// `HQRoamMath` is pure (simd only — unit-tested): it integrates the virtual
/// joystick + look deltas into a camera pose, clamps pitch, keeps the eye at
/// standing height, and slides along the walls and the raised executive
/// platform instead of clipping through them.
///
/// `HQRoamControl` is the bridge between input (SwiftUI joystick + UIKit pan,
/// main thread) and consumption (the SceneKit render loop, render thread).
/// All state lives behind one lock; the render loop takes one `step(now:)`
/// per frame and gets back the fresh pose — or nil when roam is inactive.

// MARK: - Floors

/// Which storey of the HQ the player rig is on. Storeys are stacked on +Y;
/// travel between them is a teleport through the elevator markers.
enum HQFloor: Equatable, Sendable {
    case ground      // the lobby floor — command dais, pods, exec wing
    case divisions   // the Divisions Floor — six production bays
}

// MARK: - State

struct HQRoamState: Equatable {
    /// World-space eye position (y pinned to `HQRoamMath.eyeY(on:)`).
    var position = SIMD3<Float>(0, HQRoamMath.eyeHeight, 13.5)
    /// Radians. 0 faces -Z — into the room from the south entry.
    var yaw: Float = 0
    var pitch: Float = -0.04
    /// The storey this pose lives on — picks the bounds, eye height, elevator.
    var floor: HQFloor = .ground

    /// Arrival pose per floor. The divisions spawn lands beside the lift,
    /// facing the room, clear of the trigger zone so landing never re-rides.
    static func spawn(on floor: HQFloor) -> HQRoamState {
        switch floor {
        case .ground:
            return HQRoamState()   // the proven south-entry pose
        case .divisions:
            return HQRoamState(position: SIMD3(11.4, HQRoamMath.eyeY(on: .divisions), 0),
                               yaw: .pi / 2, pitch: -0.04, floor: .divisions)
        }
    }
}

// MARK: - Math (pure)

enum HQRoamMath {
    static let eyeHeight: Float = 1.6
    static let walkSpeed: Float = 3.2            // m/s at full stick
    static let lookSensitivity: Float = 0.0042   // radians per screen point
    static let pitchRange: ClosedRange<Float> = -0.62 ... 0.45

    /// Stay inside the perimeter walls (x ±20, z ±15.5) with margin.
    static let bounds = (minX: Float(-18.6), maxX: Float(18.6),
                         minZ: Float(-14.7), maxZ: Float(14.7))
    /// The raised executive platform (16 × 8.5 @ z = -11) — solid, not walkable.
    static let execBlock = (minX: Float(-8.3), maxX: Float(8.3),
                            minZ: Float(-15.4), maxZ: Float(-6.6))

    // MARK: Divisions Floor (floor 2 — built by HQDivisionsFloor at this Y)

    /// Slab-top elevation of the Divisions Floor, well above the ground
    /// floor's 5.5 m walls and lit ceiling panels.
    static let divisionsElevation: Float = 8.0

    /// Divisions Floor perimeter walls (x ±16, z ±11) with the same margin.
    static let divisionsBounds = (minX: Float(-14.8), maxX: Float(14.8),
                                  minZ: Float(-10.2), maxZ: Float(10.2))

    static func bounds(on floor: HQFloor) -> (minX: Float, maxX: Float, minZ: Float, maxZ: Float) {
        floor == .ground ? bounds : divisionsBounds
    }

    /// Standing eye height on a given storey.
    static func eyeY(on floor: HQFloor) -> Float {
        floor == .ground ? eyeHeight : divisionsElevation + eyeHeight
    }

    /// Elevator trigger zones (world XZ). Walking inside one rides the lift —
    /// `HQDivisionsFloor` centers its pads on these so scenery and trigger
    /// never drift apart (same single-source rule as `zoneAnchors`).
    static let groundElevatorZone = (minX: Float(-14.6), maxX: Float(-12.4),
                                     minZ: Float(10.9), maxZ: Float(13.1))
    static let divisionsElevatorZone = (minX: Float(12.6), maxX: Float(14.8),
                                        minZ: Float(-1.2), maxZ: Float(1.2))

    static func inElevator(_ s: HQRoamState) -> Bool {
        let zone = s.floor == .ground ? groundElevatorZone : divisionsElevatorZone
        return s.position.x >= zone.minX && s.position.x <= zone.maxX
            && s.position.z >= zone.minZ && s.position.z <= zone.maxZ
    }

    /// One integration step. `stick` is the normalized joystick (+y = forward,
    /// +x = strafe right); `look` is the accumulated pan delta in points.
    static func step(_ s: HQRoamState,
                     stick: SIMD2<Float>,
                     look: SIMD2<Float>,
                     dt: Float) -> HQRoamState {
        var out = s
        out.yaw -= look.x * lookSensitivity
        out.pitch = min(max(out.pitch - look.y * lookSensitivity,
                            pitchRange.lowerBound), pitchRange.upperBound)

        let mag = simd_length(stick)
        if mag > 0.02, dt > 0 {
            let v = mag > 1 ? stick / mag : stick
            let sinY = sin(out.yaw), cosY = cos(out.yaw)
            // Model/camera forward at yaw 0 is -Z: forward = (-sinY, -cosY).
            let dx = (-sinY * v.y + cosY * v.x) * walkSpeed * dt
            let dz = (-cosY * v.y - sinY * v.x) * walkSpeed * dt
            let b = bounds(on: s.floor)
            var nx = min(max(out.position.x + dx, b.minX), b.maxX)
            var nz = min(max(out.position.z + dz, b.minZ), b.maxZ)

            // Executive platform (ground floor only): slide along the face
            // you approached from.
            if s.floor == .ground,
               nx > execBlock.minX, nx < execBlock.maxX,
               nz > execBlock.minZ, nz < execBlock.maxZ {
                let wasOutsideX = !(s.position.x > execBlock.minX && s.position.x < execBlock.maxX)
                let wasOutsideZ = !(s.position.z > execBlock.minZ && s.position.z < execBlock.maxZ)
                if wasOutsideX { nx = s.position.x }
                if wasOutsideZ { nz = s.position.z }
                if !wasOutsideX && !wasOutsideZ { nx = s.position.x; nz = s.position.z }
            }
            out.position.x = nx
            out.position.z = nz
        }
        out.position.y = eyeY(on: s.floor)
        return out
    }
}

// MARK: - Control bridge (main-thread writes → render-thread reads)

final class HQRoamControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stick = SIMD2<Float>.zero
    private var pendingLook = SIMD2<Float>.zero
    private var state = HQRoamState()
    private var active = false
    private var lastTime: TimeInterval?

    /// Joystick (SwiftUI) — normalized [-1, 1] each axis; zero on release.
    func setStick(_ v: SIMD2<Float>) {
        lock.lock(); stick = v; lock.unlock()
    }

    /// Pan gesture (UIKit) — accumulate look deltas between frames.
    func addLook(_ d: SIMD2<Float>) {
        lock.lock(); pendingLook += d; lock.unlock()
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// Enter roam at a fresh pose (main thread, on mode switch).
    func activate(from start: HQRoamState = HQRoamState()) {
        lock.lock()
        state = start; active = true
        stick = .zero; pendingLook = .zero; lastTime = nil
        lock.unlock()
    }

    func deactivate() {
        lock.lock(); active = false; lock.unlock()
    }

    /// One frame from the render loop. Returns the new pose, nil when inactive.
    func step(now: TimeInterval) -> HQRoamState? {
        lock.lock(); defer { lock.unlock() }
        guard active else { return nil }
        let dt = Float(min(max(now - (lastTime ?? now), 0), 1.0 / 20))  // clamp long stalls
        lastTime = now
        let look = pendingLook
        pendingLook = .zero
        state = HQRoamMath.step(state, stick: stick, look: look, dt: dt)
        return state
    }
}
