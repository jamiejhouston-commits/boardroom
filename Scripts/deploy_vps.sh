#!/bin/bash
# Deploy the Boardroom relay (+ company engine + neural voices) to your
# Hostinger VPS so it runs 24/7 — independent of your Mac.
#
# Run this ON YOUR MAC:   bash Scripts/deploy_vps.sh
#
# Prereqs on the VPS (already true per setup): hermes, python3, git installed;
# root SSH key access from this Mac; port 8787 open.
set -euo pipefail

# Your VPS target. Set it via the VPS env var, or a gitignored Scripts/.vps.local
# file containing e.g.  root@1.2.3.4  (keeps your server IP out of the repo).
VPS="${VPS:-$(cat "$(dirname "$0")/.vps.local" 2>/dev/null || echo root@YOUR_VPS_IP)}"
HOST_IP="${HOST_IP:-${VPS#*@}}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_DIR="/root/boardroom"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

bold "1/6  Checking the VPS is reachable…"
ssh -o ConnectTimeout=10 -o BatchMode=yes "$VPS" 'echo "  connected as $(whoami) on $(hostname)"'

bold "2/6  Copying relay + engine to $REMOTE_DIR/Scripts …"
ssh "$VPS" "mkdir -p $REMOTE_DIR/Scripts"
scp -q "$REPO_DIR/Scripts/hermes_mobile_relay.py" \
       "$REPO_DIR/Scripts/hermes_company.py" \
       "$REPO_DIR/Scripts/hermes_acp_client.py" \
       "$VPS:$REMOTE_DIR/Scripts/"
echo "  copied."

bold "3/6  Installing the free neural voices (Piper) on the VPS…"
ssh "$VPS" 'bash -s' <<'REMOTE'
set -e
if [ ! -x "$HOME/.hermes/piper-venv/bin/piper" ]; then
  python3 -m venv "$HOME/.hermes/piper-venv"
  "$HOME/.hermes/piper-venv/bin/pip" install -q --timeout 180 piper-tts
fi
mkdir -p "$HOME/.hermes/piper-voices"
cd "$HOME/.hermes/piper-voices"
"$HOME/.hermes/piper-venv/bin/python" -m piper.download_voices \
  en_US-ryan-medium en_US-joe-medium en_GB-alan-medium en_US-amy-medium \
  en_US-kathleen-low en_GB-jenny_dioco-medium en_US-lessac-medium 2>/dev/null || true
echo "  voices ready: $(ls "$HOME/.hermes/piper-voices"/*.onnx 2>/dev/null | wc -l) installed"
REMOTE

bold "4/6  Verifying Hermes is authenticated on the VPS…"
if ssh "$VPS" 'cd /tmp && timeout 60 hermes chat -Q --source mobile -q "reply with: OK" 2>&1 | tail -1' | grep -qi "ok"; then
  echo "  Hermes auth: working ✓"
else
  bold "  ⚠️  Hermes is NOT authenticated on the VPS."
  echo "  Do this once, then re-run this script:"
  echo "      ssh $VPS"
  echo "      hermes model        # pick your model + log in via the browser link"
  echo "  (Remember: that login is single-machine — dedicate it to the VPS.)"
  exit 1
fi

bold "5/6  Installing the relay as a 24/7 service (systemd)…"
ssh "$VPS" "bash -s '$REMOTE_DIR'" <<'REMOTE'
set -e
REMOTE_DIR="$1"
PY="$(command -v python3)"
cat > /etc/systemd/system/boardroom-relay.service <<UNIT
[Unit]
Description=Boardroom relay (Hermes Mobile)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$REMOTE_DIR
ExecStart=$PY -u $REMOTE_DIR/Scripts/hermes_mobile_relay.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
# Public IP: never serve the token over the open /pair page. Pair with the
# URL + token directly (printed by this script) instead.
Environment=HERMES_PAIR_WINDOW=0

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable boardroom-relay
systemctl restart boardroom-relay
sleep 3
systemctl is-active boardroom-relay && echo "  service: active ✓"
# Make sure the firewall allows the relay port.
command -v ufw >/dev/null && ufw status | grep -q active && ufw allow 8787 >/dev/null 2>&1 || true
REMOTE

bold "6/6  Your pairing details (enter these in the app manually):"
TOKEN="$(ssh "$VPS" "python3 - <<'PY'
import json, pathlib
print(json.load(open(pathlib.Path.home()/'.hermes'/'mobile-relay.json'))['token'])
PY" 2>/dev/null || echo "")"
echo "  Relay URL :  http://$HOST_IP:8787"
[ -n "$TOKEN" ] && echo "  Token     :  $TOKEN" || echo "  Token     :  (read it with: ssh $VPS 'cat ~/.hermes/mobile-relay.json')"
echo ""
bold "Done — the company now runs on the VPS 24/7. Your Mac can sleep."
echo "In the app: Gateway → Mac Relay → enter the URL + token above → Save → Test."
