#!/bin/bash
# local-mantis Phase-1 capture — runs IN a crabbox box. Reuses the real Mantis engine's
# capture routines (window geometry + crop + motion-GIF), wired to our payload + in-box gateway.
# Produces, per LABEL: <LABEL>.png (full), <LABEL>-window.png (cropped message column),
# <LABEL>-motion.mp4, <LABEL>-motion.gif (cropped telegram-window variant).
#
# Args: $1=payload.json  $2=LABEL  $3=SCENARIO_TEXT  [$4=extra openclaw.json fragment for streaming]
# Assumes: PR already built at /opt/openclaw (host orchestrator does the build/checkout).
#          tdata/pairing already restored under /tmp/cap (driver dir + desktop workdir).
set -uo pipefail
CAP=/tmp/cap
PAY="${1:?payload}"; LABEL="${2:?label}"; SCENARIO="${3:?scenario text}"; STREAMFRAG="${4:-\"mode\": \"progress\", \"progress\": { \"commentary\": true, \"toolProgress\": true }}"
CHAT="${MANTIS_CHAT:-8685483103}"   # bot DM by default; set MANTIS_CHAT to a -100 group for deep-link view
cd /opt/openclaw

# ---- Mantis engine constants (from scripts/e2e/telegram-user-crabbox-proof.ts) ----
WIN_X=635; WIN_Y=40; WIN_W=650; WIN_H=1000          # TELEGRAM_PROOF_WINDOW
CROP="crop=430:1000:855:40"                          # TELEGRAM_PROOF_CROP (x=win.x+220)
SCALE="scale=430:-2:flags=lanczos"
FPS="${MANTIS_FPS:-12}"
RECSECS="${MANTIS_RECSECS:-40}"

# ---- cleanup (orphan-safe: patterns live in this file so they can't self-match) ----
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill "$pid" 2>/dev/null; done
sleep 2
pkill -f "claude --output-format stream-json" 2>/dev/null||true
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
pkill -x Telegram 2>/dev/null||true; pkill -x Xvfb 2>/dev/null||true; sleep 3
mkdir -p "$CAP/state"

SUT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sutToken'])" "$PAY")
[ -z "$SUT" ] && { echo "FAIL: no sutToken"; exit 1; }
echo "[mantis] sha=$(git rev-parse --short HEAD) label=$LABEL chat=$CHAT"

# ---- isolated SUT config (in-box gateway, bot from payload, claude-cli backend) ----
cat > "$CAP/openclaw.json" <<CONF
{ "agents": { "defaults": { "model": "claude-cli/claude-sonnet-4-6", "thinkingDefault": "medium", "workspace": "/opt/openclaw",
  "cliBackends": { "claude-cli": { "command": "claude", "input": "stdin", "maxPromptArgChars": 1, "sessionMode": "always", "systemPromptMode": "replace",
    "args": ["-p","--output-format","stream-json","--include-partial-messages","--verbose","--setting-sources","user","--permission-mode","bypassPermissions"] } } } },
  "auth": { "order": { "anthropic": ["anthropic:claude-cli"] } },
  "gateway": { "port": 18789, "mode": "local", "bind": "loopback", "auth": { "mode": "token", "token": "test-token" } },
  "channels": { "telegram": { "enabled": true, "dmPolicy": "pairing",
    "botToken": { "id": "TELEGRAM_BOT_TOKEN", "provider": "default", "source": "env" },
    "streaming": { $STREAMFRAG } } },
  "tools": { "profile": "coding", "exec": { "security": "full", "ask": "off" } },
  "plugins": { "entries": { "anthropic": {"enabled": true}, "browser": {"enabled": false}, "codex": {"enabled": false} } } }
CONF

OPENCLAW_CONFIG_PATH="$CAP/openclaw.json" OPENCLAW_STATE_DIR="$CAP/state" \
TELEGRAM_BOT_TOKEN="$SUT" OPENCLAW_GATEWAY_TOKEN=test-token \
  pnpm openclaw gateway --port 18789 --allow-unconfigured > "$CAP/gw-$LABEL.log" 2>&1 &
