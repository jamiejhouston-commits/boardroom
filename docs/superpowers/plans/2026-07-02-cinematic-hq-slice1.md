# Cinematic AI Headquarters — Slice 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the flagship vertical slice of a cinematic 3D AI headquarters — an open, layered SceneKit floor with a distinct executive wing, a command center, two department pods, live status-driven agents, three camera modes, and a premium HUD — wired behind the War Room without disturbing existing views.

**Architecture:** New `Views/Headquarters/` module. A SwiftUI `HeadquartersView` hosts an `SCNView` (via `UIViewRepresentable` + `Coordinator`, mirroring `AgentStudio3DView.AgentRoomSceneView`). Pure-logic pieces (`HQLayout`, `AgentStatusResolver`) are data-driven and unit-tested. Scene/agent/camera/HUD pieces are compile-checked by Claude and visually verified on the user's iPhone.

**Tech Stack:** Swift 6, SwiftUI, SceneKit, XcodeGen, XCTest. Binds to existing `OrgStore`, `CompanyStore`, `AgentRobot`, `HermesTheme`.

## Global Constraints

- iOS 18.0 deployment target; Swift 6.0; app builds via `xcodegen generate` then a clean Xcode build.
- **Claude never runs the simulator.** Claude verification = `swiftc`/Xcode compile only. All visual/interaction verification is done by the user on his iPhone; each visual task lists the exact on-device check.
- Additive only: new files under `Views/Headquarters/`; the sole edit to existing code is one `.fullScreenCover` entry point added to `WarRoomView`. No existing view/behavior is removed.
- Palette strictly from `HermesTheme` (`emerald`, `navy`, `gold`, `steel`, `silver`, surfaces). Restrained glow — no neon.
- Performance: cap dynamic lights (≤4), reuse materials/geometry, LOD the robots, no per-frame allocations in `renderer(_:updateAtTime:)`.
- New XCTest files live in `HermesMobile/Tests/HermesMobileTests/`; run with the app's existing test target.

---

### Task 0: Scaffold + War Room entry point (empty lit floor)

**Files:**
- Create: `HermesMobile/Sources/HermesMobile/Views/Headquarters/HeadquartersView.swift`
- Create: `HermesMobile/Sources/HermesMobile/Views/Headquarters/HQSceneView.swift`
- Modify: `HermesMobile/Sources/HermesMobile/Views/WarRoomView.swift` (add one hero button + `.fullScreenCover`)

**Interfaces:**
- Produces: `struct HeadquartersView: View` (takes no args; reads `@EnvironmentObject OrgStore`, `CompanyStore`). `struct HQSceneView: UIViewRepresentable` with `final class Coordinator`, `func makeUIView`, `func updateUIView`.
- Consumes: existing `HermesTheme`, `OrgStore`, `CompanyStore` from the environment.

- [ ] **Step 1:** Create `HQSceneView` mirroring `AgentRoomSceneView`: `makeUIView` returns an `SCNView` (`backgroundColor = UIColor(HermesTheme.background)`, `antialiasingMode = .multisampling2X`, `allowsCameraControl = false`, `isPlaying = true`). Build an `SCNScene` with: a 24×24 floor plane (navy material, slight metalness), one ambient light (low), one directional key-light, and a camera node at an elevated overview pose looking at origin. Store the scene + camera node on the `Coordinator`. `updateUIView` does nothing yet.

- [ ] **Step 2:** Create `HeadquartersView` = `ZStack { HQSceneView().ignoresSafeArea(); topBar }` where `topBar` is a minimal close button (`HermesTheme` styled) that dismisses via `@Environment(\.dismiss)`.

- [ ] **Step 3:** In `WarRoomView`, add a prominent hero button near the top — `Label("Enter Headquarters", systemImage: "building.2.crop.circle")` styled with `hermesCard` — with `@State private var showHQ = false` and `.fullScreenCover(isPresented: $showHQ) { HeadquartersView() }`.

- [ ] **Step 4 (Claude compile-check):** From the repo root, run `xcodegen generate` then compile the target. Expected: builds with no errors; new files included.

