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
import socket
import subprocess
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

COMPANY_STATE_PATH = Path.home() / ".hermes" / "mobile-company.json"
COMPANY_ARTIFACTS_ROOT = Path.home() / ".hermes" / "company" / "initiatives"
COMPANY_LOCK = threading.Lock()

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
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(data, indent=2))
        self.path.chmod(0o600)

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
                 fast: bool = False) -> list[str]:
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
    if resume_session_id:
        command.extend(["--resume", resume_session_id])
    command.extend(["-q", message])
    return command


def company_chat_command(message: str, role: str, resume_session_id: str | None) -> list[str]:
    command = ["hermes", "chat", "-Q", "--source", "mobile"]
    if resume_session_id:
        command.extend(["--resume", resume_session_id])
    command.extend(["-q", message])
    return command


def company_cli_runner(role: str, prompt: str) -> str:
    """runner(role, prompt) for the company engine: one Hermes CLI call per
    turn, with a persistent session per role so agents keep their memory."""
    store = RelayConfigStore(CONFIG_PATH)
    session_key = f"company-{role}"
    resume = store.session_id("default", session_key)
    result = subprocess.run(
        company_chat_command(prompt, role, resume),
        text=True, capture_output=True, timeout=600, check=False,
    )
    output = (result.stdout or "") + "\n" + (result.stderr or "")
    session_id = extract_session_id(output) or latest_session_id("default")
    if session_id:
        store.save_session("default", session_key, session_id)
    if result.returncode != 0:
        raise RuntimeError(f"hermes exited {result.returncode} for role {role}")
    return clean_reply(result.stdout)


def company_summary(state: dict) -> dict:
    """State for the app: everything except the bulky per-stage minutes."""
    slim = []
    for init in state["initiatives"]:
        item = {k: v for k, v in init.items() if k != "minutes"}
        slim.append(item)
    return {
        "enabled": state["enabled"],
        "thesis": state["thesis"],
        "config": state["config"],
        "last_tick": state["last_tick"],
        "initiatives": slim,
    }


def company_heartbeat_loop() -> None:
    store = company_module.CompanyStore(COMPANY_STATE_PATH)
    while True:
        try:
            with COMPANY_LOCK:
                state = store.load()
                events = company_module.tick(state, company_cli_runner, COMPANY_ARTIFACTS_ROOT)
                store.save(state)
            for event in events:
                print(f"company - {event}", flush=True)
        except Exception as error:  # noqa: BLE001 — the pulse must survive anything
            print(f"company - heartbeat error: {error}", flush=True)
        time.sleep(60)


class RelayHandler(BaseHTTPRequestHandler):
    token = ""
    timeout = 240
    public_url = ""
    config_store = RelayConfigStore(CONFIG_PATH)

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(
                {
                    "ok": True,
                    "service": "hermes-mobile-relay",
                    "profiles": discover_profiles(),
                }
            )
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
        self.send_json({"error": "not_found"}, status=404)

    def do_POST(self) -> None:
        if self.path not in {"/chat", "/chat/stream", "/company/start", "/company/halt", "/company/gate"}:
            self.send_json({"error": "not_found"}, status=404)
            return

        if not self.is_authorized():
            self.send_json({"error": "unauthorized"}, status=401)
            return

        if self.path.startswith("/company/"):
            try:
                body = self.read_json()
            except Exception as error:
                self.send_json({"error": f"invalid_json: {error}"}, status=400)
                return
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
                    else:  # /company/gate
                        company_module.apply_gate(
                            state,
                            str(body.get("id", "")),
                            str(body.get("decision", "")),
                            str(body.get("note", "")),
                        )
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
            fast = bool(body.get("fast", False))
        except Exception as error:
            self.send_json({"error": f"invalid_json: {error}"}, status=400)
            return

        if not message:
            self.send_json({"error": "message_required"}, status=400)
            return

        resume_session_id = self.config_store.session_id(profile, mobile_session_key)
        command = chat_command(message, profile, resume_session_id, fast)

        if self.path == "/chat/stream":
            self.stream_chat(command, profile, mobile_session_key)
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

    def stream_chat(self, command: list[str], profile: str, mobile_session_key: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        self.write_sse({"type": "start", "profile": profile, "session": mobile_session_key})

        try:
            process = subprocess.Popen(
                command,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=1,
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
                        process.kill()
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
            process.kill()   # the app hung up — don't leak the process
            return
        except subprocess.TimeoutExpired:
            process.kill()
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

        self.write_sse(
            {
                "type": "done",
                "reply": clean_reply(full_output),
                "profile": profile,
                "session": session_id or mobile_session_key,
                "mobile_session": mobile_session_key,
            }
        )

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

    def send_bytes(self, data: bytes, content_type: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
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

    server = ThreadingHTTPServer((args.host, args.port), RelayHandler)
    try:
        server.serve_forever()
    finally:
        if bonjour is not None:
            bonjour.terminate()


if __name__ == "__main__":
    main()
