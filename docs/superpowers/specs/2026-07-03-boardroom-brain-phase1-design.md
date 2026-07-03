# Boardroom "Second Brain" — Phase 1: Constitution + Vault Memory Read-Back

Date: 2026-07-03
Status: **DRAFT — awaiting owner approval** (no code written yet)

## 1. Context & problem

The Boardroom company engine already *writes* an Obsidian-shaped Company Vault at
`~/Documents/Boardroom-Vault/` — meeting minutes (`write_meeting_to_vault`,
`hermes_mobile_relay.py:1113`), a running `decisions/Decision Log.md` (`:1137`),
and `Home.md` (`:1077`). But **nothing reads it back**. Agents decide, Lena files
the decision, and the next turn's agents have no memory of it. Server-side prompts
are assembled from static souls only — `role_prompt` = `COMPANY_CULTURE` +
`ROLE_SOULS[role]` + task body (`hermes_company.py:538`). There is no persisted
"single source of truth" about the company, and no retrieval of past decisions.

This is the "firehose pointing outward": the system produces memory it never consumes.

## 2. Goal (Phase 1 scope)

Close the read loop for the **autonomous company engine**:

1. **Company Constitution** — a persisted, human-editable `Company.md` at the vault
   root: thesis, chain of command, operating principles, priorities. One source of
   truth the owner can edit in Obsidian.
2. **Memory read-back** — before a *deliberative* agent turn, inject a compact
   "company memory" block (the constitution + the most recent decisions) into the
   prompt, so agents reason with the company's real history instead of re-deriving it.

### Explicitly OUT of scope (later phases, already agreed)
- Phase 2: proactive nightly briefing push + fixing `BriefingCenter`'s invented data.
- Phase 3: self-improving "lessons" loop.
- Phase 4: per-role model routing (`-m` flag — confirmed feasible: `hermes chat`
  accepts `-m/--model`).
- **No iOS/Swift changes in Phase 1.** All work is server-side Python → verifiable
  with the existing pytest suites and a relay restart; the owner does not rebuild the app.

## 3. Approaches considered → decisions

**Retrieval mechanism.**
- (A) *Simple recency + size cap* — read `Company.md` + tail of `Decision Log.md`,
  concatenate, cap length. **CHOSEN.** The vault is tiny; deterministic and testable.
- (B) Embeddings / vector index — semantic retrieval. Rejected for Phase 1: adds a
  model/DB dependency, latency, and an index-sync burden for a handful of notes. YAGNI.
- (C) Rely on the `hermes` CLI's per-role `--resume` session. Rejected: opaque, not
  shared across roles, not grounded in the vault.

**Injection point.**
- (A) *Relay chokepoint* — inject in `company_cli_runner` (`hermes_mobile_relay.py:579`),
  the single funnel for every company turn. **CHOSEN** — keeps the pure engine
  (`hermes_company.py`) untouched and testable.
- (B) Thread a `memory` argument through the pure engine's prompt builders. Rejected:
  more invasive; spreads vault I/O into the pure engine.

**Constitution content.**
- (A) *Static, human-authored file*, seeded once from `COMPANY_CULTURE` + role roster,
  then owner-edited in Obsidian. **CHOSEN.** Live state (active initiatives) is
  retrieved separately, not kept in sync inside the file.
- (B) Auto-regenerated dynamic file. Rejected: sync complexity for little gain.

## 4. Design / components

### Component 1 — Constitution file (`ensure_constitution()`)
Mirrors `ensure_vault_home()`. If `Boardroom-Vault/Company.md` is absent, seed it:
```
# <Company name> — Constitution

## Thesis
<one-paragraph placeholder the owner edits: what this company is, who it serves, how it wins>

## Chain of command
- Chairman (Andrew) — owner, final authority
- CEO — chairs the board, owns outcomes
- CFO / CTO / Head of Marketing / Head of Research — the board
- Lead Builder, QA + Design lead — execution & gate
- Lena — the Chairman's executive assistant

## Operating principles
- Real, finished, verifiable work — never faked, padded, or hidden.
- Consequential/irreversible moves get the Chairman's explicit YES first.
- Stay fully within the law.

## Current priorities
<owner edits — e.g. "Ship one revenue-positive initiative this month">
```
Called on relay startup and on `/company/vault/sync`. Add a `- [[Company]]` pointer
to `Home.md`. Never overwrites an existing file.

