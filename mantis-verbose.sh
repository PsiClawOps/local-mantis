#!/bin/bash
# local-mantis DM capture for the VERBOSE COMMENTARY LANE proof (feat/verbose-commentary-progress,
# supersedes #89850/#89890). Derived from mantis-dm.sh; differences:
#   - $4 streamkey selects the verbose scenarios: verbose-stream-off | verbose-stream-on
#   - $5 BUILDDIR selects the build: /opt/openclaw (PR) vs /opt/openclaw-main (baseline)
#   - config sets agents.defaults.verboseDefault "on" (the durable progress lane gate)
#   - systemPromptMode defaults to APPEND (claude only emits inter-tool preamble with its own prompt)
#   - longer recording: verbose runs emit several standalone messages before the answer
# Args: $1=payload  $2=LABEL  $3=SCENARIO  $4=STREAMKEY  $5=BUILDDIR(default /opt/openclaw)
set -uo pipefail
CAP=/tmp/cap; PAY="${1:?}"; LABEL="${2:?}"; SCENARIO="${3:?}"; SK="${4:-verbose-stream-off}"; BUILDDIR="${5:-/opt/openclaw}"
CHAT=8685483103                                         # bot DM (chat id == bot user id)
DISP_W=720; DISP_H=1050; CROP="crop=435:920:285:78"; SCALE="scale=435:-2:flags=lanczos"; FPS=12; RECSECS=${MANTIS_RECSECS:-75}
GIF_SS=${MANTIS_GIF_SS:-9}; GIF_T=${MANTIS_GIF_T:-40}
MODEL=${MANTIS_MODEL:-claude-cli/claude-opus-4-8}; THINK=${MANTIS_THINK:-max}
SYSPROMPT=${MANTIS_SYSPROMPT:-append}
CLAUDE_CMD=${MANTIS_CLAUDE_CMD:-claude}
cd "$BUILDDIR"
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill "$pid" 2>/dev/null; done
sleep 2; pkill -f "claude --output-format stream-json" 2>/dev/null||true
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
pkill -x Telegram 2>/dev/null||true; pkill -x openbox 2>/dev/null||true; pkill -x Xvfb 2>/dev/null||true; sleep 3
rm -rf "$CAP/state"; mkdir -p "$CAP/state"
SUT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sutToken'])" "$PAY")
BOTUID=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sutToken'].split(':')[0])" "$PAY")
TESTER=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('testerUserId',''))" "$PAY")
curl -s "https://api.telegram.org/bot${SUT}/deleteWebhook?drop_pending_updates=true" >/dev/null 2>&1 || true
case "$SK" in
  # Ayaan's headline: no streaming draft at all; verbose delivers tool summaries AND (with the PR)
  # interleaved durable commentary messages. Baseline build: tool summaries only, commentary folded
  # into the final answer text.
  verbose-stream-off) STREAM='"mode":"off"';;
  # Streaming draft active + verbose: baseline double-renders progress (draft lines + standalone
  # messages) and commentary lives only in the ephemeral draft; PR yields the draft lines and
  # delivers commentary durably.
  verbose-stream-on)  STREAM='"mode":"progress","progress":{"commentary":true,"toolProgress":true}';;
  *) echo "unknown streamkey $SK"; exit 2;;
