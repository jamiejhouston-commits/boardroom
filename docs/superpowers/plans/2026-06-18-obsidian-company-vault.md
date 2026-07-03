# Boardroom × Obsidian — the Company Vault

> **Status:** design spec / roadmap. No app code in here by request — this describes
> *what* each piece does and *why*, not the implementation. Read-only analysis of the
> current codebase informed it.

**Goal:** Give the company a single, persistent, linked **institutional memory** — an
Obsidian vault every agent reads and writes, that the app surfaces and the owner can
open directly in Obsidian (Mac + iPhone). Turn Boardroom from "agents with short-term
memory" into "a company with a searchable brain."

---

## 1. The problem (what the read-only pass found)

Company knowledge lives in three disconnected silos:

| Silo | Where | Problem |
|---|---|---|
| State blob | `~/.hermes/mobile-company.json` | initiatives/meetings/asks/tasks/decisions all packed in one JSON; minutes + decisions buried inside initiative objects; not human-browsable, not linked |
| Deliverables | `~/Documents/Boardroom/<slug>/` | 8 shipped products on disk with **no link** back to the initiative, meeting, or decision that produced them |
| Live context | `CompanyContext.brief` (rebuilt each turn) | **ephemeral, capped at ~5 items per category, no links, no history, not searchable** — this is how agents "share knowledge" today, and it's the weak link |

Nothing connects initiative ↔ meeting ↔ decision ↔ deliverable ↔ agent. The context
brief is re-derived every turn (token cost) and truncated (lost coordination).

**Installed and ready on the Mac's Hermes** (verified): `obsidian-markdown`,
`obsidian-bases`, `obsidian-cli`, `json-canvas`, `defuddle`.

---

## 2. The architecture — one vault, three windows

```
        ┌──────────────── ~/Documents/Boardroom-Vault/ ────────────────┐
        │  initiatives/   meetings/   decisions/   agents/             │
        │  research/      deliverables/   _bases/   _canvas/           │
        └───────▲───────────────────▲───────────────────▲─────────────┘
                │ obsidian-cli       │ relay reads        │ opens directly
        ┌───────┴──────┐     ┌───────┴───────┐    ┌───────┴────────┐
        │  Agents       │     │  Boardroom app │    │  You (Obsidian │
        │ (read+write   │     │ (reads vault   │    │  Mac + iPhone) │
        │  via Hermes)  │     │  via relay)    │    │  read + write  │
        └──────────────┘     └───────────────┘    └────────────────┘
```

- **Agents** read/write the vault through the already-installed Hermes obsidian skills.
- **The app** reads vault-derived data through new relay endpoints (e.g. `/company/vault/...`).
- **You** open the same folder as an Obsidian vault — every edit flows both ways.

Single source of truth. Two extra windows onto it.

---

## 3. The note model (linked markdown + frontmatter)

Every entity becomes a note with queryable frontmatter and wikilinks.

**Initiative** — `initiatives/<slug>.md`
```
---
type: initiative
stage: execution
score: { heat: 8, fit: 7, effort: 4 }
repo: https://github.com/.../...
created: 2026-06-18
---
# One-Tap Brain Dump Cleaner
Pitch… Brief… Minutes (body). Links: [[meeting-2026-06-18]], [[decision-greenlight-…]], [[builder-agent]]
```

**Meeting / minutes** — `meetings/<date>-<topic>.md` — attendees as `[[agent]]` links,
the transcript as body, a "Decisions" section linking to decision notes.

**Decision** — `decisions/<date>-<title>.md` — `outcome: greenlit|shipped|killed`,
links to the initiative + meeting. (Powers the conference-room Decision Vault TV.)

**Agent** — `agents/<id>.md` — soul, remit, current work; `manager: [[ceo]]`,
`reports: [[…]]` → the chain of command becomes a real link graph.

**Research clip** — `research/<source>.md` — clean markdown via `defuddle`, with source URL.

**Deliverable** — `deliverables/<slug>.md` — links repo ↔ initiative ↔ demo.

---

## 4. Bases (live database views the app + Obsidian both read)

- `_bases/pipeline.base` — initiatives grouped by `stage` → the live pipeline.
- `_bases/decisions.base` — decisions by date/outcome → the **Decision Vault**.
- `_bases/tasks.base` — Kanban tasks by status.

The app's conference-room TVs and Boardroom screens read these instead of the JSON blob.

## 5. Canvas (visual, later)

- `_canvas/org.canvas` — org chart as a node graph (fits the app's 3D/visual vibe).
- `_canvas/pipeline.canvas` — initiatives flowing across stages.

---

## 6. Phased rollout (additive-first, low risk)

**Phase 0 — Lena writes to the vault (the wedge).**
Lena (PA) writes each meeting's **minutes + decisions** into the vault as linked notes.
*Additive — changes nothing existing.* Instantly makes Meeting Minutes + Decision Vault
real, permanent, browsable. Proves the value with near-zero risk. **Start here.**

**Phase 1 — Bases the app reads.**
Generate `pipeline.base` / `decisions.base` from initiatives + decisions; the app reads
them via a relay endpoint. The TVs show real, queryable data.

**Phase 2 — Vault-backed context brief.**
Replace the capped 5-item `CompanyContext.brief` text block with "pull the relevant
linked notes." Fixes coordination + cuts token cost (no re-deriving every turn). **Biggest
unlock.**

**Phase 3 — Research clipping + linked deliverables.**
Research agent clips sources via `defuddle`; shipped folders get linked deliverable notes.

**Phase 4 — Canvas org/pipeline view.** The visual cherry.

---

## 7. The honest catch (migration)

Phases 0–1 and 3 are **additive** (the vault mirrors/augments; JSON stays the source of
truth) → safe. **Phase 2** moves the source of truth for shared context *into* the vault —
that's a real migration, done incrementally: agents *also* write the vault first, then
progressively *read* from it, with the JSON as fallback until proven.

## 8. What changes, by area (described, not coded)

- **Relay (`hermes_mobile_relay.py`)**: a vault helper (write note / read base via `obsidian-cli`); new endpoints `/company/vault/*`; Lena's meeting-end hook writes minutes/decisions.
- **Engine (`hermes_company.py`)**: on ship/gate/meeting-end, emit a vault note (additive alongside existing state).
- **Agents (`OrgChart`/`SkillLibrary`)**: equip Lena + Research with the obsidian skills (skills already installed on the Mac).
- **App**: Decision Vault / Minutes views read vault-derived data; optional "Open in Obsidian" deep link.

## 9. Verification

- Phase 0: after a meeting, the vault has a linked minutes note + decision notes; opening
  the vault in Obsidian shows them connected. Nothing in the existing app breaks.
- Each phase ships behind the additive principle: prove the new path before removing the old.

---

**One-line take:** Obsidian gives Boardroom an institutional memory you can see, search,
and graph — a real moat. The wedge (Lena → vault) is cheap, safe, and immediately useful.
