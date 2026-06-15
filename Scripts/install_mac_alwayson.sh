#!/bin/bash
# Make the Boardroom relay always-on on this Mac:
#   • auto-starts at login and restarts if it ever crashes (launchd)
#   • keeps the Mac awake while it runs (caffeinate) so it never sleeps
#     out from under the app
#
# Run once:   bash Scripts/install_mac_alwayson.sh
# Uninstall:  launchctl unload ~/Library/LaunchAgents/com.boardroom.relay.plist
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELAY="$REPO_DIR/Scripts/hermes_mobile_relay.py"
PY="$HOME/.hermes/hermes-agent/venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"
PLIST="$HOME/Library/LaunchAgents/com.boardroom.relay.plist"
LOG="$HOME/Library/Logs/boardroom-relay.log"

# launchd runs with a stripped PATH, so the relay can't find `hermes`, `nice`,
# `git`, or `gh`. Carry a real PATH that includes wherever hermes actually is.
HERMES_DIR="$(dirname "$(command -v hermes 2>/dev/null || echo /usr/local/bin/hermes)")"
SERVICE_PATH="$HERMES_DIR:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"

# Stop any relay we started by hand so the managed one owns port 8787.
pkill -f hermes_mobile_relay.py 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
sleep 1

# caffeinate -s wraps the relay: the Mac won't system-sleep while it runs
# (effective on AC power). KeepAlive restarts the relay if it dies;
# RunAtLoad starts it at login and after a reboot.
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.boardroom.relay</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-s</string>
        <string>$PY</string>
        <string>-u</string>
        <string>$RELAY</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$REPO_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$SERVICE_PATH</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLISTEOF

launchctl load -w "$PLIST"
sleep 3

bold "Checking the relay came up…"
if curl -s -m 5 http://127.0.0.1:8787/health | grep -q '"ok": true'; then
  echo "  Relay: running and always-on ✓ (auto-starts at login, kept awake)"
else
  echo "  Relay didn't answer yet — give it ~40s to warm, then: curl localhost:8787/health"
fi

bold "Done."
echo "  • The relay restarts automatically and the Mac won't sleep while it runs."
echo "  • Keep this Mac plugged in and logged in for true 24/7."
echo "  • Logs: $LOG"
echo "  • To stop always-on:  launchctl unload $PLIST"
