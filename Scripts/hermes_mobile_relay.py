#!/usr/bin/env python3
"""Small development relay for Hermes Mobile.

Run this on the Mac that already has Hermes installed:

    python3 Scripts/hermes_mobile_relay.py

The iPhone app connects to this relay over your local Wi-Fi and the relay calls
the real Hermes CLI. This is intentionally tiny so the eventual product version
can replace it with an official `hermes mobile start` command.
"""

from __future__ import annotations

import argparse
import base64
import importlib.util
import io
import json
import os
import queue
import secrets
import shutil
import socket
import signal
import subprocess
import tempfile
import sys
import re
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

_COMPANY_SPEC = importlib.util.spec_from_file_location(
    "hermes_company", Path(__file__).with_name("hermes_company.py"))
company_module = importlib.util.module_from_spec(_COMPANY_SPEC)
assert _COMPANY_SPEC.loader is not None
_COMPANY_SPEC.loader.exec_module(company_module)

_GAMES_SPEC = importlib.util.spec_from_file_location(
    "hermes_games_studio", Path(__file__).with_name("hermes_games_studio.py"))
games_module = importlib.util.module_from_spec(_GAMES_SPEC)
assert _GAMES_SPEC.loader is not None
_GAMES_SPEC.loader.exec_module(games_module)

_ACP_SPEC = importlib.util.spec_from_file_location(
    "hermes_acp_client", Path(__file__).with_name("hermes_acp_client.py"))
acp_module = importlib.util.module_from_spec(_ACP_SPEC)
assert _ACP_SPEC.loader is not None
_ACP_SPEC.loader.exec_module(acp_module)

# One warm Hermes for all interactive chat — turns cost ~3s instead of the
# 15-30s per-message cold start. Cold CLI remains the automatic fallback.
WARM_CLIENT = acp_module.AcpClient()


def prewarm_hermes() -> None:
    """Pay the agent warm-up at relay start, not on the owner's first message.
    Pre-warms the leadership sessions the app talks to (default:company-<role>)
    so even the FIRST chat with the CEO/CFO/etc. answers in ~3s, not ~18s."""
    # Process warm-up first.
    try:
        for _ in WARM_CLIENT.prompt("relay-prewarm", "Reply with exactly: OK"):
            pass
        print("Warm Hermes: READY (turns now ~3s)", flush=True)
    except Exception as error:  # noqa: BLE001 — cold path still works
        print(f"Warm Hermes unavailable, using cold CLI: {error}", flush=True)
        return
    # Then warm each leadership CHAT key the app uses — these are decoupled from
    # the autonomous engine's "company-<role>" sessions (see the chat handler),
    # so the owner's chats never collide with the running company.
    for role in ("ceo", "cfo", "cto", "marketing", "research"):
        try:
            for _ in WARM_CLIENT.prompt(f"default:company-{role}-chat", "Acknowledge with: ready"):
                pass
        except Exception:  # noqa: BLE001 — best-effort; first real chat warms it otherwise
            break
    print("Warm Hermes: leadership sessions pre-warmed (first chat ~3s)", flush=True)

def warm_keeper_loop() -> None:
    """Bring the warm agent BACK whenever it dies. Before this loop, one bad
    turn (or a slow boot at relay start — a 240s prewarm timeout under heavy
    company-build load) marked the warm client dead FOREVER: every chat fell
    to the cold CLI (15-30s+, worse under load, capped agent turns) until the
    next relay restart. That was the core of 'the agents never reply'."""
    while True:
        time.sleep(60)
        try:
            if WARM_CLIENT.warm():
                continue
            for _ in WARM_CLIENT.prompt("relay-prewarm", "Reply with exactly: OK"):
                pass
            print("Warm Hermes: RECOVERED (turns ~3s again)", flush=True)
        except Exception as error:  # noqa: BLE001 — keep trying every minute
            print(f"Warm Hermes: rewarm failed, retrying in 60s: {error}", flush=True)


COMPANY_STATE_PATH = Path.home() / ".hermes" / "mobile-company.json"
# Deliverables go somewhere the owner can SEE — Finder, not a dotfolder.
COMPANY_ARTIFACTS_ROOT = Path.home() / "Documents" / "Boardroom"
# Kanban tasks share one workspace so a list of jobs accumulates on one codebase.
COMPANY_TASKS_WORKSPACE = COMPANY_ARTIFACTS_ROOT / "task-list-workspace"
# The Company Vault — an Obsidian-readable folder of linked notes Lena files
# (meeting minutes + decisions). Open this folder as a vault in Obsidian.
COMPANY_VAULT_ROOT = Path.home() / "Documents" / "Boardroom-Vault"
COMPANY_LOCK = threading.Lock()

# Games Studio — the first Boardroom division. Its own state file + workspace,
# a sibling of the company engine (see hermes_games_studio.py).
GAMES_STATE_PATH = Path.home() / ".hermes" / "mobile-games-studio.json"
GAMES_ARTIFACTS_ROOT = COMPANY_ARTIFACTS_ROOT / "games-studio"
GAMES_LOCK = threading.Lock()
_CONFIG_LOCK = threading.Lock()   # serializes RelayConfigStore writes

# Free local neural TTS (Piper) — real human voices for the agents at $0 cost.
PIPER_BIN = Path.home() / ".hermes" / "piper-venv" / "bin" / "piper"
PIPER_VOICE_DIR = Path.home() / ".hermes" / "piper-voices"


def piper_available() -> bool:
    return PIPER_BIN.exists() and PIPER_VOICE_DIR.is_dir() and \
        any(PIPER_VOICE_DIR.glob("*.onnx"))


def available_voices() -> list[str]:
    return sorted(p.stem for p in PIPER_VOICE_DIR.glob("*.onnx")) if PIPER_VOICE_DIR.is_dir() else []


def synthesize_tts(text: str, voice: str) -> bytes | None:
    """Render `text` to WAV bytes with the named Piper voice. None on failure
    (the app then falls back to the on-device Apple voice)."""
    if not piper_available() or not text.strip():
        return None
    # Validate against installed models — no path traversal from the voice name.
    model = PIPER_VOICE_DIR / f"{Path(voice).name}.onnx"
    if not model.exists():
        installed = available_voices()
        if not installed:
            return None
        model = PIPER_VOICE_DIR / f"{installed[0]}.onnx"
    out = Path(tempfile.gettempdir()) / f"boardroom-tts-{secrets.token_hex(6)}.wav"
    try:
        result = subprocess.run(
            [str(PIPER_BIN), "-m", str(model), "-f", str(out)],
            input=text[:1200], text=True, capture_output=True, timeout=60, check=False)
        if result.returncode != 0 or not out.exists():
            return None
        return out.read_bytes()
    except Exception:  # noqa: BLE001 — fallback covers any failure
        return None
    finally:
        try:
            out.unlink(missing_ok=True)
        except OSError:
            pass


# ── ElevenLabs TTS + the VOICE-COST POLICY. ElevenLabs is NEVER the default:
#    every internal voice (owner-agent calls, meetings, office chatter, status
#    updates) uses the FREE tier — local Piper, with the on-device Apple voice
#    behind it. ElevenLabs serves ONLY requests that explicitly declare
#    tier="premium" (external, revenue-facing: sales calls, customer calls,
#    demos, marketing assets), and only within a character budget; over budget
#    it silently falls back to the free voice. ~/.hermes/elevenlabs.json:
#    {"api_key": "...", "model_id": "eleven_turbo_v2_5", "voice_map": {...},
#     "daily_char_budget": 10000, "weekly_char_budget": 40000}.

ELEVENLABS_CONFIG_PATH = Path.home() / ".hermes" / "elevenlabs.json"

# The app keeps sending its Piper voice names — the relay maps each one to a
# cast ElevenLabs voice, so no app rebuild is needed for the voice upgrade.
ELEVENLABS_VOICE_MAP = {
    "en_US-ryan-medium": "CwhRBWXzGAHq8TQ4Fs17",        # Roger — resonant, laid-back CEO
    "en_US-joe-medium": "bIHbv24MWmeRgasZH58o",         # Will — relaxed optimist
    "en_GB-alan-medium": "TX3LPaxmHKxFdv7VOQHJ",        # Liam — energetic
    "en_US-amy-medium": "cgSgspJ2msm6clMCkdW9",         # Jessica — playful, bright
    "en_US-kathleen-low": "XrExE9yKIg1WjnnlVkGX",       # Matilda — knowledgeable, professional
    "en_GB-jenny_dioco-medium": "EXAVITQu4vr4xnSDxMaL", # Sarah — mature, reassuring (Lena)
    "en_US-lessac-medium": "SAz9YHcvj6GT2YYXdXww",      # River — relaxed, informative
}
ELEVENLABS_DEFAULT_VOICE = "CwhRBWXzGAHq8TQ4Fs17"       # Roger


def elevenlabs_config() -> dict | None:
    try:
        data = json.loads(ELEVENLABS_CONFIG_PATH.read_text())
        if data.get("api_key"):
            return data
    except (OSError, json.JSONDecodeError, ValueError):
        pass
    return None


def elevenlabs_voice_id(voice: str, config: dict | None = None) -> str:
    """Map an app voice name (Piper model) to an ElevenLabs voice id. The
    owner can override any assignment via voice_map in elevenlabs.json;
    a raw ElevenLabs voice id (20-char alnum) passes straight through."""
    overrides = (config or {}).get("voice_map") or {}
    if voice in overrides:
        return str(overrides[voice])
    if voice in ELEVENLABS_VOICE_MAP:
        return ELEVENLABS_VOICE_MAP[voice]
    if re.fullmatch(r"[A-Za-z0-9]{16,32}", voice or ""):
        return voice
    return ELEVENLABS_DEFAULT_VOICE


