#!/bin/bash
# Boardroom one-command setup — run this on the Mac that has Hermes installed:
#
#     ./Scripts/setup.sh
#
# Starts the relay, keeps your agent warm, and opens the pairing QR page.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/Library/Logs/boardroom-relay.log"
PORT=8787

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

# 1. Hermes must be installed and authenticated.
if ! command -v hermes >/dev/null 2>&1; then
  bold "Hermes Agent is not installed."
  echo "Install it first: https://hermes-agent.nousresearch.com — then re-run this script."
  exit 1
fi

# 2. Prefer the Hermes venv python (has the QR library); fall back to python3.
PY="$HOME/.hermes/hermes-agent/venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"

# 3. Restart the relay cleanly.
pkill -f hermes_mobile_relay.py 2>/dev/null || true
sleep 1
mkdir -p "$(dirname "$LOG")"
nohup "$PY" -u "$REPO_DIR/Scripts/hermes_mobile_relay.py" >> "$LOG" 2>&1 &
disown

# 4. Wait for it to come up.
printf 'Starting the Boardroom relay'
for _ in $(seq 1 20); do
  if curl -s -m 2 "http://127.0.0.1:$PORT/health" | grep -q '"ok": true'; then
    echo " — up."
    break
  fi
  printf '.'
  sleep 1
done

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
PAIR_URL="http://$LAN_IP:$PORT/pair"

echo ""
bold "Boardroom relay is running."
echo "  Pairing page:  $PAIR_URL"
echo "  Logs:          $LOG"
echo ""
echo "On your iPhone: open the Boardroom app → Gateway → Scan Pairing Code,"
echo "then scan the QR on the page that just opened."
echo ""
echo "Notes:"
echo "  • First chat after startup takes ~40s while your agent warms up — after"
echo "    that, replies arrive in ~2-3 seconds."
echo "  • Keep this Mac awake; re-run this script any time to restart the relay."

open "$PAIR_URL" 2>/dev/null || true
