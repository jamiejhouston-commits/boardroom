# Games Studio — the first Boardroom division

**Date:** 2026-07-05
**Status:** approved (owner: "Build … the REAL FINAL PRODUCT")

Boardroom is a 3D walkable AI holding-company HQ. This spec adds its **first
division**: the **Games Studio**, entered through a **Games Production Room** off
the HQ floor. Phase 1 because it is the owner's own low-liability company work,
it proves the shared spine (division engine + asset/room integration), and its
signature moment — *walk up to the arcade cabinet in the 3D office and play the
mini-game the agents shipped* — is the jaw-dropping demo of the whole product.

This is not a mock. Every piece is real: a genuinely playable game, a real
relay-side studio pipeline with a Fun Gate that can reject un-fun builds, and a
3D room built to the exact quality bar of the shipped `HQSceneBuilder` world.

## What the studio makes

Narrow, web/HTML5 output — three product lines:

- **daily-puzzle** — one fresh puzzle a day, retention loop
- **hyper-casual** — 30-second-to-fun, one-thumb, endless
- **viral funnel** — score → share → challenge

The **flagship shipped title** is **Skyline Stack** (hyper-casual tower-stacker),
which ties to the HQ's existing skyline motif. It ships in the app bundle, is
fully playable in the arcade cabinet, and is the studio's first real product of
record.

## Three layers

### 1. The game runtime — `Resources/GamesStudio/SkylineStack.html`

A single self-contained HTML file (no external anything — ATS/CDN irrelevant):
Canvas 2D render loop, WebAudio blips, a swinging/​sliding block you drop to
build a tower, overhang trimming, combo/perfect-stack scoring, rising difficulty,
`localStorage` best score, and a restart loop. Boardroom palette (deep navy,
emerald, gold). On every game-over and new-best it calls
`window.webkit.messageHandlers.arcade.postMessage({event, score, best})` so the
native cabinet runtime records the owner's real high score. Degrades to a no-op
outside the app.

### 2. The studio engine — `Scripts/hermes_games_studio.py` (+ tests)

Mirrors `hermes_company.py`: pure functions, an injected `runner(role, prompt)
-> str`, fully unit-testable offline. A game moves through stages:

```
concept → design → build → playtest → fun_gate → distribution → shipped
                                          │
                                          └── rejected (not fun) → back to design
```

Roles/agents:
- **Game Designer** — writes the design pillars, and owns the **Fun Gate**: after
  playtest it returns `APPROVED` or `REJECTED` with explicit reasons. A build
  that isn't fun does **not** ship — it's sent back to design. `fun_gate_passed()`
  parses the verdict the same disciplined way `review_passed()` does in the
  company engine.
- **Playtesters** — a **playtest choreography**: N tester agents each play the
  build and return a short reaction + a 1–10 fun rating; the room animates its
  robot testers around this data. `playtest_scores()` aggregates.
- **Distribution agent** — proposes/records status per channel
  (**itch.io / Reddit / portals**): `planned → submitted → live`.

State shape (`new_studio_state`): `enabled`, `games[]`, `events[]`. Each game:
`id, title, line, stage, pillars, build_notes, playtests[], fun_gate{verdict,
reasons}, distribution{itch,reddit,portals}, runtime (html filename), score,
created`. Persisted atomically like `CompanyStore`.

Relay wiring (`hermes_mobile_relay.py`): `GET /games` (slim summary),
`GET /games/game/<id>` (detail), `POST /games/start|halt`, and a heartbeat that
advances one game per tick (guarded by the same quiet-hours/overload rules).
The flagship Skyline Stack is **seeded** so a fresh studio already has one real
shipped title.

### 3. iOS — models, store, room

- `Models/GamesStudioModels.swift` — `Codable` mirror of the engine JSON, plus a
  `.flagship` bundled state so the room is fully alive **offline** (the flagship
  game genuinely exists in the bundle — the fallback is real, not faked).
- `Services/GamesStudioStore.swift` — `@MainActor ObservableObject`: refresh from
  the relay, fall back to `.flagship`, and persist the owner's real arcade high
  score. Same shape as `CompanyStore`.
- `Services/HermesRelayClient.swift` — `gamesState()`, `gamesGameDetail(id:)`,
  `gamesStart/Halt`.

