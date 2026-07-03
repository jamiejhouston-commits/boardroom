# Boardroom "Second Brain" — Phase 2 Plan

> Design decisions (owner AFK → proceeding on recommendations): **template digest** for the proactive push (deterministic, no nightly model call); **server-side parts built now** (proactive push 2a + chat-constitution 2c, both testable, no rebuild); **Swift BriefingCenter fake-data fix (2b) implemented but flagged** — needs the owner's app rebuild + is compile-check-only on my side.

**Goal:** (2a) the relay proactively pushes a real daily briefing to the phone; (2c) interactive company-chat agents also read the Constitution; (2b) `BriefingCenter` stops inventing department status.

**Tech:** Python 3 + `unittest` (as Phase 1); one small SwiftUI string change.

## Global Constraints
- Fail-safe: vault/data reads never break a turn or the heartbeat.
- Proactive push fires **once/day** at/after `briefing_hour` (default 8), gated by `briefing_push_enabled` (default True); dedup via module dict `_BRIEFING_PUSH` (same pattern as `_OVERLOAD_PUSH`). No-op with no APNs tokens.
- Chat-constitution injected ONLY for `session.startswith("company-")` and NOT `fast` (voice).
- No new dependencies. Uncommitted; branch decision deferred to owner.

---

### Task 1 (2c): Constitution in app-chat
**Files:** Modify `Scripts/hermes_mobile_relay.py` (`build_memory_block` gains `include_decisions`; add `compose_chat_message`; wire at `:2060`). Test: `test_hermes_mobile_relay.py::CompanyBrainTests`.

- Add `include_decisions: bool = True` to `build_memory_block`; when False, skip the decisions section (constitution only).
- `compose_chat_message(session_key, message, fast=False, root=None)`: return `message` unchanged if `fast` or not `session_key.startswith("company-")` or block empty; else `f"{block}\n\n{message}"` using `build_memory_block(root, include_decisions=False)`.
- Wire: after `skills = ...` (`:2060`), add `message = compose_chat_message(mobile_session_key, message, fast)`.
- Tests: injects for `company-ceo-chat` (non-fast); skips fast + `hermes-mobile-briefing`; passthrough when no vault; `include_decisions=False` omits decisions.

### Task 2 (2a): Proactive daily briefing push
**Files:** Modify `Scripts/hermes_mobile_relay.py` (add `_BRIEFING_PUSH`, `build_briefing_digest`, `briefing_due`, `maybe_push_briefing`; wire in `company_heartbeat_loop` after `run_schedules()` `:1693`). Test: same test class.

- `build_briefing_digest(state) -> str`: from real state — count active initiatives (stage not in shipped/killed/archived), gates (stage startswith "gate"), latest meeting topic; join with " · "; empty → "Quiet — nothing needs you right now."
- `briefing_due(config, now, last_date) -> bool`: False if `briefing_push_enabled` False; else True iff `localtime(now).tm_hour >= briefing_hour(8)` and `last_date != today`.
- `maybe_push_briefing(state, now=None) -> bool`: if not due → False; stamp `_BRIEFING_PUSH["date"]=today` (once/day regardless of send outcome); `send_push("Morning briefing", digest, "BOARDROOM_BRIEFING", {"kind":"briefing"})`.
- Wire: `maybe_push_briefing(state)` after `run_schedules()` in the heartbeat.
- Tests: digest content (active/gates/last); empty→quiet; `briefing_due` fires 9am/not-before-8/not-twice/disabled; `maybe_push_briefing` sends once, body carries digest.

### Task 3 (2b): De-fake BriefingCenter (Swift — owner rebuilds)
**Files:** Modify `HermesMobile/Sources/HermesMobile/Services/BriefingCenter.swift:76`.
- Replace the "invent plausible, business-like status" instruction with: summarize only REAL signals (today's meetings, overnight replies); if a department has no signal, omit it; if nothing is happening, say so plainly. NO invented status.
- Compile-check only on my side (per standing rule only the owner builds/runs); owner rebuilds to activate.
- Optional (bundled): register a `BOARDROOM_BRIEFING` `UNNotificationCategory` in `CompanyStore.swift` `registerCategories()` so the push shows as a branded briefing; without it the push still shows as a plain alert.

## Verification
- `pytest Scripts/test_hermes_mobile_relay.py Scripts/test_hermes_company.py` green.
- e2e: real-module run showing chat injection + a sample digest.
- Swift: syntax/type sanity; owner rebuilds.
