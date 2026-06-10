#!/bin/bash
# CANONICAL local-mantis capture (runs IN a crabbox box). Reuses the real Mantis engine's
# geometry/crop/motion routines + the supergroup deep-link framing. All hard-won lessons are
# baked in as code (don't re-hand-roll). Host wrapper owns: payload staging, FRESH claude
# creds (they expire — re-copy before each run), artifact export.
# Args: $1=payload  $2=LABEL  $3=SCENARIO  $4=STREAMKEY(persist-on|persist-off|plain)
set -uo pipefail
CAP=/tmp/cap; PAY="${1:?}"; LABEL="${2:?}"; SCENARIO="${3:?}"; SK="${4:-persist-on}"
GID=-1003900553563; CHANNEL=3900553563                 # supergroup -100 id; channel = id sans -100
WIN_X=635; WIN_Y=40; WIN_W=650; WIN_H=1000             # TELEGRAM_PROOF_WINDOW (engine)
CROP="crop=430:1000:855:40"; SCALE="scale=430:-2:flags=lanczos"; FPS=12; RECSECS=48
cd /opt/openclaw
# --- orphan cleanup (patterns live in this file => can't self-match) ---
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill "$pid" 2>/dev/null; done
sleep 2; pkill -f "claude --output-format stream-json" 2>/dev/null||true
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
pkill -x Telegram 2>/dev/null||true; pkill -x openbox 2>/dev/null||true; pkill -x Xvfb 2>/dev/null||true; sleep 3; mkdir -p "$CAP/state"
SUT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sutToken'])" "$PAY")
BOTUID=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sutToken'].split(':')[0])" "$PAY")
case "$SK" in
  persist-on)  STREAM='"mode":"progress","progress":{"commentary":true,"toolProgress":true,"persistProgress":true}';;
  persist-off) STREAM='"mode":"progress","progress":{"commentary":true,"toolProgress":true,"persistProgress":false}';;
  *)           STREAM='"mode":"partial"';;
esac
cat > "$CAP/openclaw.json" <<CONF
{ "agents": { "defaults": { "model": "claude-cli/claude-sonnet-4-6", "thinkingDefault": "medium", "workspace": "/opt/openclaw",
  "cliBackends": { "claude-cli": { "command": "claude", "input": "stdin", "maxPromptArgChars": 1, "sessionMode": "always", "systemPromptMode": "replace",
    "args": ["-p","--output-format","stream-json","--include-partial-messages","--verbose","--setting-sources","user","--permission-mode","bypassPermissions"] } } } },
  "auth": { "order": { "anthropic": ["anthropic:claude-cli"] } },
  "gateway": { "port": 18789, "mode": "local", "bind": "loopback", "auth": { "mode": "token", "token": "test-token" } },
  "channels": { "telegram": { "enabled": true, "groupPolicy": "open", "groups": { "$GID": { "requireMention": false } },
    "botToken": { "id": "TELEGRAM_BOT_TOKEN", "provider": "default", "source": "env" }, "streaming": { $STREAM } } },
  "tools": { "profile": "coding", "exec": { "security": "full", "ask": "off" } },
  "plugins": { "entries": { "anthropic": {"enabled": true}, "browser": {"enabled": false}, "codex": {"enabled": false} } } }
CONF
OPENCLAW_CONFIG_PATH="$CAP/openclaw.json" OPENCLAW_STATE_DIR="$CAP/state" TELEGRAM_BOT_TOKEN="$SUT" OPENCLAW_GATEWAY_TOKEN=test-token \
  pnpm openclaw gateway --port 18789 --allow-unconfigured > "$CAP/gw-$LABEL.log" 2>&1 &
