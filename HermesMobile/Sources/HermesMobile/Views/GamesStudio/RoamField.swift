import Foundation
import QuartzCore
import simd

/// Room-agnostic first-person walkthrough — the generalized sibling of the HQ's
/// `HQRoamMath`/`HQRoamControl`, so every division room (Games Studio today,
/// more later) shares one proven walk feel instead of copying HQ's hardcoded
/// bounds. `RoamMath` is pure (simd only, unit-tested); `RoamController` is the
/// main-thread-input → render-thread-consumption bridge.
///
/// The HQ keeps its own `HQRoam*` untouched; this is additive.

// MARK: - Field (bounds + solid blockers)

/// An axis-aligned solid the walker slides along instead of clipping through
/// (the arcade cabinet, the playtest couch, …).
struct RoamBlocker: Equatable {
    var minX, maxX, minZ, maxZ: Float
    init(minX: Float, maxX: Float, minZ: Float, maxZ: Float) {
        self.minX = minX; self.maxX = maxX; self.minZ = minZ; self.maxZ = maxZ
    }
    /// Convenience: a blocker centered at (cx,cz) with the given half-extents.
    init(centerX cx: Float, centerZ cz: Float, halfX hx: Float, halfZ hz: Float) {
        self.init(minX: cx - hx, maxX: cx + hx, minZ: cz - hz, maxZ: cz + hz)
    }
    func contains(_ x: Float, _ z: Float) -> Bool {
        x > minX && x < maxX && z > minZ && z < maxZ
    }
}

/// The walkable field for a room: outer bounds + interior blockers + feel.
struct RoamField {
    var minX, maxX, minZ, maxZ: Float
    var blockers: [RoamBlocker]
    var eyeHeight: Float = 1.6
    var walkSpeed: Float = 3.2
    var lookSensitivity: Float = 0.0042
    var pitchRange: ClosedRange<Float> = -0.62 ... 0.45
    /// Where the walker starts (world eye position) and which way they face.
    var startPosition: SIMD3<Float>
    var startYaw: Float = 0
}

// MARK: - State

struct RoamState: Equatable {
    var position: SIMD3<Float>
    var yaw: Float
    var pitch: Float = -0.04

    init(position: SIMD3<Float> = SIMD3(0, 1.6, 8), yaw: Float = 0, pitch: Float = -0.04) {
        self.position = position; self.yaw = yaw; self.pitch = pitch
    }

    init(field: RoamField) {
        self.position = field.startPosition
        self.yaw = field.startYaw
        self.pitch = -0.04
    }
}

// MARK: - Math (pure)

enum RoamMath {
    /// One integration step. `stick` is the normalized joystick (+y forward,
    /// +x strafe right); `look` is accumulated pan delta in screen points.
    static func step(_ s: RoamState, field: RoamField,
                     stick: SIMD2<Float>, look: SIMD2<Float>, dt: Float) -> RoamState {
        var out = s
        out.yaw -= look.x * field.lookSensitivity
        out.pitch = min(max(out.pitch - look.y * field.lookSensitivity,
                            field.pitchRange.lowerBound), field.pitchRange.upperBound)

        let mag = simd_length(stick)
        if mag > 0.02, dt > 0 {
            let v = mag > 1 ? stick / mag : stick
            let sinY = sin(out.yaw), cosY = cos(out.yaw)
            // Camera forward at yaw 0 is -Z: forward = (-sinY, -cosY).
            let dx = (-sinY * v.y + cosY * v.x) * field.walkSpeed * dt
            let dz = (-cosY * v.y - sinY * v.x) * field.walkSpeed * dt
            var nx = min(max(out.position.x + dx, field.minX), field.maxX)
            var nz = min(max(out.position.z + dz, field.minZ), field.maxZ)

            // Slide along any blocker face the walker approached from.
            for b in field.blockers where b.contains(nx, nz) {
                let wasOutsideX = !(s.position.x > b.minX && s.position.x < b.maxX)
                let wasOutsideZ = !(s.position.z > b.minZ && s.position.z < b.maxZ)
                if wasOutsideX { nx = s.position.x }
                if wasOutsideZ { nz = s.position.z }
                if !wasOutsideX && !wasOutsideZ { nx = s.position.x; nz = s.position.z }
            }
            out.position.x = nx
            out.position.z = nz
        }
        out.position.y = field.eyeHeight
        return out
    }
}

// MARK: - Control bridge (main-thread writes → render-thread reads)

final class RoamController: @unchecked Sendable {
    private let lock = NSLock()
    private var stick = SIMD2<Float>.zero
    private var pendingLook = SIMD2<Float>.zero
    private var state: RoamState
    private var field: RoamField
    private var active = false
    private var lastTime: TimeInterval?

    init(field: RoamField) {
        self.field = field
        self.state = RoamState(field: field)
    }

    func setStick(_ v: SIMD2<Float>) { lock.lock(); stick = v; lock.unlock() }
    func addLook(_ d: SIMD2<Float>) { lock.lock(); pendingLook += d; lock.unlock() }

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

    func activate() {
        lock.lock()
        state = RoamState(field: field); active = true
        stick = .zero; pendingLook = .zero; lastTime = nil
        lock.unlock()
    }

    func deactivate() { lock.lock(); active = false; lock.unlock() }

    /// One frame from the render loop. Returns the new pose, nil when inactive.
    func step(now: TimeInterval) -> RoamState? {
        lock.lock(); defer { lock.unlock() }
        guard active else { return nil }
        let dt = Float(min(max(now - (lastTime ?? now), 0), 1.0 / 20))
        lastTime = now
        let look = pendingLook
        pendingLook = .zero
        state = RoamMath.step(state, field: field, stick: stick, look: look, dt: dt)
        return state
    }
}
