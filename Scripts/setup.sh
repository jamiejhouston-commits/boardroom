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

# 2b. Free neural voices (Piper) — optional but makes agents sound human.
PIPER_VENV="$HOME/.hermes/piper-venv"
if [ ! -x "$PIPER_VENV/bin/piper" ]; then
  bold "Installing free neural voices (one-time, ~2 min)…"
  mkdir -p "$HOME/.hermes/piper-voices"
  ( "$PY" -m venv "$PIPER_VENV" 2>/dev/null && \
    "$PIPER_VENV/bin/pip" install -q --timeout 120 piper-tts 2>/dev/null && \
    cd "$HOME/.hermes/piper-voices" && \
    "$PIPER_VENV/bin/python" -m piper.download_voices \
      en_US-ryan-medium en_US-joe-medium en_GB-alan-medium en_US-amy-medium \
      en_US-kathleen-low en_GB-jenny_dioco-medium en_US-lessac-medium 2>/dev/null ) \
    && echo "  Neural voices installed." \
    || echo "  (Voices skipped — agents will use the on-device voice. Re-run setup to retry.)"
fi

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