## The 3D Games Production Room

A **separate SceneKit scene** (keeps the HQ scene lean; keeps divisions modular),
presented full-screen when the owner enters through the HQ portal. Built with the
**same** palette constants, PBR materials, real-light rig, emissive seams,
single-sided down-facing ceiling panels, fog, HDR+bloom(0.85) camera, and
`HQAssetLibrary` assets + primitive fallbacks as `HQSceneBuilder`.

Required features → implementation:

| Spec requirement | Build |
|---|---|
| Games Production Room | `GamesRoomBuilder` — 30×24 floor, emerald seams, walls, ceiling panels, real omni/spot rig, fog |
| Giant arcade screen (live build) | Mega wall screen: SpriteKit board — title, **build status**, stylized attract preview, Fun-Gate verdict badge (`GamesRoomBoards.megaScreen`) |
| Playtest couch w/ robot testers | `Sofa` + `Robot` USDZ testers seated with controllers, ambient "playing" bob + reaction pulses tied to playtest data |
| Design whiteboard (notes) | Wall board — the game's design pillars + playtest one-liners (`GamesRoomBoards.whiteboard`) |
| **Actually playable arcade cabinet** | `GamesRoomBuilder.arcadeCabinet` — cabinet body, marquee (title glow), bezel screen running the attract loop, control panel w/ joystick + buttons. Walk up + tap → real game |
| Fun Gate (approved/rejected + reasons) | A physical lit **gate arch** the game passes through; emerald when APPROVED, amber when REJECTED; tap → reasons sheet (`GamesRoomBoards.funGate`) |
| Distribution (itch/Reddit/portals) | Distribution totem/board with a row per channel + status lamp (`GamesRoomBoards.distributionBoard`) |

Navigation reuses the shipped first-person feel via a generalized, room-agnostic
`RoamField` (bounds + blocker rects) and `RoamMath.step(...)`; the HQ's own
`HQRoam` is left untouched. Overview / Orbit / Walk camera modes as in HQ.

**The signature experience:** tap the cabinet (or walk into it) → the cabinet
screen "powers on" into a framed arcade bezel overlay (`ArcadeGameRuntime`, a
`WKWebView` loading the bundled game) → the owner plays the real Skyline Stack the
studio shipped, high score recorded back into studio state.

## Portal from the HQ

A lit **"GAMES STUDIO"** doorway on the HQ floor (`HQSceneBuilder` adds a portal
node named `hq.tap.gamestudio`, plus a walk-trigger volume). Tapping it — or
walking into it in roam — presents `GamesRoomView` as a `fullScreenCover` from
`HeadquartersView`. One line to add the next division later.

## Modularity (for future divisions)

- Room scaffolding split into `GamesRoomBuilder` (geometry), `GamesRoomBoards`
  (live SpriteKit surfaces), `GamesRoomSceneView` (host + roam + taps),
  `GamesRoomView` (SwiftUI HUD/sheets) — the same file taxonomy as `Headquarters/`.
- `RoamField`/`RoamMath` are generic and shared.
- The engine's stage/gate/distribution pattern is copy-forward for Client
  Services / Commerce / SaaS later — **not built now** (explicitly out of scope).

## Out of scope (do not build now)

Client Services, Commerce, SaaS/app studio, payments, multi-tenant accounts,
financial analysis, store builder, consulting workflow.

## Testing

- `Scripts/test_hermes_games_studio.py` — offline engine tests: stage advance,
  Fun-Gate approve/reject parsing, playtest aggregation, distribution transitions,
  seed of the flagship, state persistence.
- Swift unit tests for the pure `RoamMath`/`RoamField` (walls + blockers) and the
  `GamesStudioModels` flagship decode.
- `xcodegen generate` + `xcodebuild build` compile-check only (never boot a
  simulator — the owner runs on device).

## How to run

1. `cd "hermes ios" && xcodegen generate` (picks up the new resources + sources).
2. Open in Xcode, build to the owner's iPhone.
3. War Room → **Enter Headquarters** → walk to the lit **GAMES STUDIO** door →
   enter the Games Production Room → walk to the arcade cabinet → **PLAY**.
4. (Optional, live studio) start the relay; `POST /games/start`. Without it, the
   room runs on the bundled flagship state and the cabinet is fully playable.