esac
cat > "$CAP/openclaw.json" <<CONF
{ "agents": { "defaults": { "model": "$MODEL", "thinkingDefault": "$THINK", "verboseDefault": "on", "workspace": "$BUILDDIR",
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
# tdlib lives in the checkpoint's /tmp prebuilt-tdlib install; the driver only
# probes system paths, so point it there explicitly (preflight: tdlib 1.8.14).
TDLIB_SO=$(ls /tmp/node_modules/prebuilt-tdlib/prebuilds/tdlib-linux-x64/libtdjson.so 2>/dev/null || true)
[ -n "$TDLIB_SO" ] && export TELEGRAM_USER_DRIVER_TDLIB_PATH="$TDLIB_SO"
export TELEGRAM_USER_DRIVER_API_ID="$(python3 -c "import json;print(json.load(open('$PAY'))['telegramApiId'])" 2>/dev/null)"
export TELEGRAM_USER_DRIVER_API_HASH="$(python3 -c "import json;print(json.load(open('$PAY'))['telegramApiHash'])" 2>/dev/null)"
export TELEGRAM_USER_DRIVER_DB_ENCRYPTION_KEY="$(python3 -c "import json;print(json.load(open('$PAY'))['tdlibDatabaseEncryptionKey'])" 2>/dev/null)"
# Warm the tdlib chat list BEFORE arming any wait: a fresh/checkpointed driver
# session delivers no updateNewMessage events until the chat list has loaded
# (gotcha #8), which silently breaks every wait and desyncs the recording.
python3 scripts/e2e/telegram-user-driver.py chats --json >/dev/null 2>&1 || true
DISPLAY=:99 ffmpeg -y -loglevel warning -f x11grab -video_size ${DISP_W}x${DISP_H} -framerate $FPS -i :99 -t $RECSECS "$CAP/$LABEL-raw.mp4" >/dev/null 2>&1 & FF=$!
sleep 3
# Anchor each wait to the id of the message we just sent so a stale unread
# backlog (replayed as updateNewMessage right after the chats warmup) can't
# satisfy the wait.
NEWID=$(python3 scripts/e2e/telegram-user-driver.py send --chat "$CHAT" --text "/new" --timeout-ms 30000 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('messageId',0))" 2>/dev/null || echo 0)
python3 scripts/e2e/telegram-user-driver.py wait --chat "$CHAT" --from-bot "$BOTUID" --after-message-id "${NEWID:-0}" --timeout-ms 45000 > "$CAP/newack-$LABEL.json" 2>&1 || true
if ! grep -qi "new session" "$CAP/newack-$LABEL.json" 2>/dev/null; then echo "WARN: no '/new' confirmation within 45s (gateway laggy/broken?) — capture may be invalid"; fi
sleep 2
SCENID=$(python3 scripts/e2e/telegram-user-driver.py send --chat "$CHAT" --text "$SCENARIO" --timeout-ms 60000 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('messageId',0))" 2>/dev/null || echo 0)
python3 scripts/e2e/telegram-user-driver.py wait --chat "$CHAT" --from-bot "$BOTUID" --after-message-id "${SCENID:-0}" --timeout-ms 120000 > "$CAP/observed-$LABEL.json" 2>&1 || true
sleep 4; wait $FF 2>/dev/null
apply_geom; sleep 2
DISPLAY=:99 /opt/Telegram/Telegram -workdir "$CAP/tdata" "tg://resolve?domain=JeeevesOpenClawTelegram2bot" >/dev/null 2>&1; sleep 2; apply_geom; sleep 2
DISPLAY=:99 ffmpeg -y -loglevel error -f x11grab -video_size ${DISP_W}x${DISP_H} -i :99 -frames:v 1 "$CAP/$LABEL-full.png" >/dev/null 2>&1
ffmpeg -y -loglevel error -i "$CAP/$LABEL-full.png" -vf "$CROP" "$CAP/$LABEL.png" >/dev/null 2>&1
ffmpeg -y -loglevel error -i "$CAP/$LABEL-raw.mp4" -vf "$CROP,$SCALE" -pix_fmt yuv420p "$CAP/$LABEL-motion.mp4" >/dev/null 2>&1
ffmpeg -y -loglevel error -ss $GIF_SS -t $GIF_T -i "$CAP/$LABEL-raw.mp4" -filter_complex "$CROP,fps=6,$SCALE,split[a][b];[a]palettegen[p];[b][p]paletteuse" "$CAP/$LABEL-motion.gif" >/dev/null 2>&1
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill "$pid" 2>/dev/null; done
pkill -x Telegram 2>/dev/null||true; pkill -x openbox 2>/dev/null||true; pkill -x Xvfb 2>/dev/null||true
echo "MANTIS_VERBOSE_DONE $LABEL build=$BUILDDIR png=$(stat -c%s "$CAP/$LABEL.png" 2>/dev/null||echo 0) full=$(stat -c%s "$CAP/$LABEL-full.png" 2>/dev/null||echo 0) gif=$(stat -c%s "$CAP/$LABEL-motion.gif" 2>/dev/null||echo 0)"