- [ ] **Step 5 (User on iPhone):** Build+run. Open War Room → tap "Enter Headquarters" → a full-screen 3D view shows a lit navy floor from an elevated angle; close button returns to War Room. Existing War Room content unchanged.

- [ ] **Step 6:** Commit: `git add HermesMobile/Sources/HermesMobile/Views/Headquarters WarRoomView.swift project.yml && git commit -m "feat(hq): headquarters scaffold + war-room entry"`

---

### Task 1: Cinematic environment (`HQSceneBuilder`)

**Files:**
- Create: `HermesMobile/Sources/HermesMobile/Views/Headquarters/HQSceneBuilder.swift`
- Modify: `HQSceneView.swift` (call the builder instead of the placeholder floor)

**Interfaces:**
- Produces: `enum HQSceneBuilder { static func buildEnvironment(into scene: SCNScene) }` — adds floor, four zone footprints, glass partitions, lighting rig, and camera-independent props. Zone anchor positions exposed as `static let zoneAnchors: [HQOfficeArchetype: SCNVector3]` (consumed by Task 4).
- Consumes: `HermesTheme` colors.

- [ ] **Step 1:** Implement `buildEnvironment`: emerald under-glow floor (dark navy plane + a larger, dim emerald emissive plane just beneath, low intensity); perimeter navy walls; the **executive wing** on a raised platform (higher Y, larger footprint) with a warm gold spotlight; the **command center** centerpiece (round table node + a tall holographic "mission wall" = a thin emissive plane with low-alpha emerald); **research** and **engineering** pods as glass-partitioned footprints (smoked-glass = transparent material, low alpha, steel frame). Add `scene.fogStartDistance/fogEndDistance/fogColor` for depth haze (navy). Cap lights at 4.

- [ ] **Step 2:** Add `static let zoneAnchors` mapping each `HQOfficeArchetype` (`.executive`, `.command`, `.researchLab`, `.engineeringDen`) to its floor anchor `SCNVector3` (defined here so Task 2/4 place agents consistently).

- [ ] **Step 3:** In `HQSceneView.makeUIView`, replace the placeholder floor with `HQSceneBuilder.buildEnvironment(into: scene)`.

- [ ] **Step 4 (Claude compile-check):** `xcodegen generate` + compile. Expected: no errors.

- [ ] **Step 5 (User on iPhone):** The empty HQ now reads as a spacious, layered room: four visibly distinct zones, the executive wing clearly **bigger/higher/brighter** with gold light, smoked-glass partitions, emerald floor glow, atmospheric depth. Feels cinematic, not flat. Smooth (no stutter).

- [ ] **Step 6:** Commit: `git commit -am "feat(hq): cinematic environment + zones + lighting"`

---

### Task 2: Agent→zone layout (`HQLayout`, unit-tested)

**Files:**
- Create: `HermesMobile/Sources/HermesMobile/Views/Headquarters/HQLayout.swift`
- Test: `HermesMobile/Tests/HermesMobileTests/HQLayoutTests.swift`

**Interfaces:**
- Produces: `enum HQOfficeArchetype: CaseIterable { case executive, command, researchLab, engineeringDen }`; `struct HQPlacement { let agent: OrgAgent; let archetype: HQOfficeArchetype; let anchor: SCNVector3 }`; `enum HQLayout { static func placements(for agents: [OrgAgent]) -> [HQPlacement] }`.
- Consumes: `OrgAgent` (`tier`, `id`), `HQSceneBuilder.zoneAnchors`.

