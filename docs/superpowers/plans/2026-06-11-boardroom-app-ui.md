# Boardroom App UI (Phase 2) Implementation Plan

> Executed inline in-session immediately after writing (executing-plans); plan is interface-level by design — full code lives in the commits, one commit per task.

**Goal:** Put the autonomous company in the owner's hand: a Boardroom screen with initiative cards, one-tap Greenlight/Revise/Kill gates, Demo Day scheduling through MeetingHub, and gate notifications.

**Architecture:** `CompanyModels` (Codable mirror of relay JSON, snake_case strategy) → `HermesRelayClient` company endpoints → `CompanyStore` (@MainActor ObservableObject; refresh/poll, gate actions, new-gate local notifications) → `BoardroomView` (+detail) reached from a Command Center hero card. Background refresh via BGAppRefreshTask fires a local notification when a gate is waiting.

**Verification constraint:** app-side tests can't be run here (owner-only device builds; no simulator — standing rule). Every task verifies via `xcodebuild … CODE_SIGNING_ALLOWED=NO build` after `xcodegen generate`. Relay endpoints were already live-verified in Phase 1.

---

### Task 1: Models + relay client endpoints
- Create `HermesMobile/Sources/HermesMobile/Models/CompanyModels.swift`: `CompanyState` (enabled, thesis, lastTick, config, initiatives), `CompanyInitiative` (id, title, pitch, stage, created, score, callsUsed, brief, artifacts, note, minutes optional), `CompanyScore`, `CompanyMinute`, `CompanyConfig`; `stage` helpers (`isGate`, display name, progress fraction).
- [x] Modify `Services/HermesRelayClient.swift`: `companyState()`, `companyStart(thesis:)`, `companyHalt()`, `companyGate(id:decision:note:)`, `companyInitiativeDetail(id:)` — GET/POST with bearer auth, decode via `.convertFromSnakeCase`.
- Verify: xcodegen + compile-check → BUILD SUCCEEDED. Commit.

### Task 2: CompanyStore
- [x] Create `Services/CompanyStore.swift`: `@MainActor final class CompanyStore: ObservableObject` — `@Published state/isLoading/errorMessage`; `refresh(relay:)`, `setEnabled(_:thesis:relay:)`, `decide(id:decision:note:relay:)`; `pendingGates` computed; tracks seen gate IDs in UserDefaults and posts a local notification ("The board needs you") for newly arrived gates.
- Inject in `HermesMobileApp` as `@StateObject`, environmentObject on RootView.
- Verify: compile-check. Commit.

### Task 3: BoardroomView + Command Center entry
- [x] Create `Views/BoardroomView.swift`: company on/off + thesis editor; initiative cards (stage progress bar, score chips, decision brief, Greenlight/Revise/Kill buttons with note prompt at gates, "Schedule Demo Day" via `MeetingHub.schedule` at gate2); `InitiativeDetailView` (minutes timeline by stage/role, artifacts list); pull-to-refresh + 60s polling timer while visible.
- [x] Modify `Views/CommandCenterView.swift`: `boardroomCard` hero (pending-gate badge) → NavigationLink to BoardroomView, placed after `briefingCard`.
- Verify: compile-check. Commit.

### Task 4: Background gate alerts
- [x] Modify `project.yml`: `UIBackgroundModes: [fetch]`, `BGTaskSchedulerPermittedIdentifiers: [com.nousresearch.HermesMobile.companyRefresh]`.
- [x] Modify `HermesMobileApp.swift`: register BGAppRefreshTask, schedule on background, handler fetches `/company` and fires the same new-gate notification; reschedules itself. (iOS decides actual timing — discretionary.)
- Verify: xcodegen + compile-check. Commit.

**Owner handoff:** rebuild in Xcode (⌘R); flip the company on from the Boardroom card; the halted Phase-1 initiative ("One-Tap Brain Dump Cleaner") resumes at next tick.
