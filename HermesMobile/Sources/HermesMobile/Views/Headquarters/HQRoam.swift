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

// MARK: - State

struct HQRoamState: Equatable {
    /// World-space eye position (y pinned to `HQRoamMath.eyeHeight`).
    var position = SIMD3<Float>(0, HQRoamMath.eyeHeight, 13.5)
    /// Radians. 0 faces -Z — into the room from the south entry.
    var yaw: Float = 0
    var pitch: Float = -0.04
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
            var nx = min(max(out.position.x + dx, bounds.minX), bounds.maxX)
            var nz = min(max(out.position.z + dz, bounds.minZ), bounds.maxZ)

            // Executive platform: slide along the face you approached from.
            if nx > execBlock.minX, nx < execBlock.maxX,
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
        out.position.y = eyeHeight
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