- [ ] **Step 1 (failing test):**
```swift
import XCTest
@testable import HermesMobile
final class HQLayoutTests: XCTestCase {
    private func agent(_ id: String, _ tier: OrgAgent.Tier) -> OrgAgent {
        OrgAgent(id: id, name: id, title: id, summary: "", tier: tier, parent: nil, accentHex: "1C7A55")
    }
    func testCEOGoesToExecutiveWing() {
        let org = [agent("gm", .ceo), agent("cto", .manager), agent("research", .manager)]
        let p = HQLayout.placements(for: org)
        XCTAssertEqual(p.first { $0.agent.id == "gm" }?.archetype, .executive)
    }
    func testTwoManagersFillResearchAndEngineering() {
        let org = [agent("gm", .ceo), agent("cto", .manager), agent("research", .manager)]
        let arch = Set(HQLayout.placements(for: org).filter { $0.agent.tier == .manager }.map { $0.archetype })
        XCTAssertEqual(arch, [.researchLab, .engineeringDen])
    }
    func testSliceCapsAtThreeAgents() {
        let org = (0..<9).map { agent("m\($0)", $0 == 0 ? .ceo : .manager) }
        XCTAssertLessThanOrEqual(HQLayout.placements(for: org).count, 3)
    }
}
```
- [ ] **Step 2:** Run tests → FAIL (`HQLayout` undefined).
- [ ] **Step 3:** Implement: CEO (`tier == .ceo`, else first agent) → `.executive`; first two `.manager`s → `.researchLab`, `.engineeringDen` (in order); every placement's `anchor` = `HQSceneBuilder.zoneAnchors[archetype]`. Command center has no seated agent in Slice 1 (it's the shared stage), so cap the returned placements at 3 (CEO + 2 managers).
- [ ] **Step 4:** Run tests → PASS.
- [ ] **Step 5:** Commit: `git commit -am "feat(hq): data-driven agent→zone layout + tests"`

---

### Task 3: Live status model (`HQAgentStatus` + resolver, unit-tested)

**Files:**
- Create: `HermesMobile/Sources/HermesMobile/Views/Headquarters/HQAgentStatus.swift`
- Test: `HermesMobile/Tests/HermesMobileTests/AgentStatusResolverTests.swift`

**Interfaces:**
- Produces: `enum HQAgentStatus { case active, thinking, collaborating, blocked, waitingForUser, urgent, idle }` with `var tint: UIColor`, `var glyph: String`; `enum AgentStatusResolver { static func status(for agent: OrgAgent, in state: CompanyState) -> HQAgentStatus }`.
- Consumes: `OrgAgent`, `CompanyState` (`initiatives`, `pendingGates`-equivalent via `stage`), `OrgAgent.companyRole`.

- [ ] **Step 1 (failing test):** cover: a CEO with an initiative at `gate1` → `.waitingForUser`; a role on an `execution`-stage initiative → `.active`; an initiative with `stage == "blocked"` → owner role `.blocked`; nothing active → `.idle`. (Construct `CompanyState` via its `Codable`/memberwise init with minimal `CompanyInitiative`s.)
- [ ] **Step 2:** Run tests → FAIL.
- [ ] **Step 3:** Implement the mapping exactly as the spec's "Status mapping" section. Keep it a pure function over `(agent, state)`.
- [ ] **Step 4:** Run tests → PASS.
- [ ] **Step 5:** Commit: `git commit -am "feat(hq): agent status model + resolver + tests"`

---

### Task 4: Agents in zones (`HQAgentNode`)

**Files:**
- Create: `HermesMobile/Sources/HermesMobile/Views/Headquarters/HQAgentNode.swift`
- Modify: `HQSceneView.swift` (place agent nodes from `HQLayout.placements`)

**Interfaces:**
- Produces: `final class HQAgentNode: SCNNode { init(placement: HQPlacement); func applyStatus(_ status: HQAgentStatus) }`. Internally builds body via `AgentRobot.node(for: placement.agent, color: roleColor)` + a floating status-ring child node.
- Consumes: `AgentRobot.node(for:color:)`, `HQPlacement`, `HQAgentStatus`.

