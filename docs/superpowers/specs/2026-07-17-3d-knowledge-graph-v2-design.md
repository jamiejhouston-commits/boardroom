# 3D Knowledge Graph v2 — "Galaxy Brain"

**Date:** 2026-07-17
**Scope:** `Scripts/hermes_mobile_relay.py` (vault graph endpoint), `HermesMobile/Sources/HermesMobile/Views/VaultGraphView.swift`, `HermesRelayClient.swift` (model fields only), tests.

## Why

Andrew rebuilt his Obsidian knowledge base (~193 notes: 106 Projects, 81 root, 4 wiki, 1 Inbox, 1 raw, plus 7 canvas/base files; ~400 wikilinks; 55 company-vault notes). The 3D brain must (a) be **all-encompassing** — show every note and every link — and (b) look **premium** with real exploration capabilities.

Today it falls short on both:

1. **Coverage** — the app renders at most 150 edges in 3D / 75 in 2D (per-edge `SCNCylinder` = per-edge draw call forced the cap). `.canvas` files are ignored. No folder/tag/recency metadata is served, so the KB's structure is invisible. Unresolved wikilinks render as real notes.
2. **Design** — all nodes pinned to one sphere shell (clusters geometrically impossible), teal-neon palette + bloom 1.15/0.30 (violates the muted navy-charcoal + gold standard), `updateUIView` rebuilds the scene unconditionally (tapping a node resets the camera).

## Approaches considered

- **A. Keep shell layout, recolor + raise edge cap** — smallest diff, but clusters stay impossible and per-edge cylinders can't render 400+ links; fails "all-encompassing" and "mind-blowing".
- **B. Galaxy layout + line-primitive edges + focus mode (chosen)** — free-space force layout with community anchors, all edges in one draw call, metadata-rich nodes, tap-to-focus exploration. Real capability gain at bounded complexity.
- **C. Full GPU physics / Metal custom renderer** — over-engineering for ≤450 nodes; SceneKit handles this scale fine.

## Relay changes (`vault_graph()`)

One read per note (currently wikilinks re-reads); from that read derive:

- `folder`: top-level folder ("Projects", "wiki", "Inbox", "raw"; "" → "Notes"). Company notes: "Boardroom" (meetings/decisions/Lessons keep their `type`).
- `modified`: int epoch mtime. `words`: int word count. `tags`: inline `#tag` matches (deduped, cap 6).
- `phantom: true` on nodes created only as unresolved wikilink targets (both vaults).
- `.canvas` files become nodes (`type: "canvas"`), with edges to each embedded `"type":"file"` md note that resolves. Parse failures skip the canvas silently (a vault read must never break the graph).
- Graph-level `vault: <obsidian vault dir name>` so the app can deep-link `obsidian://open?vault=…&file=…`.
- Cap stays 400 by mtime with honest `truncated: true` (250 real nodes today).

Existing key shapes (`id`, `label`, `type`, `source`/`target`) unchanged — old app builds keep working.

## App changes (`VaultGraphView.swift`)

**Model:** `VaultNode` gains optional `folder`, `modified`, `tags`, `phantom`, `words`; `VaultGraph` gains optional `vault`. All optional → tolerant of old relays.

**Layout (3D):** label-propagation community detection (deterministic, ~8 sweeps). Communities ≥4 members get anchors on a fibonacci sphere (r≈2.6, cap 14); smaller ones fall back to a folder anchor. Force sim in free space: O(n²) repulsion (adaptive iterations as today), edge springs, anchor gravity 0.06, center gravity 0.02, **no shell pinning**. Deterministic seeding around anchors. 2D solar mode kept as-is.

**Rendering:**
- ALL edges in one `SCNGeometry` `.line` element with per-vertex colors (endpoint folder colors, low alpha) — one draw call for the whole web. Hub-adjacent edges (cap ~60) additionally get thin muted cylinders for weight. Focus edges drawn on demand in gold.
- Nodes stay billboard textures, recolored per folder/type with the muted premium palette: Projects gold, wiki emerald, root-notes warm cream, Inbox amber, raw slate-blue, canvas violet, agents gold, meetings muted cyan, decisions emerald, phantom dim slate. Notes modified in the last 7 days get a thin gold outer ring.
- Labels bounded (SKLabel texture-limit lesson): top hubs + one caption per major cluster, total ≤ ~28 planes; up to 16 more created on demand in focus mode, removed on unfocus.
- Backdrop: wireframe shell + rings **removed** in 3D; subtle point-primitive starfield (one node) + distance fog for depth. Background deep navy-charcoal. Bloom ~0.65/0.55/14 (tasteful, not neon).
- `updateUIView` rebuilds only when graph or settings actually changed (coordinator caches both) — fixes the camera-reset bug. Focus changes never rebuild.

**Capabilities:**
- **Focus mode:** tap node → non-neighborhood dims to ~0.1, neighbor labels appear, gold focus edges, auto-rotation pauses; floating SwiftUI card (title, folder chip, links · modified, Read note / Open in Obsidian). Tap empty space → unfocus, rotation resumes. No camera hijack (allowsCameraControl owns the camera).
- **Folder filter chips:** legend becomes tappable colored chips (horizontal scroll) that toggle folder visibility; works with existing search (local-graph behaviour).
- **Recency paint:** controls toggle recolors nodes by age (recent gold → old slate) using `modified`.
- **Detail sheet v2:** linked-notes section (tap → navigates the sheet to that neighbor), metadata (folder, modified, words, tags), "Open in Obsidian" for `obsidian:` nodes via the graph's `vault` name.
- Stats line: notes · links · clusters.

## Error handling

Relay: every per-note/per-canvas parse wrapped; failures skip the file, never the graph (existing convention). App: all new fields optional; missing → sensible defaults (folder "Notes", no ring, no chip).

## Testing / evidence

- pytest: update the exact-equality node test; add cases for folder/modified/words/tags, phantom marking, canvas edges, `vault` name, and old-key stability. Full suite must pass.
- `xcodebuild build` compile-check only — **owner builds/runs on his iPhone** (hard rule).
- Offscreen macOS SceneKit bench (Wave-7.1 pattern): render the new scene from the real graph JSON at several angles + a focus state; eyeball, iterate palette/layout before calling it done.

## Deliberately skipped

GPU/Metal physics, AR mode, camera fly-to on focus (fights `allowsCameraControl`), `.base` files as nodes (database views, no links), LLM "ask your brain" (relay spend; BrainDump + search already cover capture/find).