sleep 14; grep -aiE "ready|error" "$CAP/gw-$LABEL.log"|tail -2
# --- desktop under a WM, geometry applied BEFORE recording ---
Xvfb :99 -screen 0 1300x1080x24 >/dev/null 2>&1 & sleep 2
DISPLAY=:99 openbox >/dev/null 2>&1 & sleep 1
DISPLAY=:99 dbus-launch /opt/Telegram/Telegram -workdir "$CAP/tdata" >/dev/null 2>&1 & sleep 18
apply_geom(){ local w; w=$(DISPLAY=:99 wmctrl -lxG 2>/dev/null | awk 'tolower($0) ~ /telegram/ {print $1; exit}'); [ -n "$w" ] && { DISPLAY=:99 wmctrl -ir "$w" -b remove,maximized_vert,maximized_horz,fullscreen 2>/dev/null; DISPLAY=:99 wmctrl -ir "$w" -e 0,$WIN_X,$WIN_Y,$WIN_W,$WIN_H 2>/dev/null; }; }
apply_geom; sleep 1
DISPLAY=:99 /opt/Telegram/Telegram -workdir "$CAP/tdata" "tg://privatepost?channel=$CHANNEL&post=1" >/dev/null 2>&1 & sleep 5
apply_geom; sleep 1                                    # re-assert after the chat opens
export TELEGRAM_USER_DRIVER_STATE_DIR="$CAP/driver"
DISPLAY=:99 ffmpeg -y -loglevel warning -f x11grab -video_size 1300x1080 -framerate $FPS -i :99 -t $RECSECS "$CAP/$LABEL-raw.mp4" >/dev/null 2>&1 & FF=$!
sleep 3
# FRESH session, then the scenario; wait for the BOT's reply (sender = bot user id, not the chat id)
python3 scripts/e2e/telegram-user-driver.py send --chat "$GID" --text "/new" --timeout-ms 30000 >/dev/null 2>&1; sleep 8
python3 scripts/e2e/telegram-user-driver.py send --chat "$GID" --text "$SCENARIO" --timeout-ms 60000 >/dev/null 2>&1
python3 scripts/e2e/telegram-user-driver.py wait --chat "$GID" --from-bot "$BOTUID" --timeout-ms 120000 > "$CAP/observed-$LABEL.json" 2>&1 || true
wait $FF 2>/dev/null
MID=$(python3 -c "import json;d=json.load(open('$CAP/observed-$LABEL.json'));m=d.get('message',{}).get('messageId',0);print(int(m)>>20 if m else 0)" 2>/dev/null)
echo "reply post id: $MID"
# --- deep-link FRAME the reply, re-assert geometry, grab still via ffmpeg (scrot is unreliable mid-run) ---
DISPLAY=:99 timeout 6 /opt/Telegram/Telegram -workdir "$CAP/tdata" "tg://privatepost?channel=$CHANNEL&post=$MID" >/dev/null 2>&1 || true
sleep 3; apply_geom; sleep 2
DISPLAY=:99 ffmpeg -y -loglevel error -f x11grab -video_size 1300x1080 -i :99 -frames:v 1 "$CAP/$LABEL-full.png" >/dev/null 2>&1
ffmpeg -y -loglevel error -i "$CAP/$LABEL-full.png" -vf "$CROP" "$CAP/$LABEL.png" >/dev/null 2>&1
ffmpeg -y -loglevel error -i "$CAP/$LABEL-raw.mp4" -vf "$CROP,$SCALE" -pix_fmt yuv420p "$CAP/$LABEL-motion.mp4" >/dev/null 2>&1
ffmpeg -y -loglevel error -i "$CAP/$LABEL-raw.mp4" -filter_complex "$CROP,fps=$FPS,$SCALE,split[a][b];[a]palettegen[p];[b][p]paletteuse" "$CAP/$LABEL-motion.gif" >/dev/null 2>&1
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill "$pid" 2>/dev/null; done
pkill -x Telegram 2>/dev/null||true; pkill -x openbox 2>/dev/null||true; pkill -x Xvfb 2>/dev/null||true
echo "MANTIS_DONE $LABEL png=$(stat -c%s "$CAP/$LABEL.png" 2>/dev/null||echo 0) full=$(stat -c%s "$CAP/$LABEL-full.png" 2>/dev/null||echo 0) gif=$(stat -c%s "$CAP/$LABEL-motion.gif" 2>/dev/null||echo 0) mid=$MID"