### Component 2 — Memory retriever (`build_memory_block()`)
Pure, fail-safe function:
- Read `Company.md` (cap ~1500 chars).
- Read `decisions/Decision Log.md`, keep the **last ~8** `## ` entries (cap ~1200 chars).
- Return one block:
  ```
  ## Company memory (shared brain — read before you decide)
  ### Constitution
  <constitution text>
  ### Recent decisions
  <tail of the decision log>
  ```
- Total hard cap (~2800 chars) to protect latency/token cost.
- **Any exception → return `""`.** Vault reads must NEVER break a turn (mirrors the
  existing "vault filing must never break a meeting" discipline at `:1151`).

### Component 3 — Gated injection (`compose_company_prompt(role, prompt)`)
Pure, testable helper used by `company_cli_runner`:
- **Deliberative allowlist** = `{ceo, cfo, cto, marketing, builder, qa}` → prepend the
  memory block: `f"{block}\n\n{prompt}"`.
- **Skip** `research` (Scout emits strict JSON per `SCOUT_JSON_SPEC`) and `lena`
  (minutes summarization) — injecting prose would corrupt their strict-format outputs.
- Empty block (missing vault) → return `prompt` unchanged.
`company_cli_runner` (`:579`) calls `compose_company_prompt(role, prompt)` before
`company_chat_command`.

### Component 4 — (thin) app-chat constitution
For interactive app agents (AgentChat/CompanyChat/MeetingRoom/AgentCall) that flow
through `/chat` + `/chat/stream`: prepend the **constitution only** (compact, no
decision log) for company-scoped `sessionKey`s (`hermes-mobile-*` except
`hermes-mobile-briefing`). Skipped for voice-fast turns to protect latency. This is
the smallest slice that gets the shared context to the interactive agents too; it is
isolated so it can be dropped if it risks the chat path.

## 5. Data flow
```
owner edits Company.md (Obsidian)  ─┐
meetings → Lena files decisions ───┼─→ Boardroom-Vault/{Company.md, decisions/Decision Log.md}
                                    │
company turn (ceo/cfo/…) ──> company_cli_runner ──> compose_company_prompt(role, prompt)
                                                        └─ build_memory_block() reads the vault
                                                        └─ prepend for deliberative roles only
                                    ──> hermes chat -q <prompt-with-memory>
```

## 6. Error handling
- All vault reads wrapped; failure → empty block → turn proceeds exactly as today.
- Missing vault dir / missing files → `""`, no crash.
- Size caps prevent a huge decision log from blowing the prompt.
- No change to timeout, session, or kill-tree behavior.

## 7. Testing (pytest — `Scripts/test_hermes_mobile_relay.py`)
- `build_memory_block`: temp vault fixture → block contains constitution + recent
  decisions; respects caps; returns `""` when vault absent.
- `compose_company_prompt`: prepends for `ceo`; does NOT prepend for `research`/`lena`;
  returns input unchanged when block empty.
- `ensure_constitution`: seeds when absent; does not overwrite when present.
- Existing suites (`test_hermes_company.py`, `test_hermes_mobile_relay.py`) stay green
  (pure engine untouched).

## 8. Rollout / verification
1. `pytest Scripts/test_hermes_mobile_relay.py Scripts/test_hermes_company.py` — all green.
2. Restart the relay unsandboxed (per standing ops note); confirm `Company.md` seeded.
3. Evidence check: trigger one company ask/meeting; confirm the injected block reaches
   the prompt (log/inspect) and a recent decision is echoed in an agent's reasoning.
4. No app rebuild required.

## 9. Open questions / risks
- **Prompt bloat / latency:** capped at ~2.8KB; company turns already run long, so the
  marginal cost is small. Voice-fast path excluded.
- **Constitution quality:** seed is a placeholder; value grows once the owner edits it.
- **Allowlist correctness:** if any deliberative role is later reused for a strict-format
  call, revisit the gate.
```