def synthesize_elevenlabs(text: str, voice: str) -> bytes | None:
    """Natural neural speech via the owner's ElevenLabs account. None on any
    failure (no key, quota, network) — Piper/Apple fallbacks take over."""
    config = elevenlabs_config()
    if config is None or not text.strip():
        return None
    voice_id = elevenlabs_voice_id(voice, config)
    body = json.dumps({
        "text": text[:1200],
        "model_id": config.get("model_id", "eleven_turbo_v2_5"),
        "voice_settings": {"stability": 0.5, "similarity_boost": 0.75},
    }).encode()
    import urllib.request
    request = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128",
        data=body, method="POST",
        headers={"xi-api-key": config["api_key"],
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            audio = response.read()
            return audio if audio else None
    except Exception as error:  # noqa: BLE001 — fall back to Piper
        print(f"tts - elevenlabs failed (falling back to Piper): {error}", flush=True)
        return None


# Character-budget ledger for the paid voice, with daily/weekly rollover.
ELEVENLABS_USAGE_PATH = Path.home() / ".hermes" / "elevenlabs-usage.json"
_VOICE_USAGE_LOCK = threading.Lock()
DEFAULT_DAILY_CHAR_BUDGET = 10_000
DEFAULT_WEEKLY_CHAR_BUDGET = 40_000


def load_voice_usage(now: float | None = None) -> dict:
    moment = time.localtime(now if now is not None else time.time())
    day = time.strftime("%Y-%m-%d", moment)
    week = time.strftime("%G-W%V", moment)   # ISO week — resets Monday
    try:
        data = json.loads(ELEVENLABS_USAGE_PATH.read_text())
        if not isinstance(data, dict):
            data = {}
    except (OSError, json.JSONDecodeError, ValueError):
        data = {}
    if data.get("day") != day:
        data["day"], data["chars_today"] = day, 0
    if data.get("week") != week:
        data["week"], data["chars_week"] = week, 0
    data.setdefault("chars_today", 0)
    data.setdefault("chars_week", 0)
    return data


def charge_voice_usage(chars: int, now: float | None = None) -> None:
    with _VOICE_USAGE_LOCK:
        data = load_voice_usage(now)
        data["chars_today"] += chars
        data["chars_week"] += chars
        ELEVENLABS_USAGE_PATH.parent.mkdir(parents=True, exist_ok=True)
        ELEVENLABS_USAGE_PATH.write_text(json.dumps(data))


def premium_voice_allowed(text: str, config: dict, now: float | None = None) -> bool:
    """Would speaking `text` on the paid voice stay inside the owner's
    daily AND weekly character budgets?"""
    usage = load_voice_usage(now)
    daily = int(config.get("daily_char_budget", DEFAULT_DAILY_CHAR_BUDGET))
    weekly = int(config.get("weekly_char_budget", DEFAULT_WEEKLY_CHAR_BUDGET))
    chars = len(text)
    return (usage["chars_today"] + chars <= daily
            and usage["chars_week"] + chars <= weekly)


def synthesize_speech(text: str, voice: str,
                      tier: str = "internal") -> tuple[bytes, str, str] | None:
    """(audio bytes, MIME, engine) under the VOICE-COST POLICY:
    • tier "internal" (the default — calls, meetings, office chatter) NEVER
      touches ElevenLabs; it speaks on free local Piper.
    • tier "premium" (external, revenue-facing only) may use ElevenLabs —
      if a key exists AND the character budget allows — else it falls back
      to the free voice rather than overspending.
    None → the app uses the free on-device Apple voice."""
    if tier == "premium":
        config = elevenlabs_config()
        if config is not None and premium_voice_allowed(text, config):
            audio = synthesize_elevenlabs(text, voice)
            if audio:
                charge_voice_usage(len(text))
                return audio, "audio/mpeg", "elevenlabs"
    audio = synthesize_tts(text, voice)
    if audio:
        return audio, "audio/wav", "piper"
    return None


CONFIG_PATH = Path.home() / ".hermes" / "mobile-relay.json"
REEXEC_ENV = "HERMES_MOBILE_RELAY_REEXEC"
SESSION_ID_PATTERN = re.compile(r"\b\d{8}_\d{6}_[A-Za-z0-9]+\b")


def can_import_qrcode() -> bool:
    try:
        import qrcode  # type: ignore  # noqa: F401
        return True
    except Exception:
        return False


def maybe_reexec_with_hermes_python() -> None:
    if os.environ.get(REEXEC_ENV) or can_import_qrcode():
        return

    candidate = Path.home() / ".hermes" / "hermes-agent" / "venv" / "bin" / "python"
    if not candidate.exists():
        return

    probe = subprocess.run(
        [str(candidate), "-c", "import qrcode"],
        text=True,
        capture_output=True,
        check=False,
    )
    if probe.returncode != 0:
        return

    env = os.environ.copy()
    env[REEXEC_ENV] = "1"
    os.execve(str(candidate), [str(candidate), *sys.argv], env)


def local_ip() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


class RelayConfigStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    def token(self, reset: bool = False) -> str:
        data = self.load()
        token = data.get("token")
        if isinstance(token, str) and token and not reset:
            return token

        token = secrets.token_urlsafe(32)
        data["token"] = token
        self.save(data)
        return token

    def session_id(self, profile: str, mobile_session_key: str) -> str | None:
        sessions = self.load().get("sessions", {})
        if not isinstance(sessions, dict):
            return None
        value = sessions.get(self.session_key(profile, mobile_session_key))
        return value if isinstance(value, str) and value else None

    def save_session(self, profile: str, mobile_session_key: str, session_id: str) -> None:
        data = self.load()
        sessions = data.get("sessions", {})
        if not isinstance(sessions, dict):
            sessions = {}
        sessions[self.session_key(profile, mobile_session_key)] = session_id
        data["sessions"] = sessions
        self.save(data)

    def load(self) -> dict[str, Any]:
        if self.path.exists():
            try:
                data = json.loads(self.path.read_text())
                if isinstance(data, dict):
                    return data
            except json.JSONDecodeError:
                pass
        return {}

    def save(self, data: dict[str, Any]) -> None:
        # Atomic + serialized: ThreadingHTTPServer + the heartbeat can save
        # concurrently; a torn write would lose the token and all session ids.
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with _CONFIG_LOCK:
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(data, indent=2))
            tmp.chmod(0o600)
            os.replace(tmp, self.path)

    @staticmethod
    def session_key(profile: str, mobile_session_key: str) -> str:
        return f"{profile}:{mobile_session_key}"


def load_or_create_token(reset: bool) -> str:
    return RelayConfigStore(CONFIG_PATH).token(reset)


def latest_session_id(profile: str, source: str = "mobile") -> str | None:
    command = ["hermes"]
    if profile != "default":
        command.extend(["-p", profile])
    command.extend(["sessions", "list", "--source", source, "--limit", "1"])

    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        return None
    return extract_session_id(result.stdout)


def extract_session_id(output: str) -> str | None:
    session_pattern = r"\d{8}_\d{6}_[A-Za-z0-9]+"
    resume_match = re.search(r"--resume\s+(" + session_pattern + r")", output)
    if resume_match:
        return resume_match.group(1)

    session_match = re.search(r"\bSession:\s*(" + session_pattern + r")", output)
    if session_match:
        return session_match.group(1)

    match = SESSION_ID_PATTERN.search(output)
    return match.group(0) if match else None


def is_metadata_line(line: str) -> bool:
    stripped = line.strip()
    return (
        stripped == "Resume this session with:"
        or stripped.startswith("hermes --resume ")
        or stripped.startswith("hermes chat --resume ")
        or stripped.startswith("Session:")
        or stripped.startswith("Title:")
        or stripped.startswith("Messages:")
        or stripped.startswith("Tokens:")
    )


def is_status_line(line: str) -> bool:
    """Leading CLI status lines to skip without ending the reply."""
    stripped = line.strip()
    if not stripped:
        return False
    low = stripped.lower()
    return (
        "resumed session" in low
        or "session_id:" in low
        or low.startswith("starting session")
        or low.startswith("continuing session")
        # CLI iteration-limit warnings must never reach (or be spoken by) the app.
        or stripped.startswith("⚠")
        or low.startswith("warning:")
    )


def clean_reply(output: str) -> str:
    reply_lines: list[str] = []
    for line in output.splitlines():
        if is_metadata_line(line):
            break
        if is_status_line(line):
            continue
        reply_lines.append(line)
    return "\n".join(reply_lines).strip()


def discover_profiles() -> list[str]:
    profiles_dir = Path.home() / ".hermes" / "profiles"
    profiles = ["main", "default"]
    if profiles_dir.exists():
        profiles.extend(sorted(path.name for path in profiles_dir.iterdir() if path.is_dir()))
    return profiles


def normalize_profile(profile: str) -> str:
    value = profile.strip() or "main"
    return "default" if value == "main" else value