- [ ] **Step 1:** Implement `HQAgentNode`: position at `placement.anchor`; add `AgentRobot.node(...)` tinted from `placement.agent.accentHex`; add a `SCNTorus` "status ring" child hovering above the head; add a slow idle bob (`SCNAction.repeatForever`); `applyStatus` sets ring material `diffuse/emission` to `status.tint` and pulse speed.
- [ ] **Step 2:** In `HQSceneView.makeUIView`, after building the environment, iterate `HQLayout.placements(for: org.agents)`, create an `HQAgentNode` each, `applyStatus(AgentStatusResolver.status(for:in: company.state))`, add to scene; keep them in `Coordinator.agentNodes: [String: HQAgentNode]` keyed by agent id.
- [ ] **Step 3 (Claude compile-check):** `xcodegen generate` + compile → no errors.
- [ ] **Step 4 (User on iPhone):** Agents now stand in their zones — CEO in the executive wing, two managers in the research + engineering pods — each role-tinted, gently idling, with a colored status ring. Command center is the empty dramatic stage.
- [ ] **Step 5:** Commit: `git commit -am "feat(hq): status-aware agents placed in zones"`

---

### Task 5: Live status binding

**Files:**
- Modify: `HQSceneView.swift` (`updateUIView`), `HeadquartersView.swift` (observe `CompanyStore`)

**Interfaces:**
- Consumes: `Coordinator.agentNodes`, `AgentStatusResolver`, `CompanyStore.state`.

- [ ] **Step 1:** Pass `company.state` into `HQSceneView` as a property. In `updateUIView`, recompute each agent's status via `AgentStatusResolver` and call `agentNodes[id]?.applyStatus(...)` — no scene rebuild, no allocations beyond material color.
- [ ] **Step 2:** Ensure `HeadquartersView` holds `@EnvironmentObject var company: CompanyStore` so SwiftUI re-invokes `updateUIView` on state change; call `company.refresh(...)` in `.task` if not already live.
- [ ] **Step 3 (Claude compile-check):** compile → no errors.
- [ ] **Step 4 (User on iPhone):** With the company running (or by approving/creating a gate), the matching agent's ring changes live — e.g. an initiative hits a gate → the CEO's ring turns to the ✨ waiting-for-you tint — without reopening the view.
- [ ] **Step 5:** Commit: `git commit -am "feat(hq): bind agent status rings to live company state"`

---

### Task 6: Camera modes (`HQCameraController`)

**Files:**
- Create: `HermesMobile/Sources/HermesMobile/Views/Headquarters/HQCameraController.swift`
- Modify: `HQSceneView.swift`, `HeadquartersView.swift`

**Interfaces:**
- Produces: `enum HQCameraMode { case overview, orbit, inspect(agentID: String) }`; `final class HQCameraController { init(camera: SCNNode); func apply(_ mode: HQCameraMode, agentNodes: [String: HQAgentNode]) }`.
- Consumes: the camera node stored on the `Coordinator`, `agentNodes`.

- [ ] **Step 1:** Implement poses: `.overview` = elevated wide framing origin; `.orbit` = attach a `repeatForever` rotation `SCNAction` around the floor center; `.inspect(id)` = compute a pose in front of that agent node and move the camera there. All transitions via `SCNTransaction` (duration 0.8, ease-in-ease-out). `.orbit` must be cancellable (remove the action when switching).
- [ ] **Step 2:** Store an `HQCameraController` on the `Coordinator`; expose current mode from `HeadquartersView` `@State`; drive `apply` from `updateUIView`.
- [ ] **Step 3 (Claude compile-check):** compile → no errors.
- [ ] **Step 4 (User on iPhone):** A temporary debug switch (3 buttons) flips Overview / Orbit / Inspect(first agent) with smooth, non-jarring transitions; Orbit sweeps continuously and stops cleanly when leaving it.
- [ ] **Step 5:** Commit: `git commit -am "feat(hq): overview/orbit/inspect camera modes"`

---

### Task 7: Tap-to-inspect selection

**Files:**
- Modify: `HQSceneView.swift` (hit-test gesture), `HeadquartersView.swift` (`selectedAgentID`)

**Interfaces:**
- Produces: on tap, sets `HeadquartersView.selectedAgentID: String?` and applies `.inspect(agentID:)`.
- Consumes: `Coordinator.agentNodes`, `HQCameraController`.

