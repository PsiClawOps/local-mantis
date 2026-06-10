#!/bin/bash
# CANONICAL local-mantis DM capture (runs IN a crabbox box). For features that render in the
# bot DM (e.g. #89850 persistProgress live progress draft). Same lessons baked in as the group
# variant; frames the persistent message via window geometry (no deep-link in DMs).
# Args: $1=payload  $2=LABEL  $3=SCENARIO  $4=STREAMKEY(persist-on|persist-off|plain)
set -uo pipefail
CAP=/tmp/cap; PAY="${1:?}"; LABEL="${2:?}"; SCENARIO="${3:?}"; SK="${4:-persist-on}"
CHAT=8685483103                                         # bot DM (chat id == bot user id)
# CALIBRATED TO OUR Telegram Desktop build (NOT the cloud Mantis absolute constants — those assume
# a different sidebar/message-column layout). Small display + MAXIMIZED window => capture region is
# relative to our window, not a fragile absolute offset. Crop = our conversation column (sidebar
# ~285px, messages ~435px) from a calibration screenshot. Re-calibrate if the build/display changes.
DISP_W=720; DISP_H=1050; CROP="crop=435:920:285:78"; SCALE="scale=435:-2:flags=lanczos"; FPS=12; RECSECS=${MANTIS_RECSECS:-48}
# GIF is trimmed to the BUILD WINDOW so it isn't mostly static: the bot reply is so fast that the
# motion (progress draft building -> answer arriving) is a small slice of a 48s recording. Recording
# rolls well before the prompt fires (ffmpeg -> sleep 3 -> /new -> sleep 8 -> scenario at ~t=11,
# reply ~t=27), so GIF_SS skips the dead lead-in and GIF_T covers build+reply+buffer. Re-tune if the
# scenario/response timing changes.
GIF_SS=${MANTIS_GIF_SS:-9}; GIF_T=${MANTIS_GIF_T:-26}
# Model + thinking: claude-cli emits inter-tool COMMENTARY (visible assistant text before a tool,
# which #89834 captures) far more readily on opus 4.8 with MAX thinking/effort than on sonnet with
# medium (sonnet buries the narration in thinking blocks -> no commentary lines). Override via env.
MODEL=${MANTIS_MODEL:-claude-cli/claude-opus-4-8}; THINK=${MANTIS_THINK:-max}
# systemPromptMode "replace" (openclaw's prompt only) makes claude batch narration into the FINAL
# answer -> no inter-tool preamble text -> #89834 commentary never fires. "append" keeps claude's
# default prompt (its natural "I'll do X" preamble before tools) + appends openclaw's -> preamble
# surfaces -> commentary lines render. Use append to capture the commentary proof.
SYSPROMPT=${MANTIS_SYSPROMPT:-replace}
# CLAUDE_CMD lets us swap the claude binary for a wrapper that tees the raw stream-json to a file,
# so we can diff what claude emits vs what the progress draft renders (catch silently-dropped events).
CLAUDE_CMD=${MANTIS_CLAUDE_CMD:-claude}
cd /opt/openclaw
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill "$pid" 2>/dev/null; done
sleep 2; pkill -f "claude --output-format stream-json" 2>/dev/null||true
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
pkill -x Telegram 2>/dev/null||true; pkill -x openbox 2>/dev/null||true; pkill -x Xvfb 2>/dev/null||true; sleep 3
# Wipe ONLY the gateway state (telegram ingress spool + offset). deleteWebhook only
# clears Telegram's server backlog; the LOCAL spool replays queued /new+scenario from
# prior/failed runs -> the gateway does multiple agent runs (multiple messages, "spam").
# DO NOT touch "$CAP/driver" — that is the user-driver's persistent tdlib auth/session.
rm -rf "$CAP/state"; mkdir -p "$CAP/state"
SUT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sutToken'])" "$PAY")
BOTUID=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sutToken'].split(':')[0])" "$PAY")
TESTER=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('testerUserId',''))" "$PAY")
# Drain pending bot updates before starting the fresh gateway. Failed/prior capture
# runs leave the driver's /new + scenario messages UNCONSUMED in Telegram's update
# backlog; a new gateway would replay them and the driver would capture the wrong
# (stale) reply. drop_pending_updates clears the backlog server-side.
curl -s "https://api.telegram.org/bot${SUT}/deleteWebhook?drop_pending_updates=true" >/dev/null 2>&1 || true
case "$SK" in
  persist-on)  STREAM='"mode":"progress","progress":{"commentary":true,"toolProgress":true,"persistProgress":true}';;
  persist-off) STREAM='"mode":"progress","progress":{"commentary":true,"toolProgress":true,"persistProgress":false}';;
  commentary)  STREAM='"mode":"progress","progress":{"commentary":true,"toolProgress":true}';;  # no persistProgress (that's #89850); valid on upstream/main
  separate)    STREAM='"mode":"off","progress":{"commentary":true,"toolProgress":true,"persistProgress":true}';;  # #89890: stream OFF -> commentary+tool lane accumulates SILENTLY, delivered as its own message set at final-send (before the answer)
  *)           STREAM='"mode":"partial"';;
