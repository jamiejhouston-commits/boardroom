# Cinematic AI Headquarters — Slice 1 ("First Light") Design

**Goal:** Transform the War Room / company-floor 3D experience from a cramped grid of identical cube offices into a spacious, cinematic, living AI headquarters. This spec covers **Slice 1 only** — one flagship vertical slice that proves every pillar (space, role-distinct offices, live agents, cinematic camera, premium HUD) at small scale, so the look and the live-state pipeline are locked before scaling to the whole company.

**Approach:** Flagship vertical slice first. Ship Slice 1, verify on-device, then scale the same patterns to all departments/agents in later slices.

**Aesthetic:** Cinematic in the existing palette — navy-charcoal architecture, brushed-metal + smoked-glass, emerald floor under-glow, gold key-lights on the executive wing, soft depth haze. Holographic screens with **restrained** glow. Premium, never neon/gaudy. Sourced from `HermesTheme` (`emerald`, `navy`, `gold`, `steel`, `silver`).

**Tech foundation:** Evolve the existing **SceneKit** stack (no engine rewrite). Mirror the proven `UIViewRepresentable` + `SCNView` + `Coordinator` pattern from `AgentStudio3DView.AgentRoomSceneView` / `CompanyFloorView.RoomDioramaSceneView`.

---

## Constraints & non-negotiables

- **Claude compile-checks only; the user builds/runs on his iPhone.** Every step must be independently verifiable on-device. No simulator runs by Claude.
- **Preserve existing app structure, navigation, and agent functionality.** Additive: new files, wired into the existing `.warRoom` tab. Existing views (`WarRoomView`, `CompanyFloorView`, `AgentStudio3DView`, `MeetingRoomView`, `ARHeadquartersView`) stay reachable.
- **Performance:** must stay smooth on iPhone — level-of-detail (LOD) aware, capped light count, reused geometry/materials, no per-frame allocations.
- **Data-driven:** agent→zone placement comes from a layout model so later slices scale by adding data, not rewriting the scene.

## Out of scope for Slice 1 (later slices)

- All departments / every agent's bespoke office (Slice 1 ships CEO wing + Command Center + 2 dept pods: Research, Engineering).
- Full agent movement/pathfinding/collaboration choreography (Slice 1: rich idle + status motion, not floor traversal).
- First-person, agent-follow, and war-room camera modes (Slice 1: Overview, Orbit, Inspect).
- Full HUD (mission timelines, quick-command palette). Slice 1: pulse strip + camera switch + inspect card + Message action.

---

## Architecture

New files under `HermesMobile/Sources/HermesMobile/`:

| File | Responsibility |
| --- | --- |
| `Views/Headquarters/HeadquartersView.swift` | SwiftUI host: `ZStack { HQSceneView; HQHud }`. Owns camera-mode state, selected-agent state. Injected `OrgStore` + `CompanyStore`. |
| `Views/Headquarters/HQSceneView.swift` | `UIViewRepresentable` wrapping `SCNView` + `Coordinator` (mirrors `AgentRoomSceneView`). Builds scene once, drives camera transitions, updates agent status nodes on state change, routes taps → selected agent. |
| `Views/Headquarters/HQSceneBuilder.swift` | Pure SceneKit environment construction: floor, zones (executive wing, command center, research lab, engineering den), glass partitions, lighting rig, holographic mission wall, depth haze. Palette from `HermesTheme`. |
| `Views/Headquarters/HQLayout.swift` | Data model: maps org agents → a `HQZone` (position, office archetype, scale, accent). `HQZone` archetypes: `.executive`, `.command`, `.researchLab`, `.engineeringDen` (extensible). Decides which agents appear in Slice 1 and where. |
| `Views/Headquarters/HQAgentNode.swift` | Builds a per-agent node = evolved `AgentRobot.node(for:color:)` + a floating holographic **status ring** + role-tint. Exposes `applyStatus(_:)` for live updates. |
| `Views/Headquarters/HQCameraController.swift` | Owns the `SCNNode` camera + named poses (Overview, Orbit path, per-agent Inspect). Smooth transitions via `SCNTransaction` / `SCNAction`. |
| `Views/Headquarters/HQAgentStatus.swift` | `enum HQAgentStatus { active, thinking, collaborating, blocked, waitingForUser, urgent, idle }` + color/emoji/pulse mapping + `AgentStatusResolver` deriving status from `CompanyState`. |
| `Views/Headquarters/HQHud.swift` | SwiftUI overlay: company-pulse strip, camera-mode switcher, inspect card, Message button. Styled with `HermesTheme` / `hermesCard`. |

