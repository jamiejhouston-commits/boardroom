# Scripts/hermes_watchdog.py
"""Self-healing ops for the Boardroom relay — the 3am pager nobody carries.

Run by launchd every 5 minutes (com.boardroom.watchdog). Three jobs:
1. Relay down?  kickstart com.boardroom.relay (launchd's KeepAlive misses a
   wedged-but-alive process; the /health probe doesn't).
2. Tailscale stopped (the post-crash failure mode)?  reopen the app — and
   restart the relay too, so local_ip() re-picks the tailnet address.
3. Nightly state backups: one dated folder per day under ~/.hermes/backups,
   pruned to the newest 14 — a corrupted mobile-company.json is one bad write
   away from erasing the whole company.

stdlib only; every action logs one honest line to ~/.hermes/watchdog.log.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path

RELAY_HEALTH_URL = "http://127.0.0.1:8787/health"
RELAY_LAUNCHD_LABEL = "com.boardroom.relay"
TAILSCALE_BIN = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

HERMES_DIR = Path.home() / ".hermes"
BACKUP_ROOT = HERMES_DIR / "backups"
LOG_PATH = HERMES_DIR / "watchdog.log"
LOG_CAP_BYTES = 256 * 1024
KEEP_BACKUPS = 14
# The state files worth resurrecting after a disaster. Missing ones are skipped.
STATE_FILES = ("mobile-company.json", "mobile-games-studio.json",
               "mobile-relay.json", "mobile-installs.json", "mobile-calls.json")


def relay_healthy(url: str = RELAY_HEALTH_URL, timeout: int = 10) -> bool:
    """/health answers ok:true → the relay is genuinely serving, not just alive."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return bool(json.loads(response.read().decode()).get("ok"))
    except Exception:  # noqa: BLE001 — any failure mode means "not healthy"
        return False


def heal_relay() -> None:
    subprocess.run(["launchctl", "kickstart", "-k",
                    f"gui/{os.getuid()}/{RELAY_LAUNCHD_LABEL}"],
                   capture_output=True, timeout=30, check=False)


def tailscale_running() -> bool:
    """BackendState == Running. A missing CLI reads as running — a Mac without
    Tailscale installed must not be 'healed' into launching nothing forever."""
    if not Path(TAILSCALE_BIN).exists():
        return True
    try:
        status = subprocess.run([TAILSCALE_BIN, "status", "--json"],
                                capture_output=True, text=True, timeout=15,
                                check=False)
        return json.loads(status.stdout or "{}").get("BackendState") == "Running"
    except Exception:  # noqa: BLE001
        return True   # unknown ≠ stopped; don't thrash the app open


def heal_tailscale() -> None:
    subprocess.run(["open", "-a", "Tailscale"],
                   capture_output=True, timeout=30, check=False)


def backup_today(now: float | None = None, hermes_dir: Path = HERMES_DIR,
                 backup_root: Path = BACKUP_ROOT) -> Path | None:
    """Copy the state files into backups/<YYYY-MM-DD>/ once per day.
    Returns the folder when a backup was made, None when today's exists."""
    date = time.strftime("%Y-%m-%d", time.localtime(now or time.time()))
    folder = backup_root / date
    if folder.exists():
        return None
    folder.mkdir(parents=True)
    for name in STATE_FILES:
        source = hermes_dir / name
        if source.is_file():
            shutil.copy2(source, folder / name)
    return folder


def prune_backups(backup_root: Path = BACKUP_ROOT,
                  keep: int = KEEP_BACKUPS) -> list[str]:
    """Drop everything but the newest `keep` dated folders. Returns the names
    removed (dated-name sort == chronological sort)."""
    if not backup_root.is_dir():
        return []
    dated = sorted(p for p in backup_root.iterdir() if p.is_dir())
    removed = []
    for folder in dated[:-keep] if keep else dated:
        shutil.rmtree(folder, ignore_errors=True)
        removed.append(folder.name)
    return removed


def log(line: str) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with LOG_PATH.open("a") as handle:
        handle.write(f"{stamp} {line}\n")
    # ponytail: crude size cap — halve the file when it outgrows the cap.
    if LOG_PATH.stat().st_size > LOG_CAP_BYTES:
        text = LOG_PATH.read_text()
        LOG_PATH.write_text(text[len(text) // 2:])


def main() -> None:
    actions = []
    if not tailscale_running():
        heal_tailscale()
        time.sleep(10)           # give the backend a moment before the relay re-binds
        heal_relay()             # relay must re-pick the tailnet IP
        actions.append("tailscale stopped → reopened app + kickstarted relay")
    elif not relay_healthy():
        heal_relay()
        actions.append("relay unhealthy → kickstarted")
    folder = backup_today()
    if folder is not None:
        actions.append(f"backed up state → {folder.name}")
        removed = prune_backups()
        if removed:
            actions.append(f"pruned old backups: {', '.join(removed)}")
    log("; ".join(actions) if actions else "ok")


if __name__ == "__main__":
    main()
