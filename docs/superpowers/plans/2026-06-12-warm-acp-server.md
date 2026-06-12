# Warm ACP Server (chat speed fix) Implementation Plan

> Executed inline immediately after writing; interface-level plan, full code in commits.

**Goal:** Chats and voice calls answer in ~2–4s instead of ~15–30s by routing relay traffic through a persistent warm `hermes acp` process instead of cold-booting the CLI per message.

**Measured basis (spike, 2026-06-12):** warm ACP turn = 3.0s total / 2.2s first token. Cold CLI = 15–30s. One-time warm-up ~40s per process/session, paid at relay start or first message of a new conversation.

**Architecture:** New `Scripts/hermes_acp_client.py` — `AcpClient` owns one `hermes acp` subprocess: JSON-RPC over stdio (initialize → session/new per conversation key → session/prompt streaming `agent_message_chunk`s). Reader thread feeds a queue; auto-replies to `session/request_permission` (allow). Conversation map (mobile session key → ACP sessionId) is in-memory; process death → restart + transparent retry. Relay's `stream_chat` tries the warm path first (unless `fast`-incompatible), falls back to the cold CLI subprocess on any ACP failure. Company engine + memos keep the cold path (background work, latency-tolerant).

**Verification:** unit tests with a scripted fake subprocess (framing, session reuse, chunk streaming, permission auto-allow, crash recovery); live end-to-end timing through the relay: turn 1 (warm-up) then turn 2 expected ≤5s.

### Task 1: AcpClient with fake-subprocess tests
- Create `Scripts/hermes_acp_client.py`, `Scripts/test_hermes_acp_client.py` (unittest, importlib pattern).

### Task 2: Relay integration + fallback
- Modify `Scripts/hermes_mobile_relay.py`: lazy global `AcpClient`; `stream_chat` warm-first with cold fallback; `/health` reports `"warm": true/false`.

### Task 3: Live verification + commit
- Restart relay; time two consecutive `/chat/stream` turns (same session) — expect turn 2 ≤5s; voice path inherits automatically. Commit.
