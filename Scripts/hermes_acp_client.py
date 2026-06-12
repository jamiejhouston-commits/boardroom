#!/usr/bin/env python3
"""Warm Hermes client over ACP (Agent Client Protocol).

Keeps ONE persistent `hermes acp` subprocess and routes chat turns through it:
the agent's tools/skills/memory load once, so a turn costs ~3s instead of the
15-30s per-message cold start of `hermes chat -q`.

JSON-RPC 2.0 over stdio. Flow: initialize → session/new (one per conversation
key) → session/prompt, streaming `agent_message_chunk` updates. Incoming
`session/request_permission` requests are auto-allowed (same trust model as
the non-interactive CLI on the owner's own machine).

Thread-safe for one caller at a time per client (a lock serializes turns).
On process death the next prompt raises WarmUnavailable — the relay falls
back to the cold CLI and a fresh warm process is started for the turn after.
"""

from __future__ import annotations

import json
import subprocess
import threading
import time
from typing import Callable, Iterator


class WarmUnavailable(Exception):
    """The warm process is dead/unusable — caller should use the cold path."""


def _default_spawn():
    return subprocess.Popen(
        ["hermes", "acp", "--accept-hooks"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )


class AcpClient:
    def __init__(self, spawn: Callable = _default_spawn, turn_timeout: float = 240.0) -> None:
        self._spawn = spawn
        self._turn_timeout = turn_timeout
        self._lock = threading.Lock()
        self._process = None
        self._initialized = False
        self._sessions: dict[str, str] = {}   # conversation key → ACP sessionId
        self._next_id = 0

    # ── public API ────────────────────────────────────────────────────────

    def prompt(self, conversation_key: str, text: str) -> Iterator[str]:
        """Send one turn; yield text chunks as the agent streams them.
        Raises WarmUnavailable if the warm process can't serve the turn."""
        with self._lock:
            self._ensure_ready()
            session_id = self._ensure_session(conversation_key)
            request_id = self._send("session/prompt", {
                "sessionId": session_id,
                "prompt": [{"type": "text", "text": text}],
            })
            yield from self._pump_until_response(request_id)

    def warm(self) -> bool:
        """True if the warm process is alive and handshaken."""
        return self._process is not None and self._process.poll() is None and self._initialized

    def shutdown(self) -> None:
        with self._lock:
            if self._process is not None:
                try:
                    self._process.terminate()
                except Exception:
                    pass
            self._process = None
            self._initialized = False
            self._sessions.clear()

    # ── internals (call with lock held) ───────────────────────────────────

    def _ensure_ready(self) -> None:
        if self._process is not None and self._process.poll() is not None:
            # Died since last turn: drop it so the relay can cold-fallback now
            # and we come back warm on the next call.
            self._process = None
            self._initialized = False
            self._sessions.clear()
            raise WarmUnavailable("warm hermes process died")
        if self._process is None:
            self._process = self._spawn()
            self._initialized = False
            self._sessions.clear()
        if not self._initialized:
            request_id = self._send("initialize", {
                "protocolVersion": 1,
                "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}},
            })
            for _ in self._pump_until_response(request_id):
                pass
            self._initialized = True

    def _ensure_session(self, conversation_key: str) -> str:
        session_id = self._sessions.get(conversation_key)
        if session_id:
            return session_id
        request_id = self._send("session/new", {"cwd": "/tmp", "mcpServers": []})
        result = {}
        for _ in self._pump_until_response(request_id, capture_result=result):
            pass
        session_id = result.get("result", {}).get("sessionId")
        if not session_id:
            raise WarmUnavailable("session/new returned no sessionId")
        self._sessions[conversation_key] = session_id
        return session_id

    def _send(self, method: str, params: dict) -> int:
        self._next_id += 1
        message = {"jsonrpc": "2.0", "id": self._next_id, "method": method, "params": params}
        try:
            self._process.stdin.write(json.dumps(message) + "\n")
            self._process.stdin.flush()
        except (BrokenPipeError, OSError, AttributeError) as error:
            self._mark_dead()
            raise WarmUnavailable(f"write failed: {error}")
        return self._next_id

    def _reply(self, request_id, result: dict) -> None:
        try:
            self._process.stdin.write(json.dumps(
                {"jsonrpc": "2.0", "id": request_id, "result": result}) + "\n")
            self._process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            self._mark_dead()
            raise WarmUnavailable(f"write failed: {error}")

    def _pump_until_response(self, request_id: int, capture_result: dict | None = None) -> Iterator[str]:
        """Read messages until the response for request_id arrives. Yields
        agent text chunks; auto-allows permission requests."""
        deadline = time.monotonic() + self._turn_timeout
        while True:
            if time.monotonic() > deadline:
                self._mark_dead()
                raise WarmUnavailable("turn timed out")
            try:
                line = self._process.stdout.readline()
            except (OSError, AttributeError) as error:
                self._mark_dead()
                raise WarmUnavailable(f"read failed: {error}")
            if not line:
                if self._process is None or self._process.poll() is not None:
                    self._mark_dead()
                    raise WarmUnavailable("warm hermes process closed its pipe")
                continue
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue

            method = message.get("method")
            if method == "session/update":
                update = message.get("params", {}).get("update", {})
                if update.get("sessionUpdate") == "agent_message_chunk":
                    content = update.get("content", {})
                    if isinstance(content, dict) and content.get("type") == "text":
                        yield content.get("text", "")
                continue
            if method == "session/request_permission":
                self._auto_allow(message)
                continue
            if message.get("id") == request_id and ("result" in message or "error" in message):
                if "error" in message:
                    raise WarmUnavailable(f"agent error: {message['error']}")
                if capture_result is not None:
                    capture_result["result"] = message.get("result", {})
                return

    def _auto_allow(self, message: dict) -> None:
        options = message.get("params", {}).get("options", []) or []
        choice = None
        for option in options:
            if "allow" in str(option.get("kind", "")) or "allow" in str(option.get("optionId", "")):
                choice = option.get("optionId")
                break
        if choice is None and options:
            choice = options[0].get("optionId")
        self._reply(message.get("id"),
                    {"outcome": {"outcome": "selected", "optionId": choice}})

    def _mark_dead(self) -> None:
        if self._process is not None:
            try:
                self._process.kill()
            except Exception:
                pass
        self._process = None
        self._initialized = False
        self._sessions.clear()