sleep 14
grep -aiE "ready|error" "$CAP/gw-$LABEL.log" | tail -2

# ---- desktop (logged-in from restored tdata), Mantis window geometry ----
Xvfb :99 -screen 0 1300x1080x24 > "$CAP/xvfb.log" 2>&1 & sleep 2
DISPLAY=:99 dbus-launch /opt/Telegram/Telegram -workdir "$CAP/tdata" > "$CAP/tg.log" 2>&1 & sleep 18
WIN=$(DISPLAY=:99 wmctrl -lxG 2>/dev/null | awk 'tolower($0) ~ /telegram/ {print $1; exit}')
if [ -n "$WIN" ]; then
  DISPLAY=:99 wmctrl -ir "$WIN" -b remove,maximized_vert,maximized_horz,fullscreen 2>/dev/null
  DISPLAY=:99 wmctrl -ir "$WIN" -e 0,$WIN_X,$WIN_Y,$WIN_W,$WIN_H 2>/dev/null
fi
# open the chat (bot DM resolve, or group deep-link if MANTIS_VIEW_LINK set)
if [ -n "${MANTIS_VIEW_LINK:-}" ]; then
  DISPLAY=:99 timeout 5 /opt/Telegram/Telegram -workdir "$CAP/tdata" "$MANTIS_VIEW_LINK" >/dev/null 2>&1 || true
else
  DISPLAY=:99 /opt/Telegram/Telegram -workdir "$CAP/tdata" "tg://resolve?domain=JeeevesOpenClawTelegram2bot" >/dev/null 2>&1 &
fi
sleep 6

# ---- record while driving the scenario ----
DISPLAY=:99 ffmpeg -y -loglevel warning -f x11grab -video_size 1300x1080 -framerate "$FPS" -i :99 -t "$RECSECS" "$CAP/$LABEL-raw.mp4" > "$CAP/ffmpeg-$LABEL.log" 2>&1 &
FF=$!
sleep 3
export TELEGRAM_USER_DRIVER_STATE_DIR="$CAP/driver"
python3 scripts/e2e/telegram-user-driver.py chats --json >/dev/null 2>&1 || true
python3 scripts/e2e/telegram-user-driver.py send --chat "$CHAT" --text "$SCENARIO" --timeout-ms 60000 >/dev/null 2>&1
python3 scripts/e2e/telegram-user-driver.py wait --chat "$CHAT" --from-bot "$CHAT" --timeout-ms 120000 > "$CAP/observed-$LABEL.json" 2>&1 || true
wait $FF 2>/dev/null

# ---- stills: full + cropped message column (Mantis crop) ----
DISPLAY=:99 scrot "$CAP/$LABEL.png" 2>/dev/null || true
ffmpeg -y -loglevel error -i "$CAP/$LABEL.png" -vf "$CROP" "$CAP/$LABEL-window.png" >/dev/null 2>&1 || true

# ---- motion: cropped telegram-window mp4 + palette gif (Mantis routine) ----
ffmpeg -y -loglevel error -i "$CAP/$LABEL-raw.mp4" -vf "$CROP,$SCALE" -pix_fmt yuv420p "$CAP/$LABEL-motion.mp4" >/dev/null 2>&1 || true
ffmpeg -y -loglevel error -i "$CAP/$LABEL-raw.mp4" -filter_complex "$CROP,fps=$FPS,$SCALE,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" "$CAP/$LABEL-motion.gif" >/dev/null 2>&1 || true

for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill "$pid" 2>/dev/null; done
pkill -x Telegram 2>/dev/null||true; pkill -x Xvfb 2>/dev/null||true
echo "[mantis] DONE $LABEL: png=$(stat -c%s "$CAP/$LABEL.png" 2>/dev/null||echo 0) window=$(stat -c%s "$CAP/$LABEL-window.png" 2>/dev/null||echo 0) gif=$(stat -c%s "$CAP/$LABEL-motion.gif" 2>/dev/null||echo 0) mp4=$(stat -c%s "$CAP/$LABEL-motion.mp4" 2>/dev/null||echo 0)"