esac
cat > "$CAP/openclaw.json" <<CONF
{ "agents": { "defaults": { "model": "$MODEL", "thinkingDefault": "$THINK", "workspace": "/opt/openclaw",
  "cliBackends": { "claude-cli": { "command": "$CLAUDE_CMD", "input": "stdin", "maxPromptArgChars": 1, "sessionMode": "always", "systemPromptMode": "$SYSPROMPT",
    "args": ["-p","--output-format","stream-json","--include-partial-messages","--verbose","--setting-sources","user","--permission-mode","bypassPermissions"] } } } },
  "auth": { "order": { "anthropic": ["anthropic:claude-cli"] } },
  "gateway": { "port": 18789, "mode": "local", "bind": "loopback", "auth": { "mode": "token", "token": "test-token" } },
  "channels": { "telegram": { "enabled": true, "dmPolicy": "allowlist", "allowFrom": [$TESTER],
    "botToken": { "id": "TELEGRAM_BOT_TOKEN", "provider": "default", "source": "env" }, "streaming": { $STREAM } } },
  "tools": { "profile": "coding", "exec": { "security": "full", "ask": "off" } },
  "plugins": { "entries": { "anthropic": {"enabled": true}, "browser": {"enabled": false}, "codex": {"enabled": false} } } }
CONF
OPENCLAW_CONFIG_PATH="$CAP/openclaw.json" OPENCLAW_STATE_DIR="$CAP/state" TELEGRAM_BOT_TOKEN="$SUT" OPENCLAW_GATEWAY_TOKEN=test-token \
  pnpm openclaw gateway --port 18789 --allow-unconfigured > "$CAP/gw-$LABEL.log" 2>&1 &