- [ ] **Step 1:** Add a `UITapGestureRecognizer` in `makeUIView`; in the handler, `hitTest` the tapped point, walk up `parent` chain to find the owning `HQAgentNode`, resolve its agent id, set a binding back to `HeadquartersView.selectedAgentID`, and apply `.inspect`.
- [ ] **Step 2 (Claude compile-check):** compile → no errors.
- [ ] **Step 3 (User on iPhone):** Tapping an agent glides the camera to them and marks them selected (verify via a temporary text label showing `selectedAgentID`).
- [ ] **Step 4:** Commit: `git commit -am "feat(hq): tap-to-inspect agent selection"`

---

### Task 8: Cinematic HUD (`HQHud`)

**Files:**
- Create: `HermesMobile/Sources/HermesMobile/Views/Headquarters/HQHud.swift`
- Modify: `HeadquartersView.swift` (overlay `HQHud`, remove debug controls)

**Interfaces:**
- Produces: `struct HQHud: View` taking bindings for camera mode + selected agent, plus `OrgStore`/`CompanyStore`. Emits a Message action → presents existing `AgentChatView(agent:)`.
- Consumes: `CompanyStore.snapshot` / `pendingGates`, `OrgStore.agent(id:)`, `HermesTheme`, `AgentChatView`.

- [ ] **Step 1:** Build `HQHud`: top **pulse strip** ("N building · M decisions waiting" from `company.snapshot`/`pendingGates`); a bottom **camera switcher** (Overview/Orbit/Inspect segmented, glassy `hermesCard`); when `selectedAgentID != nil`, an **inspect card** (name, title, current-work line from status, status chip) with a **Message** button that presents `AgentChatView(agent:)`. Minimal, glassy, non-cluttered.
- [ ] **Step 2:** Overlay `HQHud` in `HeadquartersView`'s `ZStack`; delete the Task 6/7 debug controls.
- [ ] **Step 3 (Claude compile-check):** `xcodegen generate` + compile → no errors.
- [ ] **Step 4 (User on iPhone):** The HQ now has a premium HUD: live pulse strip up top, camera switcher works, tapping an agent shows the inspect card, Message opens that agent's chat. Whole thing feels like a live command center.
- [ ] **Step 5:** Commit: `git commit -am "feat(hq): cinematic HUD overlay + agent inspect + message"`

---

## Self-Review

- **Spec coverage:** Environment/space → T1; distinct exec vs dept offices → T1+T2; agent identity+tint → T4; live status (active/thinking/collab/blocked/waiting/urgent/idle) → T3+T5; camera Overview/Orbit/Inspect → T6+T7; HUD pulse/switch/inspect/Message → T8; preserve app + War Room wiring → T0; performance (light cap, LOD, no per-frame alloc) → Global Constraints + T1/T5. Scaling path is future slices (out of scope). ✅ All Slice-1 spec sections map to a task.
- **Placeholder scan:** No "TBD/handle edge cases/similar to Task N". Logic tasks (T2, T3) carry real test code; scene tasks carry concrete structural steps + explicit on-device checks (the only honest "test" for SceneKit visuals given Claude cannot run the simulator). ✅
- **Type consistency:** `HQOfficeArchetype`, `HQPlacement`, `HQLayout.placements(for:)`, `HQAgentStatus`, `AgentStatusResolver.status(for:in:)`, `HQAgentNode.applyStatus(_:)`, `HQSceneBuilder.zoneAnchors`, `HQCameraMode`/`HQCameraController.apply(_:agentNodes:)`, `Coordinator.agentNodes` used consistently across tasks. ✅

## Notes on the test cycle (honesty)

SceneKit visual output cannot be asserted by Claude — there is no simulator run and no pixel oracle. So: pure logic (T2, T3) is real XCTest TDD; everything visual is **Claude compile-check + a specific, single on-device check by the user**. If a visual step looks wrong on device, that's the feedback loop — we iterate that task before moving on, exactly like a red test.