def session_name_for(profile: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", profile).strip("-") or "default"
    return f"hermes-mobile-{safe}"


def chat_command(message: str, profile: str, resume_session_id: str | None,
                 fast: bool = False, skills: str = "") -> list[str]:
    command = ["hermes"]
    if profile != "default":
        command.extend(["-p", profile])
    command.extend([
        "chat",
        "-Q",
        "--source",
        "mobile",
    ])
    if fast:
        # Voice calls: cap the agent loop so a turn can't wander into long
        # tool chains. 2 (not 1) — at 1 the CLI truncates with ⚠️ warnings.
        command.extend(["--max-turns", "2"])
    if skills:
        command.extend(["-s", skills])   # per-agent skill loadout
    if resume_session_id:
        command.extend(["--resume", resume_session_id])
    command.extend(["-q", message])
    return command


def company_chat_command(message: str, role: str, resume_session_id: str | None) -> list[str]:
    # `nice`: the autonomous company runs at LOW CPU priority so its long
    # builds can never starve the owner's live chat/voice. macOS honors this.
    command = ["nice", "-n", "15", "hermes", "chat", "-Q", "--source", "mobile"]
    if resume_session_id:
        command.extend(["--resume", resume_session_id])
    command.extend(["-q", message])
    return command


def kill_tree(proc: subprocess.Popen) -> None:
    """SIGKILL a Popen AND its whole process group, so a killed Hermes turn
    takes its model-backend/tool grandchildren with it instead of orphaning
    them. Requires the proc to have been started with start_new_session=True."""
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            proc.kill()
        except OSError:
            pass


def run_killable(command: list[str], timeout: int) -> subprocess.CompletedProcess:
    """Like subprocess.run(timeout=...), but the child runs in its OWN process
    group, so a timeout kills the ENTIRE tree — the model backend, tool
    subprocesses, everything it spawned — not just the direct child.

    THE bug behind the load-540 death spiral: subprocess.run's timeout SIGKILLs
    only the parent. Every grandchild (codex model backend, tool procs) then
    reparents to launchd and keeps running forever. Across dozens of killed
    30-min build turns they pile up into hundreds of runaway processes that
    thrash the Mac, which starves the owner's live chat until it times out.
    Killing the whole group on timeout stops the leak at the source.
    (Simulators are spawned by CoreSimulatorService, not as children, so they
    are handled separately by cleanup_zombie_simulators.)"""
    proc = subprocess.Popen(
        command, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True,   # own session/process group → killpg reaches all descendants
    )
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
        return subprocess.CompletedProcess(command, proc.returncode, stdout, stderr)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            proc.kill()
        try:
            proc.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            pass
        raise


def company_turn_timeout() -> int:
    """Per-turn ceiling for company agent turns, in seconds. 30 min default —
    a real build turn (create files, run tools, QA fixes) routinely needs
    longer than 600s; at 600s the builder was killed mid-build almost every
    time — the #1 reason initiatives died without ever shipping. Heavy QA
    turns (watch-sim screenshots on an Intel Mac) can need more: the owner can
    raise it via company config {"turn_timeout_minutes": 45} without code."""
    try:
        config = json.loads(COMPANY_STATE_PATH.read_text()).get("config", {})
        minutes = int(config.get("turn_timeout_minutes", 30))
    except Exception:  # noqa: BLE001 — a broken config must not stop turns
        minutes = 30
    return max(10, min(minutes, 120)) * 60


def company_cli_runner(role: str, prompt: str) -> str:
    """runner(role, prompt) for the company engine: one Hermes CLI call per
    turn, with a persistent session per role so agents keep their memory."""
    prompt = compose_company_prompt(role, prompt)   # inject shared brain (gated to deliberative roles)
    store = RelayConfigStore(CONFIG_PATH)
    session_key = f"company-{role}"
    resume = store.session_id("default", session_key)
    timeout = company_turn_timeout()
    try:
        result = run_killable(
            # Work already written to disk is picked up and extended on the
            # next tick, so a turn that needs more than one pass still
            # converges instead of being marked failed. On timeout the WHOLE
            # tree is killed (run_killable) so nothing orphans.
            company_chat_command(prompt, role, resume),
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        # str(TimeoutExpired) embeds the full 4KB role prompt — a wall of
        # soul-text in the app instead of what actually went wrong. Surface
        # the one line the owner needs.
        try:
            load1 = os.getloadavg()[0]
        except OSError:
            load1 = 0.0
        raise RuntimeError(
            f"{role} turn timed out after {timeout // 60} min (Mac load {load1:.0f}) — "
            "progress already on disk resumes next tick"
        ) from error
    output = (result.stdout or "") + "\n" + (result.stderr or "")
    session_id = extract_session_id(output) or latest_session_id("default")
    if session_id:
        store.save_session("default", session_key, session_id)
    if result.returncode != 0:
        raise RuntimeError(f"hermes exited {result.returncode} for role {role}")
    return clean_reply(result.stdout)


def games_cli_runner(role: str, prompt: str) -> str:
    """runner(role, prompt) for the Games Studio engine — one Hermes CLI call per
    turn, with a persistent session per studio role (games-<role>) so the Game
    Designer, playtesters, and distributor keep their own memory, cleanly
    separated from the company board's sessions. The games engine already builds
    the full role prompt (culture + soul), so no company brain is injected."""
    store = RelayConfigStore(CONFIG_PATH)
    session_key = f"games-{role}"
    resume = store.session_id("default", session_key)
    timeout = company_turn_timeout()
    try:
        result = run_killable(
            company_chat_command(prompt, role, resume),
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(
            f"games {role} turn timed out after {timeout // 60} min — retries next tick"
        ) from error
    output = (result.stdout or "") + "\n" + (result.stderr or "")
    session_id = extract_session_id(output) or latest_session_id("default")
    if session_id:
        store.save_session("default", session_key, session_id)
    if result.returncode != 0:
        raise RuntimeError(f"hermes exited {result.returncode} for games role {role}")
    return clean_reply(result.stdout)


def games_heartbeat() -> None:
    """One Games Studio pulse, sharing the company's working hours + overload
    guard so studio turns never buy timeouts. No-op unless the studio is enabled
    and has a game in flight (the shipped flagship needs no turns)."""
    with GAMES_LOCK:
        state = games_module.StudioStore(GAMES_STATE_PATH).load()
    if not state.get("enabled") or not games_module.working(state):
        return
    # Respect the same quiet hours + machine-load rules as the company engine.
    try:
        config = company_module.CompanyStore(COMPANY_STATE_PATH).load().get("config", {})
    except Exception:  # noqa: BLE001
        config = {}
    hour = time.localtime().tm_hour
    if company_module.is_quiet(hour, config.get("quiet_start", 22), config.get("quiet_end", 7)):
        return
    if company_module.machine_overloaded(config.get("max_load_per_core", 2.5)):
        return
    events = games_module.tick(state, games_cli_runner, GAMES_ARTIFACTS_ROOT)
    if events:
        with GAMES_LOCK:
            games_module.StudioStore(GAMES_STATE_PATH).save(state)
        for event in events:
            print(f"games - {event}", flush=True)


# ── Absolute binary resolution — ship must be PATH-INDEPENDENT. When the relay
#    is launched from a stripped-PATH context (launchd / caffeinate always-on,
#    see Scripts/install_mac_alwayson.sh), bare "gh"/"git" are not found and
#    ship dies. Real failure recorded in company state:
#    "Ship failed: [Errno 2] No such file or directory: gh". We search the
#    process PATH plus the usual install dirs so ship works regardless of how
#    the relay was launched.
_BIN_CACHE: dict[str, str] = {}
_BIN_FALLBACK_DIRS = [
    "/usr/local/bin", "/opt/homebrew/bin",
    str(Path.home() / ".local" / "bin"), str(Path.home() / ".npm-global" / "bin"),
    "/usr/bin", "/bin", "/usr/sbin", "/sbin",
]


def _resolve_bin(name: str) -> str:
    """Absolute path to a required binary, PATH-independent. Searches the
    process PATH augmented with the usual install dirs, so ship works even
    under launchd/caffeinate where PATH is stripped. Cached per process.
    Raises a clear RuntimeError naming the binary if it can't be found."""
    cached = _BIN_CACHE.get(name)
    if cached:
        return cached
    search_path = os.pathsep.join(
        [p for p in os.environ.get("PATH", "").split(os.pathsep) if p]
        + _BIN_FALLBACK_DIRS)
    found = shutil.which(name, path=search_path)
    if not found:
        raise RuntimeError(
            f"required binary '{name}' not found on PATH or fallback dirs "
            f"({', '.join(_BIN_FALLBACK_DIRS)}); install it or add its directory "
            f"to PATH (e.g. `brew install {name}`)")
    _BIN_CACHE[name] = found
    return found


def _remote_https_url(outdir: Path) -> str | None:
    """https URL of the outdir's origin remote, normalized (no trailing slash
    or .git). Lets a re-ship recover the repo URL after pushing to an existing
    repo, where `gh repo create` never emits a fresh URL to scrape."""
    try:
        result = subprocess.run(
            [_resolve_bin("git"), "-C", str(outdir), "remote", "get-url", "origin"],
            text=True, capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError, RuntimeError):
        return None
    if result.returncode != 0:
        return None
    remote = (result.stdout or "").strip()
    if not remote:
        return None
    # Normalize SSH form git@github.com:owner/repo(.git) → https URL.
    match = re.match(r"git@([^:]+):(.+)", remote)
    if match:
        remote = f"https://{match.group(1)}/{match.group(2)}"
    return remote.rstrip("/").removesuffix(".git")


def ship_commands(outdir: Path, slug: str) -> list[list[str]]:
    """Commands that publish an initiative's deliverables as a PRIVATE repo
    on the owner's GitHub account. Private by design — the owner reviews and
    flips it public themselves if and when they choose. git/gh are resolved to
    ABSOLUTE paths so ship is PATH-independent (launchd/caffeinate-safe); the
    outdir is passed as a POSIX path."""
    git = _resolve_bin("git")
    gh = _resolve_bin("gh")
    outdir_arg = outdir.as_posix()
    return [
        [git, "-C", outdir_arg, "init", "-b", "main"],
        [git, "-C", outdir_arg, "add", "-A"],
        [git, "-C", outdir_arg,
         "-c", "user.name=Boardroom", "-c", "user.email=boardroom@localhost",
         "commit", "-m", f"Ship: {slug} — built by the Boardroom company", "--allow-empty"],
        [gh, "repo", "create", slug, "--private",
         "--source", outdir_arg, "--push"],
    ]


def ship_initiative(init: dict) -> str | None:
    """Run the ship pipeline; returns the private repo URL or None.
    Raises with a readable message if git/gh fail, so the caller can surface
    it instead of handing the owner a link to an empty repo."""
    slug = company_module.initiative_dirname(init)
    outdir = COMPANY_ARTIFACTS_ROOT / slug
    if not outdir.is_dir() or not any(outdir.rglob("*")):
        raise RuntimeError("nothing to ship — no deliverables on disk")
    url = None
    for command in ship_commands(outdir, slug):
        result = subprocess.run(command, text=True, capture_output=True,
                                timeout=120, check=False)
        output = (result.stdout or "") + (result.stderr or "")
        # command[0] is now an ABSOLUTE path, so branch on the basename.
        if os.path.basename(command[0]) == "gh":
            match = re.search(r"https://github\.com/\S+", output)
            if match:
                url = match.group(0).rstrip("/").removesuffix(".git")
            if result.returncode != 0:
                if "already exists" in output:
                    # Re-ship after a revise round: push to the existing repo.
                    push = subprocess.run(
                        [_resolve_bin("git"), "-C", str(outdir), "push", "origin", "main"],
                        text=True, capture_output=True, timeout=120, check=False)
                    if push.returncode != 0:
                        raise RuntimeError(f"push to existing repo failed: {(push.stderr or '')[-300:]}")
                    # The re-ship succeeded but gh emitted no fresh URL to scrape —
                    # recover it from the existing remote so we don't falsely
                    # report "no repo URL returned" after a successful push.
                    if url is None:
                        url = _remote_https_url(outdir)
                elif url is None:
                    raise RuntimeError(f"gh repo create failed: {output[-300:]}")
        elif result.returncode != 0:
            # git init/add/commit failed — abort before creating an empty remote.
            raise RuntimeError(f"{' '.join(command[:3])} failed: {output[-300:]}")
    # Final fallback: if we still have no URL but a remote exists, derive it.
    if url is None:
        url = _remote_https_url(outdir)
    return url


def ship_in_background(initiative_id: str) -> None:
    """Ship without blocking the gate response; record the repo URL in state.
    Any failure (gh/git missing, push conflict, empty outdir) is recorded as
    a visible note instead of the thread dying silently."""
    def record(note: str, url: str | None) -> None:
        with COMPANY_LOCK:
            state = company_module.CompanyStore(COMPANY_STATE_PATH).load()
            try:
                init = company_module.find_initiative(state, initiative_id)
            except KeyError:
                return
            init["repo_url"] = url or ""
            init["note"] = note
            company_module.log_event(state, f"{init['title']}: {note}")
            company_module.CompanyStore(COMPANY_STATE_PATH).save(state)

    def run() -> None:
        init: dict = {}
        try:
            store = company_module.CompanyStore(COMPANY_STATE_PATH)
            with COMPANY_LOCK:
                state = store.load()
                try:
                    init = company_module.find_initiative(state, initiative_id)
                except KeyError:
                    return
            url = ship_initiative(init)   # slow — outside the lock
            if url:
                record(f"Shipped to private repo: {url}", url)
                print(f"company - {initiative_id} shipped: {url}", flush=True)
                send_push("🚀 Shipped", f"{init.get('title', 'Your product')} is live in a private repo.",
                          payload={"initiative_id": initiative_id})
            else:
                record("Ship failed: no repo URL returned (is the gh CLI authed?).", None)
                print(f"company - {initiative_id} ship FAILED: no url", flush=True)
        except Exception as error:  # noqa: BLE001 — never let the ship thread die silently
            record(f"Ship failed: {error}", None)
            print(f"company - {initiative_id} ship FAILED: {error}", flush=True)
            send_push("⚠️ Ship failed", f"{init.get('title', 'A product')} couldn't ship — open the app.",
                      payload={"initiative_id": initiative_id})

    threading.Thread(target=run, daemon=True).start()


# ── APNs push: real remote notifications, so gate decisions reach the owner
#    ANYWHERE — closed app, cellular, other side of the world. The Mac relay
#    talks straight to Apple's push service over HTTP/2 (via curl); no VPS
#    needed because APNs does the last-mile delivery. Configure once with
#    ~/.hermes/apns.json: {"key_path": "~/keys/AuthKey_XXXX.p8", "key_id":
#    "XXXX", "team_id": "YYYY", "bundle_id": "com.jamiehouston.boardroom",
#    "environment": "development"|"production"}. Unconfigured = silent no-op.

APNS_CONFIG_PATH = Path.home() / ".hermes" / "apns.json"
_APNS_JWT_CACHE: dict[str, Any] = {"token": "", "issued": 0.0}
# Last "company parked on overload" push — at most one every 3 hours.
_OVERLOAD_PUSH: dict[str, float] = {"ts": 0.0}


def apns_config() -> dict | None:
    try:
        data = json.loads(APNS_CONFIG_PATH.read_text())
        if all(data.get(k) for k in ("key_path", "key_id", "team_id", "bundle_id")):
            return data
    except (OSError, json.JSONDecodeError, ValueError):
        pass
    return None


def apns_jwt(config: dict) -> str | None:
    """Provider token for APNs, cached ~45 min (Apple wants 20-60 min)."""
    now = time.time()
    if _APNS_JWT_CACHE["token"] and now - _APNS_JWT_CACHE["issued"] < 45 * 60:
        return _APNS_JWT_CACHE["token"]
    try:
        import jwt as pyjwt  # PyJWT + cryptography ship in the hermes venv
        key = Path(config["key_path"]).expanduser().read_text()
        token = pyjwt.encode({"iss": config["team_id"], "iat": int(now)}, key,
                             algorithm="ES256", headers={"kid": config["key_id"]})
        _APNS_JWT_CACHE.update(token=token, issued=now)
        return token
    except Exception as error:  # noqa: BLE001 — push is best-effort, never fatal
        print(f"apns - jwt failed: {error}", flush=True)
        return None


def push_tokens() -> list[str]:
    data = RelayConfigStore(CONFIG_PATH).load()
    tokens = data.get("push_tokens")
    return [t for t in tokens if isinstance(t, str) and t] if isinstance(tokens, list) else []


def register_push_token(token: str) -> None:
    """Remember a device token (deduped, most recent last, capped at 5)."""
    store = RelayConfigStore(CONFIG_PATH)
    data = store.load()
    tokens = [t for t in data.get("push_tokens", []) if isinstance(t, str) and t != token]
    tokens.append(token)
    data["push_tokens"] = tokens[-5:]
    store.save(data)


def drop_push_token(token: str) -> None:
    store = RelayConfigStore(CONFIG_PATH)
    data = store.load()
    data["push_tokens"] = [t for t in data.get("push_tokens", []) if t != token]
    store.save(data)


def apns_message(title: str, body: str, category: str = "",
                 payload: dict | None = None) -> dict:
    """The APNs JSON for one alert. Pure — unit-testable without Apple."""
    aps: dict[str, Any] = {"alert": {"title": title, "body": body},
                           "sound": "default", "interruption-level": "time-sensitive"}
    if category:
        aps["category"] = category
    return {"aps": aps, **(payload or {})}


def send_push(title: str, body: str, category: str = "",
              payload: dict | None = None) -> int:
    """Deliver an alert to every registered device. Returns sends that landed.
    Silent no-op (0) when APNs isn't configured — local notifications still
    cover the app-open case, so nothing breaks without a key."""
    config = apns_config()
    tokens = push_tokens()
    if not config or not tokens:
        return 0
    bearer = apns_jwt(config)
    if not bearer:
        return 0
    host = ("api.sandbox.push.apple.com"
            if config.get("environment", "development") == "development"
            else "api.push.apple.com")
    message = json.dumps(apns_message(title, body, category, payload))
    sent = 0
    for token in tokens:
        try:
            result = subprocess.run(
                ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 "--http2", "-m", "10",
                 "-H", f"authorization: bearer {bearer}",
                 "-H", f"apns-topic: {config['bundle_id']}",
                 "-H", "apns-push-type: alert",
                 "-H", "apns-priority: 10",
                 "-d", message,
                 f"https://{host}/3/device/{token}"],
                text=True, capture_output=True, timeout=15, check=False)
            status = result.stdout.strip()
            if status == "200":
                sent += 1
            elif status == "410":       # Apple says this token is dead
                drop_push_token(token)
            else:
                print(f"apns - push returned {status or 'nothing'}", flush=True)
        except Exception as error:  # noqa: BLE001
            print(f"apns - push failed: {error}", flush=True)
    return sent


def gate_transitions(before: dict, after: dict) -> list[dict]:
    """Initiatives that ENTERED a decision point (gate1/gate2/blocked) during
    a tick — the moments the owner must hear about wherever they are."""
    prev = {i["id"]: i.get("stage") for i in before.get("initiatives", [])}
    return [i for i in after.get("initiatives", [])
            if i.get("stage") in ("gate1", "gate2", "blocked")
            and prev.get(i["id"]) != i.get("stage")]


def gate_push_content(init: dict) -> tuple[str, str, str, dict]:
    """(title, body, category, payload) for an initiative reaching a decision.
    Category BOARDROOM_GATE gives the notification Greenlight/Kill buttons in
    the app, and the payload carries the id those buttons act on."""
    stage = init.get("stage", "")
    payload = {"initiative_id": init.get("id", ""), "stage": stage,
               "initiativeTitle": init.get("title", "")}
    if stage == "gate2":
        return ("📅 Demo Day — ready to ship",
                f"{init.get('title', '')} is built and QA'd. Greenlight to ship it.",
                "BOARDROOM_GATE", payload)
    if stage == "gate1":
        return ("💡 The CEO wants a greenlight",
                f"{init.get('title', '')}: {init.get('pitch', '')}"[:170],
                "BOARDROOM_GATE", payload)
    return ("⚠️ The team is blocked",
            f"{init.get('title', '')} needs your call to continue.",
            "", payload)


# ── Revenue loop: the company SEES what its shipped products earn (RevenueCat)
#    and feeds that back into what it pitches next. Configure once with
#    ~/.hermes/revenue-keys.json: {"revenuecat_api_key": "sk_...",
#    "revenuecat_project_id": "proj..."} (project id optional — the first
#    project on the account is used). Unconfigured = honest "not connected". ──

REVENUE_CONFIG_PATH = Path.home() / ".hermes" / "revenue-keys.json"
_REVENUE_CACHE: dict[str, Any] = {"data": None, "fetched": 0.0}
REVENUE_CACHE_SECONDS = 15 * 60


def revenue_config() -> dict | None:
    try:
        data = json.loads(REVENUE_CONFIG_PATH.read_text())
        if data.get("revenuecat_api_key"):
            return data
    except (OSError, json.JSONDecodeError, ValueError):
        pass
    return None


def _revenuecat_get(path: str, api_key: str) -> dict | None:
    import urllib.request
    request = urllib.request.Request(
        f"https://api.revenuecat.com/v2{path}",
        headers={"Authorization": f"Bearer {api_key}",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read().decode())
    except Exception as error:  # noqa: BLE001 — revenue is read-only telemetry
        print(f"revenue - fetch failed: {error}", flush=True)
        return None


def parse_revenuecat_metrics(payload: dict | None) -> list[dict]:
    """RevenueCat metrics/overview → [{id, name, value, unit}]. Pure."""
    if not isinstance(payload, dict):
        return []
    metrics = payload.get("metrics")
    if not isinstance(metrics, list):
        return []
    return [{"id": m.get("id", ""), "name": m.get("name", ""),
             "value": m.get("value", 0), "unit": m.get("unit", "")}
            for m in metrics if isinstance(m, dict) and m.get("id")]


def revenue_brief_line(metrics: list[dict]) -> str:
    """One line the agents (and widgets) can digest: the money that matters."""
    parts = []
    for metric in metrics:
        unit = metric.get("unit", "")
        value = metric.get("value", 0)
        amount = f"{unit}{value:,.2f}" if unit == "$" else f"{value:,}"
        parts.append(f"{metric.get('name', metric['id'])}: {amount}")
    return " · ".join(parts)


def revenue_summary(force: bool = False) -> dict:
    """Portfolio metrics for the app + agents, cached 15 min."""
    config = revenue_config()
    if config is None:
        return {"configured": False, "metrics": [], "brief": "",
                "note": "Add ~/.hermes/revenue-keys.json with your RevenueCat "
                        "secret API key to see live revenue here."}
    now = time.time()
    if (not force and _REVENUE_CACHE["data"] is not None
            and now - _REVENUE_CACHE["fetched"] < REVENUE_CACHE_SECONDS):
        return _REVENUE_CACHE["data"]
    api_key = config["revenuecat_api_key"]
    project_id = config.get("revenuecat_project_id")
    if not project_id:
        projects = _revenuecat_get("/projects", api_key) or {}
        items = projects.get("items") or []
        project_id = items[0].get("id") if items and isinstance(items[0], dict) else None
    metrics = parse_revenuecat_metrics(
        _revenuecat_get(f"/projects/{project_id}/metrics/overview", api_key)
        if project_id else None)
    summary = {"configured": True, "metrics": metrics,
               "brief": revenue_brief_line(metrics),
               "note": "" if metrics else "RevenueCat answered with no metrics — check the key/project.",
               "fetched": now}
    _REVENUE_CACHE.update(data=summary, fetched=now)
    return summary


def update_revenue_brief() -> None:
    """Drop the latest revenue line into company state so the scout/CEO see
    what the portfolio actually earns — the feedback loop that makes the
    company double down on winners. No-op when RevenueCat isn't wired."""
    summary = revenue_summary()
    if not summary.get("configured") or not summary.get("brief"):
        return
    store = company_module.CompanyStore(COMPANY_STATE_PATH)
    with COMPANY_LOCK:
        state = store.load()
        if state.get("revenue_brief") != summary["brief"]:
            state["revenue_brief"] = summary["brief"]
            store.save(state)


# ── Demo Day assets: the screenshots the builder captures into <project>/.demo
#    so the owner SEES the product at gate 2 instead of approving blind. ──

DEMO_SUFFIXES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                 ".gif": "image/gif", ".mp4": "video/mp4"}


def demo_dir_for(initiative_id: str) -> Path | None:
    store = company_module.CompanyStore(COMPANY_STATE_PATH)
    with COMPANY_LOCK:
        state = store.load()
    try:
        init = company_module.find_initiative(state, initiative_id)
    except KeyError:
        return None
    return COMPANY_ARTIFACTS_ROOT / company_module.initiative_dirname(init) / ".demo"


def demo_asset_names(initiative_id: str) -> list[str]:
    demo_dir = demo_dir_for(initiative_id)
    if demo_dir is None or not demo_dir.is_dir():
        return []
    return sorted(p.name for p in demo_dir.iterdir()
                  if p.is_file() and p.suffix.lower() in DEMO_SUFFIXES)


def demo_asset(initiative_id: str, filename: str) -> tuple[bytes, str] | None:
    """Bytes + MIME for one demo file. The name is validated against the
    directory's own listing, so traversal (`../`, absolute paths) is dead on
    arrival — a request can only name files that actually sit in .demo."""
    if filename not in demo_asset_names(initiative_id):
        return None
    demo_dir = demo_dir_for(initiative_id)
    if demo_dir is None:
        return None
    path = demo_dir / filename
    try:
        return path.read_bytes(), DEMO_SUFFIXES[path.suffix.lower()]
    except OSError:
        return None


# ── Company Vault: Lena files meetings as linked Obsidian notes (additive) ──

CONSTITUTION_FILENAME = "Company.md"
CONSTITUTION_SEED = (
    "# Company — Constitution\n\n"
    "> The single source of truth for this company. Edit me in Obsidian — every "
    "board agent reads this before it decides.\n\n"
    "## Thesis\n"
    "<One paragraph: what this company is, who it serves, and how it wins. "
    "Replace this line.>\n\n"
    "## Chain of command\n"
    "- Chairman (Andrew) — owner, final authority\n"
    "- CEO — chairs the board, owns outcomes\n"
    "- CFO / CTO / Head of Marketing / Head of Research — the board\n"
    "- Lead Builder, QA + Design lead — execution & the shipping gate\n"
    "- Lena — the Chairman's executive assistant\n\n"
    "## Operating principles\n"
    "- Real, finished, verifiable work — never faked, padded, or hidden.\n"
    "- Consequential or hard-to-reverse moves get the Chairman's explicit YES first.\n"
    "- Stay fully within the law.\n\n"
    "## Current priorities\n"
    "<Edit: e.g. 'Ship one revenue-positive initiative this month.'>\n"
)
MEMORY_BLOCK_CAP = 2800
_CONSTITUTION_CAP = 1500
_DECISIONS_CAP = 1200
DELIBERATIVE_ROLES = {"ceo", "cfo", "cto", "marketing", "builder", "qa"}


def _vault_slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")[:48] or "note"


def _vault_write(subdir: str, filename: str, content: str) -> None:
    folder = COMPANY_VAULT_ROOT / subdir if subdir else COMPANY_VAULT_ROOT
    folder.mkdir(parents=True, exist_ok=True)
    (folder / filename).write_text(content)


def ensure_constitution(root: Path | None = None) -> None:
    """Seed the company Constitution (Company.md) if absent. NEVER overwrites —
    the owner edits it in Obsidian. Idempotent; safe on every vault touch."""
    base = root or COMPANY_VAULT_ROOT
    path = base / CONSTITUTION_FILENAME
    if path.exists():
        return
    base.mkdir(parents=True, exist_ok=True)
    path.write_text(CONSTITUTION_SEED)


def build_memory_block(root: Path | None = None, include_decisions: bool = True) -> str:
    """Compact 'company memory' for agent turns: the Constitution + (optionally)
    the most recent decisions, size-capped. include_decisions=False → constitution
    only (used for interactive chat, to stay lean). Fail-safe: ANY error → '' (a
    vault read must never break a turn)."""
    base = root or COMPANY_VAULT_ROOT
    try:
        parts: list[str] = []
        con = base / CONSTITUTION_FILENAME
        if con.exists():
            parts.append("### Constitution\n" + con.read_text()[:_CONSTITUTION_CAP].strip())
        if include_decisions:
            log = base / "decisions" / "Decision Log.md"
            if log.exists():
                body = log.read_text().split("\n## ")[1:]   # drop the "# Decision Log" header chunk
                recent = body[-8:]
                if recent:
                    tail = ("## " + "\n## ".join(recent)).strip()
                    parts.append("### Recent decisions\n" + tail[-_DECISIONS_CAP:])
        if not parts:
            return ""
        block = ("## Company memory (shared brain — read before you decide)\n"
                 + "\n\n".join(parts))
        return block[:MEMORY_BLOCK_CAP]
    except Exception:  # noqa: BLE001 — memory read must never break a turn
        return ""


def compose_company_prompt(role: str, prompt: str, root: Path | None = None) -> str:
    """Prepend the company memory block for deliberative board roles only.
    Utility calls — Scout ('research', strict JSON) and Lena ('lena', minutes) —
    are SKIPPED so injected prose can't corrupt their required output formats.
    Empty block or non-deliberative role → prompt unchanged."""
    if role not in DELIBERATIVE_ROLES:
        return prompt
    block = build_memory_block(root)
    if not block:
        return prompt
    return f"{block}\n\n{prompt}"


def compose_chat_message(session_key: str, message: str, fast: bool = False,
                         root: Path | None = None) -> str:
    """Prefix the company Constitution into interactive company-chat turns so the
    app's agents share the same source of truth as the autonomous board. Skipped
    for voice-fast turns (latency) and non-company sessions (e.g. the briefing)."""
    if fast or not session_key.startswith("company-"):
        return message
    block = build_memory_block(root, include_decisions=False)
    if not block:
        return message
    return f"{block}\n\n{message}"


def ensure_vault_home() -> None:
    ensure_constitution()
    home = COMPANY_VAULT_ROOT / "Home.md"
    if home.exists():
        return
    COMPANY_VAULT_ROOT.mkdir(parents=True, exist_ok=True)
    home.write_text(
        "# Boardroom — Company Vault\n\n"
        "Your company's shared memory, filed by **Lena**. Open this folder as a "
        "vault in Obsidian.\n\n"
        "- `meetings/` — minutes + decisions from every meeting\n"
        "- `decisions/Decision Log.md` — the running decision log\n\n"
        "_Lena keeps this up to date automatically after each meeting._\n")


def lena_minutes(topic: str, transcript: str) -> tuple[str, str]:
    """Lena reads a transcript → (summary, decisions-markdown). Falls back safely
    if the model call fails — vault filing must never break a meeting."""
    prompt = (
        "You are Lena, the owner's executive assistant, filing the minutes of a "
        f"company meeting titled \"{topic}\". Read the transcript and reply in EXACTLY "
        "this format, nothing else:\n\n"
        "SUMMARY:\n<3-4 sentence plain-English summary>\n\n"
        "DECISIONS:\n<a short markdown bullet list of concrete decisions; if none "
        "were made, write '- No formal decisions were made.'>\n\n"
        f"Transcript:\n{transcript[:6000]}"
    )
    try:
        out = company_cli_runner("lena", prompt).strip()
    except Exception:  # noqa: BLE001
        return "(Summary unavailable — see the transcript below.)", "- (see transcript)"
    if "DECISIONS:" in out:
        summary, decisions = out.split("DECISIONS:", 1)
        return summary.replace("SUMMARY:", "").strip(), decisions.strip()
    return out.replace("SUMMARY:", "").strip(), "- (see summary)"


def write_meeting_to_vault(meeting: dict, summarize: bool = True) -> None:
    turns = meeting.get("turns", [])
    if not turns:
        return
    topic = meeting.get("topic", "Meeting")
    transcript = "\n".join(f"**{t.get('role', '?').upper()}**: {t.get('text', '')}" for t in turns)
    date = time.strftime("%Y-%m-%d")
    note = f"{date}-{_vault_slug(topic)}"
    if summarize:
        summary, decisions = lena_minutes(topic, transcript)
    else:
        summary, decisions = "(Filed from history — see the transcript below.)", "- (not extracted)"
    attendees = meeting.get("attendees", [])
    attendee_links = " ".join(f"[[{r}]]" for r in attendees) or "—"
    body = (
        f"---\ntype: meeting\ndate: {date}\nattendees: [{', '.join(attendees)}]\n---\n"
        f"# {topic}\n\n> Filed by Lena · {date}\n\n"
        f"## Summary\n{summary}\n\n"
        f"## Decisions\n{decisions}\n\n"
        f"## Attendees\n{attendee_links}\n\n"
        f"## Transcript\n{transcript}\n"
    )
    _vault_write("meetings", f"{note}.md", body)
    if decisions and "(not extracted)" not in decisions:
        log = COMPANY_VAULT_ROOT / "decisions" / "Decision Log.md"
        log.parent.mkdir(parents=True, exist_ok=True)
        existing = log.read_text() if log.exists() else "# Decision Log\n\nDecisions Lena recorded from meetings.\n"
        log.write_text(existing + f"\n## {topic} — {date}\n{decisions}\n→ [[{note}]]\n")


def file_meeting_minutes(meeting_id: str) -> None:
    """Hooked at the end of every meeting — additive, never breaks the meeting."""
    try:
        ensure_vault_home()
        meeting = find_meeting(company_module.CompanyStore(COMPANY_STATE_PATH).load(), meeting_id)
        if meeting:
            write_meeting_to_vault(meeting, summarize=True)
            print(f"company - filed minutes to vault: {meeting.get('topic', '')[:40]}", flush=True)
    except Exception as error:  # noqa: BLE001 — vault filing must never break a meeting
        print(f"company - vault filing failed: {error}", flush=True)


def vault_backfill() -> int:
    """File existing meetings (transcript-only, no model calls) so the vault is
    populated immediately. Returns how many were filed."""
    ensure_vault_home()
    state = company_module.CompanyStore(COMPANY_STATE_PATH).load()
    count = 0
    for meeting in state.get("meetings", []):
        if meeting.get("turns"):
            try:
                write_meeting_to_vault(meeting, summarize=False)
                count += 1
            except Exception:  # noqa: BLE001
                pass
    return count


def vault_graph() -> dict:
    """The vault as a graph: every note is a node, every [[wikilink]] an edge.
    Powers the app's 3D/2D knowledge-graph view."""
    root = COMPANY_VAULT_ROOT
    if not root.exists():
        return {"nodes": [], "edges": []}
    agent_ids = {"ceo", "cfo", "cto", "marketing", "research", "builder", "qa", "lena", "gm"}
    skip = {"Home", "Decision Log"}

    def kind(name: str, folder: str) -> str:
        if name.lower() in agent_ids:
            return "agent"
        if folder == "meetings":
            return "meeting"
        if folder == "decisions":
            return "decision"
        return "note"

    def label(name: str, is_agent: bool) -> str:
        if is_agent:
            return name.upper()
        s = re.sub(r"^\d{4}-\d{2}-\d{2}-", "", name).replace("-", " ")
        low = s.lower()
        for pre in ("status check ", "office hours ", "company standup ", "company standup"):
            if low.startswith(pre):
                s = s[len(pre):]
                break
        return s.strip().title() or name.replace("-", " ").title()

    nodes: dict[str, dict] = {}
    edges: list[dict] = []
    for md in root.rglob("*.md"):
        nid = md.stem
        if nid in skip:
            continue
        typ = kind(nid, md.parent.name)
        nodes.setdefault(nid, {"id": nid, "label": label(nid, typ == "agent"), "type": typ})
        try:
            text = md.read_text(errors="ignore")
        except Exception:  # noqa: BLE001
            continue
        for raw in re.findall(r"\[\[([^\]]+)\]\]", text):
            target = raw.split("|")[0].split("#")[0].strip()
            if not target or target in skip:
                continue
            ttyp = kind(target, "")
            nodes.setdefault(target, {"id": target, "label": label(target, ttyp == "agent"), "type": ttyp})
            edges.append({"source": nid, "target": target})
    return {"nodes": list(nodes.values()), "edges": edges}


def run_autonomous_meeting() -> None:
    """The org holds an internal standup on its own. Each turn is saved as it
    lands so the owner can open the Meeting Room and watch it happen live."""
    store = company_module.CompanyStore(COMPANY_STATE_PATH)
    with COMPANY_LOCK:
        state = store.load()
        if not company_module.should_convene_meeting(state, time.time()):
            return
        topic, roles = company_module.meeting_plan(state)
        meeting = company_module.new_meeting(topic, roles)
        state.setdefault("meetings", []).insert(0, meeting)
        state["meetings"] = state["meetings"][:20]   # keep the last 20
        state["last_meeting"] = time.time()
        company_module.log_event(state, f"meeting started: {topic}")
        store.save(state)
    meeting_id = meeting["id"]
    print(f"company - meeting started: {topic}", flush=True)

    def append_turn(role: str, text: str) -> None:
        with COMPANY_LOCK:
            s = store.load()
            for m in s.get("meetings", []):
                if m["id"] == meeting_id:
                    m["turns"].append({"role": role, "text": text.strip(),
                                       "ts": time.strftime("%H:%M")})
                    break
            store.save(s)

    transcript = ""
    try:
        for role in roles:
            prompt = company_module.meeting_turn_prompt(meeting, role, transcript, state)
            text = company_cli_runner(role, prompt).strip() or "(no comment)"
            append_turn(role, text)
            transcript += f"\n{role.upper()}: {text}"
    except Exception as error:  # noqa: BLE001 — a bad turn shouldn't wedge the meeting
        print(f"company - meeting turn failed: {error}", flush=True)
    # Mark done.
    with COMPANY_LOCK:
        s = store.load()
        for m in s.get("meetings", []):
            if m["id"] == meeting_id:
                m["status"] = "done"
                break
        store.save(s)
    print(f"company - meeting concluded: {topic}", flush=True)
    file_meeting_minutes(meeting_id)


def run_owner_meeting_response(meeting_id: str, owner_text: str) -> None:
    """Owner spoke into a meeting — append their turn, then the attendees
    respond to it (saved live), then mark done. Runs in the background."""
    store = company_module.CompanyStore(COMPANY_STATE_PATH)
    with COMPANY_LOCK:
        state = store.load()
        meeting = company_module.add_owner_turn(state, meeting_id, owner_text)
        if meeting is None:
            return
        roles = list(meeting.get("attendees", []))
        store.save(state)

    def append_turn(role: str, text: str) -> None:
        with COMPANY_LOCK:
            s = store.load()
            for m in s.get("meetings", []):
                if m["id"] == meeting_id:
                    m["turns"].append({"role": role, "text": text.strip(),
                                       "ts": time.strftime("%H:%M")})
                    break
            store.save(s)

    transcript = "\n".join(f"{t['role'].upper()}: {t['text']}" for t in meeting["turns"])
    try:
        for role in roles:
            prompt = company_module.owner_response_prompt(meeting, role, owner_text, transcript, state)
            text = company_cli_runner(role, prompt).strip() or "(no comment)"
            append_turn(role, text)
            transcript += f"\n{role.upper()}: {text}"
    except Exception as error:  # noqa: BLE001
        print(f"company - owner-meeting turn failed: {error}", flush=True)
    with COMPANY_LOCK:
        s = store.load()
        for m in s.get("meetings", []):
            if m["id"] == meeting_id:
                m["status"] = "done"
                break
        store.save(s)
    file_meeting_minutes(meeting_id)


def run_company_ask(ask_id: str, question: str) -> None:
    """Owner asked the company a question — the board answers (saved live so the
    app can show each leader as they land), then the CEO synthesizes one answer.
    Background, like meetings."""
    store = company_module.CompanyStore(COMPANY_STATE_PATH)
    with COMPANY_LOCK:
        state = store.load()
        roles = company_module.ask_panel(state, question)
    print(f"company - ask started: {question[:60]}", flush=True)

    def append_contribution(role: str, text: str) -> None:
        with COMPANY_LOCK:
            s = store.load()
            for ask in s.get("asks", []):
                if ask["id"] == ask_id:
                    ask["contributions"].append({"role": role, "text": text.strip()})
                    break
            store.save(s)

    transcript = ""
    try:
        for role in roles:
            prompt = company_module.ask_prompt(role, question, transcript, state)
            text = company_cli_runner(role, prompt).strip() or "(no comment)"
            append_contribution(role, text)
            transcript += f"\n{role.upper()}: {text}"
        answer = company_cli_runner(
            "ceo", company_module.ask_synthesis_prompt(question, transcript)).strip()
    except Exception as error:  # noqa: BLE001 — never let the ask thread die silently
        answer = ""
        print(f"company - ask failed: {error}", flush=True)

    with COMPANY_LOCK:
        s = store.load()
        for ask in s.get("asks", []):
            if ask["id"] == ask_id:
                ask["answer"] = answer or "Couldn't reach the team — try again."
                ask["status"] = "done"
                break
        company_module.log_event(s, f"answered: {question[:50]}")
        store.save(s)
    print(f"company - ask done: {question[:60]}", flush=True)


def run_scheduled_meeting(topic: str) -> None:
    """A scheduled office-hours meeting fires — convene leadership and run the
    turns live (the owner gets the 'team is meeting' ping and can join by voice
    in the Meeting Room). Mirrors the autonomous meeting, minus the cadence gate."""
    store = company_module.CompanyStore(COMPANY_STATE_PATH)
    roles = ["ceo", "cfo", "cto", "marketing"]
    with COMPANY_LOCK:
        state = store.load()
        if any(m.get("status") == "live" for m in state.get("meetings", [])):
            return   # never stack on a live meeting
        meeting = company_module.new_meeting(topic, roles)
        state.setdefault("meetings", []).insert(0, meeting)
        state["meetings"] = state["meetings"][:20]
        state["last_meeting"] = time.time()
        company_module.log_event(state, f"office hours: {topic}")
        store.save(state)
    meeting_id = meeting["id"]
    print(f"company - office hours started: {topic}", flush=True)

    def append_turn(role: str, text: str) -> None:
        with COMPANY_LOCK:
            s = store.load()
            for m in s.get("meetings", []):
                if m["id"] == meeting_id:
                    m["turns"].append({"role": role, "text": text.strip(),
                                       "ts": time.strftime("%H:%M")})
                    break
            store.save(s)

    transcript = ""
    try:
        for role in roles:
            prompt = company_module.meeting_turn_prompt(meeting, role, transcript, state)
            text = company_cli_runner(role, prompt).strip() or "(no comment)"
            append_turn(role, text)
            transcript += f"\n{role.upper()}: {text}"
    except Exception as error:  # noqa: BLE001
        print(f"company - office hours turn failed: {error}", flush=True)
    with COMPANY_LOCK:
        s = store.load()
        for m in s.get("meetings", []):
            if m["id"] == meeting_id:
                m["status"] = "done"
                break
        store.save(s)
    print(f"company - office hours concluded: {topic}", flush=True)
    file_meeting_minutes(meeting_id)


def run_schedules() -> None:
    """Fire any owner automations that are due — recurring directives, asks, and
    office-hours meetings (the Cron). Runs each heartbeat; gated on enabled."""
    store = company_module.CompanyStore(COMPANY_STATE_PATH)
    asks_to_run: list[tuple[str, str]] = []
    meetings_to_run: list[str] = []
    with COMPANY_LOCK:
        state = store.load()
        if not state.get("enabled"):
            return
        due = company_module.due_schedules(state, time.time())
        if not due:
            return
        now = time.time()
        for sched in due:
            sched["last_fired"] = now
            if sched["kind"] == "ask":
                ask = company_module.new_ask(sched["text"])
                state.setdefault("asks", []).insert(0, ask)
                state["asks"] = state["asks"][:20]
                asks_to_run.append((ask["id"], sched["text"]))
            elif sched["kind"] == "meeting":
                meetings_to_run.append(sched["text"] or sched["title"])
            else:  # directive
                company_module.seed_initiative(state, sched["text"])
            company_module.log_event(state, f"scheduled {sched['kind']}: {sched['title']}")
        store.save(state)
    for ask_id, question in asks_to_run:
        threading.Thread(target=run_company_ask, args=(ask_id, question), daemon=True).start()
        print(f"company - scheduled ask: {question[:50]}", flush=True)
    for topic in meetings_to_run:
        threading.Thread(target=run_scheduled_meeting, args=(topic,), daemon=True).start()
        print(f"company - scheduled office hours: {topic[:50]}", flush=True)


def run_task_work() -> None:
    """Kanban List mode: the team works through the owner's task backlog instead
    of their own ideas — one task per heartbeat, To Do → In Progress → Done,
    saved live so the board updates in the app. Mirrors the meeting pattern:
    persist 'In Progress' under the lock, run the slow builder OUTSIDE it, then
    reload-by-id and persist the result."""
    store = company_module.CompanyStore(COMPANY_STATE_PATH)
    with COMPANY_LOCK:
        state = store.load()
        if not state.get("enabled") or not state.get("task_mode"):
            return
        if company_module.machine_overloaded(state["config"].get("max_load_per_core", 2.5)):
            return   # task turns spend API calls too — wait out the load spike
        task = company_module.next_task(state)
        if task is None:
            return
        task_id = task["id"]
        text = task["text"]
        if task["status"] == "todo":
            task["status"] = "doing"
            task["attempts"] = task.get("attempts", 0) + 1
            company_module.log_event(state, f"started task: {text[:60]}")
            store.save(state)          # makes 'In Progress' show immediately
        attempts = task.get("attempts", 1)
    print(f"company - task started: {text[:60]}", flush=True)

    outdir = COMPANY_TASKS_WORKSPACE
    outdir.mkdir(parents=True, exist_ok=True)
    existing = sorted(str(p) for p in outdir.rglob("*") if p.is_file())
    prompt = company_module.task_build_prompt(text, existing, outdir)
    try:
        report = company_cli_runner("builder", prompt).strip() or "(done)"
    except Exception as error:  # noqa: BLE001 — a bad task must not wedge the queue
        with COMPANY_LOCK:
            s = store.load()
            task = company_module.find_task(s, task_id)
            if task is not None:
                if attempts >= company_module.MAX_TASK_ATTEMPTS:
                    task["status"] = "done"   # parked so the queue moves on
                    task["result"] = f"⚠ couldn't complete after {attempts} tries: {error}"
                    company_module.log_event(s, f"task parked (failed): {text[:60]}")
                else:
                    task["status"] = "todo"   # back to the queue to retry later
                    task["result"] = f"retry pending ({attempts}): {error}"
                store.save(s)
        print(f"company - task failed ({attempts}): {error}", flush=True)
        return

    artifacts = sorted(str(p) for p in outdir.rglob("*") if p.is_file())
    with COMPANY_LOCK:
        s = store.load()
        task = company_module.find_task(s, task_id)
        if task is not None:
            task["status"] = "done"
            task["result"] = report[:600]
            task["artifacts"] = artifacts
            company_module.log_event(s, f"finished task: {text[:60]}")
            store.save(s)
    print(f"company - task done: {text[:60]}", flush=True)


def company_summary(state: dict) -> dict:
    """State for the app: everything except the bulky transcripts/minutes."""
    slim = []
    for init in state["initiatives"]:
        item = {k: v for k, v in init.items() if k != "minutes"}
        # Keep this payload SMALL — the app re-fetches it every 60s. The list UI
        # shows neither the raw failure `note` (a timeout note embeds the ENTIRE
        # build prompt, ~27KB each) nor the `artifacts` file list (one build's was
        # 430KB). Left whole they bloated this response to ~840KB and made the app
        # hitch/freeze on every refresh. Both are still available in full via
        # /company/initiative/<id>, which the detail screen already uses.
        note = item.get("note") or ""
        if len(note) > 280:
            item["note"] = note[:279] + "…"
        item["artifacts"] = []
        slim.append(item)
    # Meetings without full turn text — just enough for the list + live badge.
    meetings = []
    for m in state.get("meetings", []):
        meetings.append({
            "id": m["id"], "topic": m["topic"], "status": m["status"],
            "attendees": m["attendees"], "started": m["started"],
            "turn_count": len(m.get("turns", [])),
        })
    return {
        "enabled": state["enabled"],
        "thesis": state["thesis"],
        "config": state["config"],
        "last_tick": state["last_tick"],
        "initiatives": slim,
        "meetings": meetings,
        "events": state.get("events", [])[-30:],   # activity feed
        "tasks": state.get("tasks", []),            # Kanban backlog
        "task_mode": state.get("task_mode", False), # "Kanban List" toggle
        "asks": state.get("asks", [])[:10],         # Ask-the-company Q&A (newest first)
        "schedules": state.get("schedules", []),    # owner automations (the Cron)
    }


def find_meeting(state: dict, meeting_id: str) -> dict | None:
    for m in state.get("meetings", []):
        if m["id"] == meeting_id:
            return m
    return None


def find_ask(state: dict, ask_id: str) -> dict | None:
    for ask in state.get("asks", []):
        if ask["id"] == ask_id:
            return ask
    return None


def cleanup_zombie_simulators() -> None:
    """Builder/demo turns boot iOS simulators; when a turn is timeout-killed
    its cleanup never runs, so booted sims (and hundreds of CoreSimulator
    daemons) accumulate until the Mac drowns — which then makes MORE turns
    time out. If the Simulator GUI isn't open — nobody is watching them —
    shut every booted device down. Never touches sims the owner has open."""
    try:
        gui = subprocess.run(["pgrep", "-x", "Simulator"], capture_output=True, timeout=5)
        if gui.returncode == 0:
            return   # the owner has Simulator.app open — hands off
        booted = subprocess.run(["xcrun", "simctl", "list", "devices", "booted"],
                                capture_output=True, text=True, timeout=20)
        if "(Booted)" not in (booted.stdout or ""):
            return
        subprocess.run(["xcrun", "simctl", "shutdown", "all"],
                       capture_output=True, timeout=90)
        print("company - shut down zombie simulators (headless, left by killed build turns)", flush=True)
    except Exception:  # noqa: BLE001 — hygiene must never break the pulse
        pass


_BRIEFING_PUSH = {"date": ""}   # module-level once-per-day dedup (mirrors _OVERLOAD_PUSH)


def build_briefing_digest(state: dict) -> str:
    """A short, deterministic morning-briefing line built from REAL company state —
    no model call, so it can't hallucinate or hang the relay at 3am. Fail-safe."""
    try:
        inits = state.get("initiatives", []) or []
        active = [i for i in inits if i.get("stage") not in ("shipped", "killed", "archived")]
        gates = [i for i in active if str(i.get("stage", "")).startswith("gate")]
        meetings = state.get("meetings", []) or []
        parts: list[str] = []
        if active:
            parts.append(f"{len(active)} initiative{'s' if len(active) != 1 else ''} active")
        if gates:
            parts.append(f"{len(gates)} gate{'s' if len(gates) != 1 else ''} awaiting you")
        if meetings:
            parts.append(f"last: {meetings[-1].get('topic', 'meeting')}")
        return " · ".join(parts) if parts else "Quiet — nothing needs you right now."
    except Exception:  # noqa: BLE001 — a briefing must never break the heartbeat
        return "Your morning briefing is ready."


def briefing_due(config: dict, now: float, last_date: str) -> bool:
    """True at/after the configured morning hour, at most once per calendar day."""
    if not config.get("briefing_push_enabled", True):
        return False
    hour = int(config.get("briefing_hour", 8))
    local = time.localtime(now)
    if last_date == time.strftime("%Y-%m-%d", local):
        return False
    return local.tm_hour >= hour


def maybe_push_briefing(state: dict, now: float | None = None) -> bool:
    """Once a day in the morning, push a real briefing digest to the owner's phone.
    No-op if not due, or silently if APNs is unconfigured (send_push handles that)."""
    now = now if now is not None else time.time()
    if not briefing_due(state.get("config", {}) or {}, now, _BRIEFING_PUSH["date"]):
        return False
    _BRIEFING_PUSH["date"] = time.strftime("%Y-%m-%d", time.localtime(now))  # once/day regardless of send
    digest = build_briefing_digest(state)
    return bool(send_push("Morning briefing", digest, "BOARDROOM_BRIEFING", {"kind": "briefing"}))


def company_heartbeat_loop() -> None:
    store = company_module.CompanyStore(COMPANY_STATE_PATH)
    while True:
        try:
            cleanup_zombie_simulators()
            # Agent turns take MINUTES — never hold the lock through them, or
            # the app's /company reads (and gate decisions) block until done.
            with COMPANY_LOCK:
                state = store.load()
            before = json.loads(json.dumps(state))   # deep snapshot for merge
            events = company_module.tick(state, company_cli_runner, COMPANY_ARTIFACTS_ROOT)
            if events or state["last_tick"] != before["last_tick"]:
                with COMPANY_LOCK:
                    current = store.load()
                    store.save(company_module.merge_tick_results(current, state, before))
            # Real push (APNs) the moment something needs the owner's decision —
            # reaches a closed app on cellular, not just the local Wi-Fi poll.
            for init in gate_transitions(before, state):
                title, body, category, payload = gate_push_content(init)
                if send_push(title, body, category, payload):
                    print(f"company - pushed: {title} ({init['id']})", flush=True)
            for event in events:
                print(f"company - {event}", flush=True)
            # If the overload pause has dragged on, tell the owner ONCE (per
            # 3h) — a silently parked company is indistinguishable from a
            # broken one, and that silence cost days of shipping time.
            if any("⏰ 45m+" in event or "forcing one turn" in event for event in events):
                now_ts = time.time()
                if now_ts - _OVERLOAD_PUSH["ts"] > 3 * 3600:
                    _OVERLOAD_PUSH["ts"] = now_ts
                    send_push("⏸ Company waiting on your Mac",
                              "The Mac has been overloaded for 45+ min, so builds are paced. "
                              "Close heavy apps to let the company ship faster.")
            # Games Studio division — advance any in-flight game one stage.
            games_heartbeat()
            # The org also meets among itself on a cadence — visible/live in the app.
            run_autonomous_meeting()
            # Kanban List mode: work the owner's task backlog (self-gates on the
            # enabled + task_mode flags; no-op when the toggle is off).
            run_task_work()
            # Owner automations (the Cron): fire due directives/asks.
            run_schedules()
            # Proactive: once a day in the morning, push a real briefing digest
            # to the owner's phone (reaches a closed app; no-op without tokens).
            maybe_push_briefing(state)
            # Revenue feedback: keep the agents' view of what the portfolio
            # earns fresh (15-min cache inside; no-op without a RevenueCat key).
            update_revenue_brief()
        except Exception as error:  # noqa: BLE001 — the pulse must survive anything
            print(f"company - heartbeat error: {error}", flush=True)
        time.sleep(60)


class RelayHandler(BaseHTTPRequestHandler):
    token = ""
    timeout = 240
    public_url = ""
    config_store = RelayConfigStore(CONFIG_PATH)
    # Pairing pages hand out the bearer token, so they only answer from the
    # Mac itself or during a short window after startup — the moment you're
    # actually pairing. Restart the relay (or re-run setup.sh) to re-open.
    started_at = time.monotonic()
    pair_window_seconds = int(os.environ.get("HERMES_PAIR_WINDOW", "600"))

    def pairing_allowed(self) -> bool:
        if self.client_address[0] in ("127.0.0.1", "::1"):
            return True
        return time.monotonic() - RelayHandler.started_at < RelayHandler.pair_window_seconds

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(
                {
                    "ok": True,
                    "service": "hermes-mobile-relay",
                    "profiles": discover_profiles(),
                    "warm": WARM_CLIENT.warm(),
                    "tts": piper_available(),
                    "voices": available_voices(),
                    # Policy: internal voice is ALWAYS the free engine; the
                    # paid voice exists only for premium (sales) requests.
                    "voice_engine": "piper" if piper_available() else "none",
                    "premium_voice": elevenlabs_config() is not None,
                    "apns": apns_config() is not None,
                }
            )
            return
        if self.path in {"/pair", "/pair.json", "/pair.png"} and not self.pairing_allowed():
            self.send_json({"error": "pairing_window_closed",
                            "fix": "Restart the relay (or run Scripts/setup.sh) and pair within 10 minutes, or open this page on the Mac itself."},
                           status=403)
            return
        if self.path == "/pair.json":
            self.send_json(pairing_payload(self.public_url, self.token))
            return
        if self.path == "/pair.png":
            png = pairing_qr_png(pairing_payload(self.public_url, self.token))
            if png is None:
                self.send_json({"error": "qr_unavailable", "install": "python3 -m pip install --user 'qrcode[pil]'"}, status=503)
                return
            self.send_bytes(png, "image/png")
            return
        if self.path == "/pair":
            self.send_html(pairing_page(self.public_url, self.token))
            return
        if self.path == "/company":
            if not self.is_authorized():
                self.send_json({"error": "unauthorized"}, status=401)
                return
            store = company_module.CompanyStore(COMPANY_STATE_PATH)
            with COMPANY_LOCK:
                self.send_json(company_summary(store.load()))
            return
        if self.path.startswith("/company/demo/"):
            # /company/demo/<initiative_id>/<filename> → the image/video bytes.
            if not self.is_authorized():
                self.send_json({"error": "unauthorized"}, status=401)
                return
            parts = self.path.split("/")
            if len(parts) != 5:
                self.send_json({"error": "not_found"}, status=404)
                return
            asset = demo_asset(parts[3], urllib.parse.unquote(parts[4]))
            if asset is None:
                self.send_json({"error": "not_found"}, status=404)
                return
            self.send_bytes(asset[0], asset[1])
            return
        if self.path.startswith("/company/initiative/") and self.path.endswith("/demo"):
            # The demo gallery manifest for one initiative (gate-2 screen).
            if not self.is_authorized():
                self.send_json({"error": "unauthorized"}, status=401)
                return
            initiative_id = self.path.split("/")[3]
            self.send_json({"files": demo_asset_names(initiative_id)})
            return
        if self.path.startswith("/company/initiative/"):
            if not self.is_authorized():
                self.send_json({"error": "unauthorized"}, status=401)
                return
            initiative_id = self.path.rsplit("/", 1)[-1]
            store = company_module.CompanyStore(COMPANY_STATE_PATH)
            with COMPANY_LOCK:
                try:
                    self.send_json(company_module.find_initiative(store.load(), initiative_id))
                except KeyError:
                    self.send_json({"error": "not_found"}, status=404)
            return
        if self.path.startswith("/company/meeting/"):
            if not self.is_authorized():
                self.send_json({"error": "unauthorized"}, status=401)
                return
            meeting_id = self.path.rsplit("/", 1)[-1]
            store = company_module.CompanyStore(COMPANY_STATE_PATH)
            with COMPANY_LOCK:
                meeting = find_meeting(store.load(), meeting_id)
            if meeting is None:
                self.send_json({"error": "not_found"}, status=404)
            else:
                self.send_json(meeting)
            return
        if self.path.startswith("/company/ask/"):
            if not self.is_authorized():
                self.send_json({"error": "unauthorized"}, status=401)
                return
            ask_id = self.path.rsplit("/", 1)[-1]
            store = company_module.CompanyStore(COMPANY_STATE_PATH)
            with COMPANY_LOCK:
                ask = find_ask(store.load(), ask_id)
            if ask is None:
                self.send_json({"error": "not_found"}, status=404)
            else:
                self.send_json(ask)
            return
        if self.path == "/games":
            if not self.is_authorized():
                self.send_json({"error": "unauthorized"}, status=401)
                return
            with GAMES_LOCK:
                state = games_module.StudioStore(GAMES_STATE_PATH).load()
            self.send_json(games_module.studio_summary(state))
            return
        if self.path.startswith("/games/game/"):
            if not self.is_authorized():
                self.send_json({"error": "unauthorized"}, status=401)
                return
            game_id = self.path.rsplit("/", 1)[-1]
            with GAMES_LOCK:
                state = games_module.StudioStore(GAMES_STATE_PATH).load()
            game = next((g for g in state.get("games", []) if g["id"] == game_id), None)
            if game is None:
                self.send_json({"error": "not_found"}, status=404)
            else:
                self.send_json(game)
            return
        if self.path == "/company/vault/graph":
            if not self.is_authorized():
                self.send_json({"error": "unauthorized"}, status=401)
                return
            self.send_json(vault_graph())
            return
        if self.path == "/company/revenue":
            if not self.is_authorized():
                self.send_json({"error": "unauthorized"}, status=401)
                return
            self.send_json(revenue_summary())
            return
        if self.path == "/voice/usage":
            # The Voice settings screen: budgets + what's been spent.
            if not self.is_authorized():
                self.send_json({"error": "unauthorized"}, status=401)
                return
            config = elevenlabs_config() or {}
            usage = load_voice_usage()
            self.send_json({
                "premium_configured": bool(config),
                "daily_char_budget": int(config.get("daily_char_budget", DEFAULT_DAILY_CHAR_BUDGET)),
                "weekly_char_budget": int(config.get("weekly_char_budget", DEFAULT_WEEKLY_CHAR_BUDGET)),
                "used_today": usage["chars_today"],
                "used_week": usage["chars_week"],
            })
            return
        self.send_json({"error": "not_found"}, status=404)

    def do_POST(self) -> None:
        is_meeting_say = self.path.startswith("/company/meeting/") and self.path.endswith("/say")
        if self.path not in {"/chat", "/chat/stream", "/tts", "/push/register",
                             "/company/start", "/company/halt", "/company/gate",
                             "/company/iterate", "/company/directive", "/company/ask",
                             "/company/thesis", "/company/vault/sync", "/company/config",
                             "/company/tasks", "/company/tasks/mode",
                             "/company/tasks/clear", "/company/task/delete",
                             "/company/schedules", "/company/schedule/delete",
                             "/company/schedule/toggle",
                             "/games/start", "/games/halt",
                             "/games/concept", "/games/score"} and not is_meeting_say:
            self.send_json({"error": "not_found"}, status=404)
            return

        if not self.is_authorized():
            self.send_json({"error": "unauthorized"}, status=401)
            return

        if is_meeting_say:
            meeting_id = self.path.split("/")[3]
            try:
                text = str(self.read_json().get("text", "")).strip()
            except Exception as error:
                self.send_json({"error": f"invalid_json: {error}"}, status=400)
                return
            if not text:
                self.send_json({"error": "text_required"}, status=400)
                return
            threading.Thread(target=run_owner_meeting_response,
                             args=(meeting_id, text), daemon=True).start()
            self.send_json({"ok": True})
            return

        if self.path == "/push/register":
            try:
                token = str(self.read_json().get("token", "")).strip()
            except Exception as error:
                self.send_json({"error": f"invalid_json: {error}"}, status=400)
                return
            if not re.fullmatch(r"[0-9a-fA-F]{32,200}", token):
                self.send_json({"error": "token_invalid"}, status=400)
                return
            register_push_token(token.lower())
            self.send_json({"ok": True, "apns": apns_config() is not None})
            return

        if self.path == "/tts":
            try:
                body = self.read_json()
                text = str(body.get("text", "")).strip()
                voice = str(body.get("voice", "")).strip()
                # Voice-cost policy: premium (ElevenLabs) ONLY when the caller
                # explicitly declares a revenue-facing use; internal is free.
                tier = str(body.get("tier", "internal")).strip() or "internal"
            except Exception as error:
                self.send_json({"error": f"invalid_json: {error}"}, status=400)
                return
            speech = synthesize_speech(text, voice, tier)
            if speech is None:
                self.send_json({"error": "tts_unavailable"}, status=503)
                return
            audio, mime, engine = speech
            # The app badges "Paid voice" off this header.
            self.send_bytes(audio, mime, headers={"X-Voice-Engine": engine})
            return

        if self.path == "/company/ask":
            try:
                question = str(self.read_json().get("question", "")).strip()
            except Exception as error:
                self.send_json({"error": f"invalid_json: {error}"}, status=400)
                return
            if not question:
                self.send_json({"error": "question_required"}, status=400)
                return
            store = company_module.CompanyStore(COMPANY_STATE_PATH)
            with COMPANY_LOCK:
                state = store.load()
                ask = company_module.new_ask(question)
                state.setdefault("asks", []).insert(0, ask)
                state["asks"] = state["asks"][:20]   # keep the last 20
                store.save(state)
            threading.Thread(target=run_company_ask,
                             args=(ask["id"], question), daemon=True).start()
            self.send_json(ask)
            return

        if self.path == "/company/vault/sync":
            filed = vault_backfill()
            self.send_json({"ok": True, "filed": filed, "vault": str(COMPANY_VAULT_ROOT)})
            return

        if self.path.startswith("/games/"):
            # Games Studio division controls: on/off, pitch a game, record a score.
            try:
                body = self.read_json()
            except Exception:
                body = {}
            with GAMES_LOCK:
                store = games_module.StudioStore(GAMES_STATE_PATH)
                state = store.load()
                if self.path == "/games/start":
                    state["enabled"] = True
                    state["last_tick"] = 0.0
                elif self.path == "/games/halt":
                    state["enabled"] = False
                elif self.path == "/games/concept":
                    games_module.seed_concept(
                        state,
                        str(body.get("title", "")),
                        str(body.get("line", "hyper-casual")),
                        str(body.get("pitch", "")))
                elif self.path == "/games/score":
                    # The cabinet reports the owner's best arcade score.
                    gid, score = str(body.get("id", "")), int(body.get("score", 0))
                    for game in state.get("games", []):
                        if game["id"] == gid:
                            if game.get("score") is None or score > game["score"]:
                                game["score"] = score
                            break
                store.save(state)
            self.send_json(games_module.studio_summary(state))
            return

        if self.path.startswith("/company/"):
            # /company/halt needs no body — never let an empty POST block the
            # kill switch. start/gate parse a body but tolerate an empty one.
            try:
                body = self.read_json()
            except Exception:
                body = {}
            store = company_module.CompanyStore(COMPANY_STATE_PATH)
            with COMPANY_LOCK:
                state = store.load()
                try:
                    if self.path == "/company/start":
                        state["enabled"] = True
                        if "thesis" in body:
                            state["thesis"] = str(body["thesis"])
                        state["last_tick"] = 0.0   # first tick fires within a minute
                    elif self.path == "/company/halt":
                        state["enabled"] = False
                    elif self.path == "/company/iterate":
                        # Owner wants MORE work on a finished project — the same
                        # team continues on the same codebase (features, backend,
                        # RevenueCat, App Store prep…). The loop reopens.
                        company_module.reopen_for_iteration(
                            state,
                            str(body.get("id", "")),
                            str(body.get("instruction", "")),
                        )
                    elif self.path == "/company/directive":
                        # Owner pitched an idea (often a voice memo) — seed it
                        # as an initiative the team researches and brings to gate.
                        company_module.seed_initiative(state, str(body.get("text", "")))
                    elif self.path == "/company/thesis":
                        # Set the investment thesis without toggling the company
                        # on (used by Genesis 2.0 setup).
                        state["thesis"] = str(body.get("thesis", ""))
                    elif self.path == "/company/config":
                        # Owner controls the working hours. quiet_start == quiet_end
                        # means NO quiet hours — the team works around the clock.
                        cfg = state.setdefault("config", {})
                        if "quiet_start" in body:
                            cfg["quiet_start"] = max(0, min(23, int(body["quiet_start"])))
                        if "quiet_end" in body:
                            cfg["quiet_end"] = max(0, min(23, int(body["quiet_end"])))
                        if "interval_minutes" in body:
                            cfg["interval_minutes"] = max(1, int(body["interval_minutes"]))
                    elif self.path == "/company/tasks":
                        # Owner hands the team a Kanban backlog. Accepts a list
                        # ({"tasks": [...]}) or one item ({"text": "..."}).
                        texts = body.get("tasks")
                        if not isinstance(texts, list):
                            texts = [body.get("text", "")]
                        company_module.add_tasks(state, [str(t) for t in texts])
                    elif self.path == "/company/tasks/mode":
                        # The "Kanban List" toggle: on = work the owner's list.
                        company_module.set_task_mode(state, bool(body.get("on", True)))
                    elif self.path == "/company/schedules":
                        state.setdefault("schedules", []).append(
                            company_module.new_schedule(
                                str(body.get("title", "")),
                                str(body.get("kind", "directive")),
                                str(body.get("text", "")),
                                str(body.get("cadence", "daily")),
                                int(body.get("at_hour", 9)),
                                int(body.get("at_minute", 0)),
                                int(body.get("weekday", 0))))
                    elif self.path == "/company/schedule/delete":
                        sid = str(body.get("id", ""))
                        state["schedules"] = [s for s in state.get("schedules", [])
                                              if s.get("id") != sid]
                    elif self.path == "/company/schedule/toggle":
                        sid = str(body.get("id", ""))
                        for s in state.get("schedules", []):
                            if s.get("id") == sid:
                                s["enabled"] = bool(body.get("enabled", not s.get("enabled", True)))
                    elif self.path == "/company/tasks/clear":
                        state["tasks"] = [t for t in state.get("tasks", [])
                                          if t.get("status") != "done"]
                    elif self.path == "/company/task/delete":
                        task_id = str(body.get("id", ""))
                        state["tasks"] = [t for t in state.get("tasks", [])
                                          if t.get("id") != task_id]
                    else:  # /company/gate
                        gated = company_module.apply_gate(
                            state,
                            str(body.get("id", "")),
                            str(body.get("decision", "")),
                            str(body.get("note", "")),
                        )
                        if gated["stage"] == "shipped":
                            # "Ship it" means SHIP: private GitHub repo,
                            # owner's account, link lands back in the app.
                            ship_in_background(gated["id"])
                except KeyError:
                    self.send_json({"error": "initiative_not_found"}, status=404)
                    return
                except ValueError as error:
                    self.send_json({"error": str(error)}, status=400)
                    return
                store.save(state)
                self.send_json(company_summary(state))
            return

        try:
            body = self.read_json()
            message = str(body.get("message", "")).strip()
            requested_profile = str(body.get("profile", "main")).strip() or "main"
            profile = normalize_profile(requested_profile)
            mobile_session_key = str(body.get("session", "")).strip() or session_name_for(profile)
            # Decouple leadership CHATS from the autonomous engine's sessions. Both
            # used "company-<role>"; with the engine running 24/7 the owner's chat
            # collided with an in-progress engine turn and came back empty ("no
            # response"). A "-chat" session keeps the conversation reliable and
            # private to the owner; shared company knowledge is still injected each
            # turn via the context brief.
            if mobile_session_key.startswith("company-") and not mobile_session_key.endswith("-chat"):
                mobile_session_key += "-chat"
            fast = bool(body.get("fast", False))
            skills = str(body.get("skills", "")).strip()
            # Shared brain: interactive company-chat agents read the Constitution
            # too (skipped for voice-fast turns and non-company sessions like the
            # briefing). Covers cold, sync, and warm paths in one place.
            message = compose_chat_message(mobile_session_key, message, fast)
        except Exception as error:
            self.send_json({"error": f"invalid_json: {error}"}, status=400)
            return

        if not message:
            self.send_json({"error": "message_required"}, status=400)
            return

        resume_session_id = self.config_store.session_id(profile, mobile_session_key)
        command = chat_command(message, profile, resume_session_id, fast, skills)

        if self.path == "/chat/stream":
            self.stream_chat(command, profile, mobile_session_key, message=message)
            return

        try:
            result = subprocess.run(
                command,
                text=True,
                capture_output=True,
                timeout=self.timeout,
                check=False,
            )
        except subprocess.TimeoutExpired:
            self.send_json({"error": "timeout", "timeout": self.timeout}, status=504)
            return

        if result.returncode != 0:
            self.send_json(
                {
                    "error": "hermes_failed",
                    "returncode": result.returncode,
                    "stderr": result.stderr[-4000:],
                },
                status=502,
            )
            return

        session_id = extract_session_id(result.stdout) or latest_session_id(profile)
        if session_id:
            self.config_store.save_session(profile, mobile_session_key, session_id)

        self.send_json(
            {
                "reply": clean_reply(result.stdout),
                "profile": profile,
                "session": session_id or mobile_session_key,
                "mobile_session": mobile_session_key,
            }
        )

    def stream_chat(self, command: list[str], profile: str, mobile_session_key: str,
                    message: str = "") -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        self.write_sse({"type": "start", "profile": profile, "session": mobile_session_key})

        # Warm path first: ~3s/turn through the persistent agent. Any failure
        # before completion falls through to the cold CLI below.
        if message and WARM_CLIENT.warm():
            if self.stream_chat_warm(profile, mobile_session_key, message):
                return

        try:
            process = subprocess.Popen(
                command,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=1,
                start_new_session=True,   # own group → kill_tree reaps grandchildren
            )
        except Exception as error:
            self.write_sse({"type": "error", "message": str(error)})
            return

        # Read hermes stdout on a background thread so the main loop can emit
        # SSE keepalives during the cold-start / model "think" gap. Without
        # this the connection sits dead-silent for 15-30s (longer if the model
        # stalls) and the app's quiet-byte timeout fires — the #1 cause of the
        # "it timed out" reports.
        line_queue: queue.Queue = queue.Queue()

        def pump() -> None:
            try:
                assert process.stdout is not None
                for line in process.stdout:
                    line_queue.put(line)
            finally:
                line_queue.put(None)   # EOF sentinel

        reader = threading.Thread(target=pump, daemon=True)
        reader.start()

        output_parts: list[str] = []
        suppress_metadata = False
        started = time.monotonic()
        keepalive_seconds = 8

        try:
            while True:
                try:
                    line = line_queue.get(timeout=keepalive_seconds)
                except queue.Empty:
                    # Silent gap — hold the connection open, enforce the cap.
                    if time.monotonic() - started > self.timeout:
                        kill_tree(process)
                        self.write_sse({"type": "error",
                                        "message": "Hermes took too long to respond. Try again."})
                        return
                    self.write_keepalive()
                    continue
                if line is None:
                    break   # process finished
                output_parts.append(line)
                if is_metadata_line(line):
                    suppress_metadata = True
                    continue
                if suppress_metadata or is_status_line(line):
                    continue
                self.write_sse({"type": "delta", "text": line})

            returncode = process.wait(timeout=5)
        except (BrokenPipeError, ConnectionResetError):
            kill_tree(process)   # the app hung up — don't leak the process tree
            return
        except subprocess.TimeoutExpired:
            kill_tree(process)
            self.write_sse({"type": "error", "message": "Hermes process did not exit cleanly."})
            return

        full_output = "".join(output_parts).strip()
        if returncode != 0:
            self.write_sse(
                {
                    "type": "error",
                    "message": full_output or f"Hermes exited with status {returncode}.",
                    "returncode": returncode,
                }
            )
            return

        session_id = extract_session_id(full_output) or latest_session_id(profile)
        if session_id:
            self.config_store.save_session(profile, mobile_session_key, session_id)

        self.close_connection = True   # stream is finished — release the socket
        self.write_sse(
            {
                "type": "done",
                "reply": clean_reply(full_output),
                "profile": profile,
                "session": session_id or mobile_session_key,
                "mobile_session": mobile_session_key,
            }
        )

    def stream_chat_warm(self, profile: str, mobile_session_key: str, message: str) -> bool:
        """Stream one turn through the warm agent. Returns True when the turn
        completed (done/error already sent); False = caller should cold-fallback.
        Keepalives cover any silent gap, same as the cold path."""
        chunk_queue: queue.Queue = queue.Queue()
        failure: list[Exception] = []

        def pump() -> None:
            try:
                for chunk in WARM_CLIENT.prompt(f"{profile}:{mobile_session_key}", message):
                    chunk_queue.put(chunk)
            except Exception as error:  # noqa: BLE001
                failure.append(error)
            finally:
                chunk_queue.put(None)

        reader = threading.Thread(target=pump, daemon=True)
        reader.start()

        collected: list[str] = []
        started = time.monotonic()
        try:
            while True:
                try:
                    chunk = chunk_queue.get(timeout=8)
                except queue.Empty:
                    if time.monotonic() - started > self.timeout:
                        self.write_sse({"type": "error",
                                        "message": "Hermes took too long to respond. Try again."})
                        return True
                    self.write_keepalive()
                    continue
                if chunk is None:
                    break
                collected.append(chunk)
                self.write_sse({"type": "delta", "text": chunk})
        except (BrokenPipeError, ConnectionResetError):
            return True   # app hung up; nothing more to send

        if failure and not collected:
            print(f"warm chat fell back to cold CLI: {failure[0]}", flush=True)
            return False   # nothing streamed yet — cold path can still serve
        if failure:
            self.write_sse({"type": "error", "message": str(failure[0])})
            return True

        reply = "".join(collected).strip()
        self.write_sse({
            "type": "done",
            "reply": reply,
            "profile": profile,
            "session": mobile_session_key,
            "mobile_session": mobile_session_key,
        })
        self.close_connection = True   # stream is finished — release the socket
        return True

    def write_sse(self, payload: dict[str, Any]) -> None:
        encoded = json.dumps(payload).encode("utf-8")
        self.wfile.write(b"data: ")
        self.wfile.write(encoded)
        self.wfile.write(b"\n\n")
        self.wfile.flush()

    def write_keepalive(self) -> None:
        # SSE comment line: keeps the socket warm during the model's think
        # gap. The app skips any line without a "data: " prefix, so this is
        # invisible to it — it only resets the connection's idle timer.
        self.wfile.write(b": keepalive\n\n")
        self.wfile.flush()

    def is_authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        return header == f"Bearer {self.token}"

    def read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(length)
        return json.loads(data.decode("utf-8"))

    def send_json(self, payload: dict[str, Any], status: int = 200) -> None:
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def send_html(self, html: str, status: int = 200) -> None:
        encoded = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def send_bytes(self, data: bytes, content_type: str, status: int = 200,
                   headers: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args: Any) -> None:
        print(f"{self.client_address[0]} - {format % args}")


def pairing_payload(public_url: str, token: str) -> dict[str, str]:
    return {
        "service": "hermes-mobile-relay",
        "url": public_url,
        "token": token,
        "profile": "main",
    }


def pairing_payload_text(public_url: str, token: str) -> str:
    return json.dumps(pairing_payload(public_url, token), separators=(",", ":"))


def pairing_deep_link(public_url: str, token: str) -> str:
    query = urllib.parse.urlencode({"url": public_url, "token": token, "profile": "main"})
    return f"hermesmobile://pair?{query}"


def pairing_qr_png(payload: dict[str, str]) -> bytes | None:
    try:
        import qrcode  # type: ignore
    except Exception:
        return None

    image = qrcode.make(json.dumps(payload, separators=(",", ":")))
    buffer = io.BytesIO()
    image.save(buffer)
    return buffer.getvalue()


def pairing_page(public_url: str, token: str) -> str:
    payload = pairing_payload_text(public_url, token)
    qr = pairing_qr_png(pairing_payload(public_url, token))
    qr_html = ""
    if qr is not None:
        encoded = base64.b64encode(qr).decode("ascii")
        qr_html = f'<img alt="Hermes Mobile pairing QR" src="data:image/png;base64,{encoded}" />'
    else:
        qr_html = """
        <div class="missing">
          QR image support is not installed on this Mac.<br>
          Install once with <code>python3 -m pip install --user 'qrcode[pil]'</code>, then restart the relay.
        </div>
        """

    return f"""<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Hermes Mobile Pairing</title>
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #f5f6f8; color: #16171a; margin: 0; padding: 28px; }}
    main {{ max-width: 560px; margin: 0 auto; background: white; border-radius: 12px; padding: 24px; box-shadow: 0 18px 50px rgba(0,0,0,.08); }}
    h1 {{ margin: 0 0 8px; font-size: 28px; }}
    p {{ color: #696d75; line-height: 1.45; }}
    img {{ display: block; width: min(320px, 100%); height: auto; margin: 22px auto; image-rendering: pixelated; }}
    pre {{ white-space: pre-wrap; word-break: break-all; background: #f0f2f4; border-radius: 8px; padding: 12px; font-size: 12px; }}
    .missing {{ background: #fff4df; border-radius: 8px; padding: 14px; color: #7a4a00; margin: 18px 0; }}
    code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}
  </style>
</head>
<body>
  <main>
    <h1>Pair Hermes Mobile</h1>
    <p>Open Hermes Mobile on your iPhone, go to Gateway > Connect to this Mac > Scan Pairing Code, then scan this code.</p>
    {qr_html}
    <p>Pairing payload:</p>
    <pre>{payload}</pre>
  </main>
</body>
</html>"""


def main() -> None:
    maybe_reexec_with_hermes_python()

    parser = argparse.ArgumentParser(description="Run the Hermes Mobile development relay")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", default=8787, type=int)
    parser.add_argument("--reset-token", action="store_true")
    parser.add_argument("--timeout", default=240, type=int)
    args = parser.parse_args()

    token = load_or_create_token(args.reset_token)
    RelayHandler.token = token
    RelayHandler.timeout = args.timeout

    display_url = f"http://{local_ip()}:{args.port}"
    RelayHandler.public_url = display_url
    print("\nHermes Mobile Relay", flush=True)
    print("===================", flush=True)
    print(f"URL:   {display_url}", flush=True)
    print(f"Token: {token}", flush=True)
    print(f"Pair:  {display_url}/pair", flush=True)
    print("\nEnter these in Hermes Mobile > Gateway > Mac Relay.", flush=True)
    print("Keep this terminal open while using the iPhone app.\n", flush=True)

    # Advertise over Bonjour so the app finds this Mac automatically —
    # no IP, no QR, survives network changes. Uses macOS's built-in dns-sd.
    bonjour = None
    try:
        bonjour = subprocess.Popen(
            ["dns-sd", "-R", "Hermes Relay", "_hermes-relay._tcp", "local",
             str(args.port), f"token={token}", "profile=main"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        print("Bonjour: advertising as _hermes-relay._tcp (auto-discovery on)\n", flush=True)
    except Exception as exc:  # noqa: BLE001 — discovery is best-effort
        print(f"Bonjour advertising unavailable: {exc}\n", flush=True)

    heartbeat = threading.Thread(target=company_heartbeat_loop, daemon=True)
    heartbeat.start()
    print("Company heartbeat: running (60s check, tick interval from config)\n", flush=True)

    warmup = threading.Thread(target=prewarm_hermes, daemon=True)
    warmup.start()
    print("Warm Hermes: warming up in background (~40s)…\n", flush=True)

    # …and KEEP it warm: if the warm agent ever dies (timeout, crash), this
    # loop revives it within a minute instead of leaving every chat cold.
    keeper = threading.Thread(target=warm_keeper_loop, daemon=True)
    keeper.start()

    server = ThreadingHTTPServer((args.host, args.port), RelayHandler)
    try:
        server.serve_forever()
    finally:
        if bonjour is not None:
            bonjour.terminate()


if __name__ == "__main__":
    main()