sleep 14; grep -aiE "ready|error" "$CAP/gw-$LABEL.log"|tail -2
Xvfb :99 -screen 0 ${DISP_W}x${DISP_H}x24 >/dev/null 2>&1 & sleep 2
DISPLAY=:99 openbox >/dev/null 2>&1 & sleep 1
DISPLAY=:99 dbus-launch /opt/Telegram/Telegram -workdir "$CAP/tdata" >/dev/null 2>&1 & sleep 18
apply_geom(){ local w; w=$(DISPLAY=:99 wmctrl -lxG 2>/dev/null | awk 'tolower($0) ~ /telegram/ {print $1; exit}'); [ -n "$w" ] && { DISPLAY=:99 wmctrl -ir "$w" -b remove,fullscreen 2>/dev/null; DISPLAY=:99 wmctrl -ir "$w" -b add,maximized_vert,maximized_horz 2>/dev/null; }; }
apply_geom; sleep 1
DISPLAY=:99 /opt/Telegram/Telegram -workdir "$CAP/tdata" "tg://resolve?domain=JeeevesOpenClawTelegram2bot" >/dev/null 2>&1 & sleep 5
apply_geom; sleep 1
export TELEGRAM_USER_DRIVER_STATE_DIR="$CAP/driver"
# Telegram app credentials for the user-driver (tdlib). These live with the driver config,
# not in the tdlib session archive, so set them from the payload to survive a state restore.
export TELEGRAM_USER_DRIVER_API_ID="$(python3 -c "import json;print(json.load(open('$PAY'))['telegramApiId'])" 2>/dev/null)"
export TELEGRAM_USER_DRIVER_API_HASH="$(python3 -c "import json;print(json.load(open('$PAY'))['telegramApiHash'])" 2>/dev/null)"
export TELEGRAM_USER_DRIVER_DB_ENCRYPTION_KEY="$(python3 -c "import json;print(json.load(open('$PAY'))['tdlibDatabaseEncryptionKey'])" 2>/dev/null)"
DISPLAY=:99 ffmpeg -y -loglevel warning -f x11grab -video_size ${DISP_W}x${DISP_H} -framerate $FPS -i :99 -t $RECSECS "$CAP/$LABEL-raw.mp4" >/dev/null 2>&1 & FF=$!
sleep 3
python3 scripts/e2e/telegram-user-driver.py send --chat "$CHAT" --text "/new" --timeout-ms 30000 >/dev/null 2>&1
# Wait for the "New session started" confirmation before sending the scenario. A fixed
# sleep races a laggy gateway (scenario lands in an un-reset session); waiting also flags
# a dead/broken gateway EARLY (empty ack => abort instead of capturing a broken run).
python3 scripts/e2e/telegram-user-driver.py wait --chat "$CHAT" --from-bot "$BOTUID" --timeout-ms 45000 > "$CAP/newack-$LABEL.json" 2>&1 || true
if ! grep -qi "new session" "$CAP/newack-$LABEL.json" 2>/dev/null; then echo "WARN: no '/new' confirmation within 45s (gateway laggy/broken?) — capture may be invalid"; fi
sleep 2
python3 scripts/e2e/telegram-user-driver.py send --chat "$CHAT" --text "$SCENARIO" --timeout-ms 60000 >/dev/null 2>&1
python3 scripts/e2e/telegram-user-driver.py wait --chat "$CHAT" --from-bot "$BOTUID" --timeout-ms 120000 > "$CAP/observed-$LABEL.json" 2>&1 || true
sleep 4; wait $FF 2>/dev/null
# the persisted message is the latest in the DM; re-assert geometry and grab the still (message fits the tall column)
apply_geom; sleep 2
DISPLAY=:99 /opt/Telegram/Telegram -workdir "$CAP/tdata" "tg://resolve?domain=JeeevesOpenClawTelegram2bot" >/dev/null 2>&1; sleep 2; apply_geom; sleep 2
DISPLAY=:99 ffmpeg -y -loglevel error -f x11grab -video_size ${DISP_W}x${DISP_H} -i :99 -frames:v 1 "$CAP/$LABEL-full.png" >/dev/null 2>&1
ffmpeg -y -loglevel error -i "$CAP/$LABEL-full.png" -vf "$CROP" "$CAP/$LABEL.png" >/dev/null 2>&1
ffmpeg -y -loglevel error -i "$CAP/$LABEL-raw.mp4" -vf "$CROP,$SCALE" -pix_fmt yuv420p "$CAP/$LABEL-motion.mp4" >/dev/null 2>&1
ffmpeg -y -loglevel error -ss $GIF_SS -t $GIF_T -i "$CAP/$LABEL-raw.mp4" -filter_complex "$CROP,fps=$FPS,$SCALE,split[a][b];[a]palettegen[p];[b][p]paletteuse" "$CAP/$LABEL-motion.gif" >/dev/null 2>&1
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill "$pid" 2>/dev/null; done
pkill -x Telegram 2>/dev/null||true; pkill -x openbox 2>/dev/null||true; pkill -x Xvfb 2>/dev/null||true
echo "MANTIS_DM_DONE $LABEL png=$(stat -c%s "$CAP/$LABEL.png" 2>/dev/null||echo 0) full=$(stat -c%s "$CAP/$LABEL-full.png" 2>/dev/null||echo 0) gif=$(stat -c%s "$CAP/$LABEL-motion.gif" 2>/dev/null||echo 0)"