**Wiring:** `WarRoomView` gains an entry (button/segment) to present `HeadquartersView` full-screen, or `HeadquartersView` becomes the primary `.warRoom` content with the old War Room reachable via a toggle. Chosen in the plan; default: new **"Enter Headquarters"** hero button at the top of `WarRoomView` presenting `HeadquartersView` as a full-screen cover — zero risk to existing War Room.

## Data flow

1. `HeadquartersView` reads `OrgStore.agents` (+ `ceo`, `managers`, `children(of:)`) and `CompanyStore.state`.
2. `HQLayout.zones(for: org)` produces the Slice-1 placement (CEO → executive; a manager each → research/engineering; command center = shared centerpiece).
3. `HQSceneBuilder.build(zones:)` constructs the static environment once in `makeUIView`.
4. `HQAgentNode` builds one node per placed agent; `AgentStatusResolver.status(for: agent, in: companyState)` sets its initial status ring.
5. `updateUIView` observes `CompanyStore.state` changes → recomputes each agent's `HQAgentStatus` → `node.applyStatus(_:)` animates the ring (no scene rebuild).
6. Tap (via `SCNView` hit-test in the Coordinator) → resolves node → sets `HeadquartersView.selectedAgent` → HUD inspect card + camera Inspect glide.

### Status mapping (Slice 1, from `CompanyState`)

- On the active/executing initiative's stage → mapped role is `active`/`executing`.
- Role is a live meeting attendee → `collaborating`.
- Initiative at `gate1`/`gate2` (in `pendingGates`) → the CEO shows `waitingForUser` (✨).
- Initiative `blocked`/`stall_count >= 3` owner role → `blocked`.
- Otherwise → `idle` with gentle breathing motion.
- Mapping lives in `AgentStatusResolver`; it is intentionally simple for Slice 1 and expands later.

## Camera modes (Slice 1)

- **Overview** — elevated wide pose framing the whole floor.
- **Orbit** — slow continuous cinematic arc (repeating `SCNAction`), pausable.
- **Inspect** — smooth glide to a chosen agent, framing their workstation; back-gesture returns to Overview.
Transitions: `SCNTransaction` with ease-in-ease-out, ~0.8s.

## HUD (Slice 1)

- **Pulse strip** (top): "N building · M decisions waiting" from `CompanyStore.snapshot` / `pendingGates`.
- **Camera switcher**: Overview / Orbit / Inspect segmented control.
- **Inspect card** (on selection): agent name, title, current work line, status chip; **Message** button → existing `AgentChatView(agent:)`.
- All styled with `HermesTheme`; glassy, minimal, non-cluttered.

## Verification (on-device, per step)

Each build step ends with a concrete on-iPhone check, e.g.:
1. Empty HQ scene renders (floor + lighting + haze) at 60fps → looks cinematic, not flat.
2. Zones + glass + executive wing visibly distinct; CEO wing reads bigger/brighter.
3. Agents appear in correct zones with role tint + idle motion.
4. Status rings reflect real company state (toggle a gate → CEO shows ✨).
5. Camera Overview/Orbit/Inspect all transition smoothly.
6. Tap agent → inspect card + Message opens the right chat.
Claude compile-checks (`xcodegen` + build compile) between steps; the user does the visual/interaction verification.

## Risks & mitigations

- **Looks flat / cheap** → lock the environment look in step 1–2 before adding agents; depth haze + layered lighting are the priority.
- **Performance dips on iPhone** → cap dynamic lights, bake where possible, reuse materials, LOD the robots, no per-frame allocs; verify fps on-device early.
- **Scope creep into full HQ** → Slice 1 boundary is fixed above; scaling is a later slice.
- **Regression to existing War Room** → additive full-screen cover; existing views untouched.

## Scaling path (post–Slice 1)

Add zone archetypes + more agents to `HQLayout` (data), reuse `HQSceneBuilder`/`HQAgentNode` patterns, then layer: full office variety, floor traversal + collaboration choreography, remaining camera modes (war-room, first-person, follow), and the complete HUD.
