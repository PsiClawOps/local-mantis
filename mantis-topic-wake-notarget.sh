#!/bin/bash
# local-mantis variant for PR #83738 (cron wake origin capture) — runs IN a crabbox box.
# Proves: a cron wake scheduled from a Telegram FORUM TOPIC replies back into that same
# topic (AFTER build) vs routing to the default/main lane (BEFORE build).
#
# Args: $1=payload.json  $2=LABEL  $3=BUILDDIR (/opt/openclaw = PR, /opt/openclaw-main = base)
# Self-stages $CAP/tdata + $CAP/driver from the payload archives when missing.
set -uo pipefail
CAP=/tmp/cap; PAY="${1:?payload}"; LABEL="${2:?label}"; BUILDDIR="${3:?builddir}"
GID=-1003900553563; CHANNEL=3900553563; SGID=3900553563
WIN_X=635; WIN_Y=40; WIN_W=650; WIN_H=1000
CROP="crop=430:1000:855:40"; SCALE="scale=430:-2:flags=lanczos"; FPS=12; RECSECS=110
cd "$BUILDDIR"

# --- orphan cleanup (patterns live in this file => can't self-match) ---
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill "$pid" 2>/dev/null; done
sleep 2; pkill -f "claude --output-format stream-json" 2>/dev/null||true
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
pkill -f "telegram-user-driver" 2>/dev/null||true; fuser -k "$CAP/driver/db/td.binlog" 2>/dev/null||true
# SIGKILLed Xvfb leaves a stale /tmp/.X11-unix/X99 socket -> new Xvfb :99 cannot
# bind -> Telegram has no display -> "window never mapped". Clear it + X locks.
rm -f /tmp/.X11-unix/X99 /tmp/.X99-lock 2>/dev/null||true; pkill -9 -x Telegram 2>/dev/null||true; pkill -9 -x openbox 2>/dev/null||true; pkill -9 -x Xvfb 2>/dev/null||true
# wait until the old Telegram is really gone — a TERM-lingering instance still
# holds the single-instance socket and the fresh launch defers to it and exits
for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Telegram >/dev/null 2>&1 || break; sleep 2; done
sleep 2; mkdir -p "$CAP/state-$LABEL"

SUT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sutToken'])" "$PAY")
BOTUID=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sutToken'].split(':')[0])" "$PAY")

# --- stage tdata + driver state from payload archives (idempotent) ---
python3 - "$PAY" <<'PYSTAGE'
import base64, io, json, os, sys, tarfile
pay = json.load(open(sys.argv[1]))
cap = "/tmp/cap"
for key, dest in (("desktopTdataArchiveBase64", f"{cap}/tdata"), ("tdlibArchiveBase64", f"{cap}/driver")):
    # driver state must contain db/ — a partial unpack (files/ only) passes a
    # naive non-empty check and then fails auth with "Not logged in"
    ok = os.path.isdir(dest) and os.listdir(dest)
    if dest.endswith("/driver"):
        ok = ok and os.path.isdir(f"{dest}/db")
    if ok:
        print(f"[stage] {dest} present"); continue
    import shutil; shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest, exist_ok=True)
    raw = base64.b64decode(pay[key])
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:*") as tf:
        tf.extractall(dest)
    print(f"[stage] unpacked {key} -> {dest}")
PYSTAGE

# --- drain unconsumed bot updates so a fresh gateway doesn't replay stale msgs ---
curl -s "https://api.telegram.org/bot$SUT/deleteWebhook?drop_pending_updates=true" >/dev/null 2>&1 || true

cat > "$CAP/openclaw.json" <<CONF
{ "agents": { "defaults": { "model": "claude-cli/claude-sonnet-4-6", "thinkingDefault": "low", "workspace": "$BUILDDIR",
  "cliBackends": { "claude-cli": { "command": "claude", "input": "stdin", "maxPromptArgChars": 1, "sessionMode": "always", "systemPromptMode": "replace",
    "args": ["-p","--output-format","stream-json","--include-partial-messages","--verbose","--setting-sources","user","--permission-mode","bypassPermissions"] } } } },
  "auth": { "order": { "anthropic": ["anthropic:claude-cli"] } },
  "gateway": { "port": 18789, "mode": "local", "bind": "loopback", "auth": { "mode": "token", "token": "test-token" } },
  "channels": { "telegram": { "enabled": true, "groupPolicy": "open", "groups": { "$GID": { "requireMention": false } },
    "botToken": { "id": "TELEGRAM_BOT_TOKEN", "provider": "default", "source": "env" }, "streaming": { "mode": "off" } } },
  "tools": { "profile": "coding", "exec": { "security": "full", "ask": "off" } },
  "plugins": { "entries": { "anthropic": {"enabled": true}, "browser": {"enabled": false}, "codex": {"enabled": false} } } }
CONF
OPENCLAW_CONFIG_PATH="$CAP/openclaw.json" OPENCLAW_STATE_DIR="$CAP/state-$LABEL" TELEGRAM_BOT_TOKEN="$SUT" OPENCLAW_GATEWAY_TOKEN=test-token \
  pnpm openclaw gateway --port 18789 --allow-unconfigured > "$CAP/gw-$LABEL.log" 2>&1 &
for i in $(seq 1 30); do grep -aq "\[gateway\] ready" "$CAP/gw-$LABEL.log" && break; sleep 3; done
grep -aiE "ready|error" "$CAP/gw-$LABEL.log"|tail -2

# --- desktop under a WM, geometry applied BEFORE recording ---
rm -f /tmp/.X11-unix/X99 /tmp/.X99-lock 2>/dev/null||true   # kill -9'"'"'d Xvfb leaves these; must clear AFTER the kills, right before relaunch
Xvfb :99 -screen 0 1300x1080x24 >/dev/null 2>&1 & sleep 2
DISPLAY=:99 openbox >/dev/null 2>&1 & sleep 1
DISPLAY=:99 dbus-launch /opt/Telegram/Telegram -workdir "$CAP/tdata" > /tmp/tg-launch-$LABEL.log 2>&1 & sleep 30
apply_geom(){ local w; w=$(DISPLAY=:99 wmctrl -lxG 2>/dev/null | awk 'tolower($0) ~ /telegram/ {print $1; exit}'); [ -n "$w" ] && { DISPLAY=:99 wmctrl -ir "$w" -b remove,maximized_vert,maximized_horz,fullscreen 2>/dev/null; DISPLAY=:99 wmctrl -ir "$w" -e 0,$WIN_X,$WIN_Y,$WIN_W,$WIN_H 2>/dev/null; }; }
# PREFLIGHT: a live Telegram process with NO mapped window = missing libopengl0 /
# tray-hidden => the whole recording would be silently BLACK. Fail fast instead.
for i in $(seq 1 30); do
  DISPLAY=:99 xwininfo -root -tree 2>/dev/null | grep -qi telegram && break; sleep 5
done
DISPLAY=:99 xwininfo -root -tree 2>/dev/null | grep -qi telegram || {
  echo "FAIL: Telegram window never mapped"
  echo "[diag] xdpyinfo: $(DISPLAY=:99 xdpyinfo 2>&1 | head -1)"
  echo "[diag] xwininfo:"; DISPLAY=:99 xwininfo -root -tree 2>&1 | head -8
  echo "[diag] procs:"; ps aux | grep -E "[T]elegram|[X]vfb|[o]penbox" | grep -v defunct | head -5
  echo "[diag] tdata log:"; tail -5 "$CAP/tdata/log.txt" 2>/dev/null
  echo "[diag] tg stderr:"; tail -5 /tmp/tg-launch-$LABEL.log 2>/dev/null
  exit 1
}
apply_geom; sleep 1

export TELEGRAM_USER_DRIVER_STATE_DIR="$CAP/driver"
# forum-topic tdlib calls (toggleSupergroupIsForum/createForumTopic) need tdlib >= 1.8.6;
# the box system libtdjson is 1.8.0 — use the prebuilt modern one.
export TELEGRAM_USER_DRIVER_TDLIB_PATH="$(node -e "console.log(require('/tmp/node_modules/prebuilt-tdlib').getTdjson())")"
echo "[tdlib] $TELEGRAM_USER_DRIVER_TDLIB_PATH"
export TELEGRAM_USER_DRIVER_API_ID="$(python3 -c "import json;print(json.load(open('$PAY'))['telegramApiId'])" 2>/dev/null)"
export TELEGRAM_USER_DRIVER_API_HASH="$(python3 -c "import json;print(json.load(open('$PAY'))['telegramApiHash'])" 2>/dev/null)"
export TELEGRAM_USER_DRIVER_DB_ENCRYPTION_KEY="$(python3 -c "import json;print(json.load(open('$PAY'))['tdlibDatabaseEncryptionKey'])" 2>/dev/null)"

# --- ensure forum mode + a fresh topic; returns the topic's message_thread_id ---
TID=$(python3 - "$LABEL" <<'PYTOPIC'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("tud", "scripts/e2e/telegram-user-driver.py")
tud = importlib.util.module_from_spec(spec); spec.loader.exec_module(tud)
config, bot_config = tud.load_config()
d = tud.UserDriver(config, bot_config)
d.authorize()
GID = -1003900553563; SGID = 3900553563
def req(p, t=25):
    r = d.client.request(p, timeout=t)
    if isinstance(r, dict) and r.get("@type") == "error":
        print(f"ERR {p.get('@type')}: {r.get('message')}", file=sys.stderr)
    return r
# fresh tdlib session: resolve the chat (access hash) before supergroup calls
try:
    d.client.request({"@type": "loadChats", "chat_list": {"@type": "chatListMain"}, "limit": 50}, timeout=20)
except Exception:
    pass
time.sleep(2)
req({"@type": "getChat", "chat_id": GID})
req({"@type": "toggleSupergroupIsForum", "supergroup_id": SGID, "is_forum": True, "has_forum_tabs": False})
time.sleep(2)
topic = req({"@type": "createForumTopic", "chat_id": GID, "name": f"PROOF-83738 {sys.argv[1]}",
             "icon": {"@type": "forumTopicIcon", "color": 0x6FB9F0, "custom_emoji_id": "0"}})
info = topic.get("info", topic) if isinstance(topic, dict) else {}
mtid = info.get("message_thread_id") or 0
print(int(mtid))
PYTOPIC
)
TID=$(echo "$TID" | tail -1)
echo "[topic] message_thread_id=$TID"
[ -z "$TID" ] || [ "$TID" = "0" ] && { echo "FAIL: no topic id"; exit 1; }
TOPICPOST=$((TID >> 20))

# open the topic in the desktop client
DISPLAY=:99 /opt/Telegram/Telegram -workdir "$CAP/tdata" "tg://privatepost?channel=$CHANNEL&post=$TOPICPOST" >/dev/null 2>&1 & sleep 5
apply_geom; sleep 1

DISPLAY=:99 ffmpeg -y -loglevel warning -f x11grab -video_size 1300x1080 -framerate $FPS -i :99 -t $RECSECS "$CAP/$LABEL-raw.mp4" >/dev/null 2>&1 & FF=$!
sleep 3

# State dir is fresh per label, so the topic session is already new (/new would
# need an owner-authorized sender and only adds an authorization-error reply).
SCENARIO='I am testing my cron wake routing in this topic. Please schedule a wake for right now using your cron tool (action wake, mode now) with text: You were woken by a cron wake. Run date -u with your exec tool and reply with exactly PROOF-83738 wake turn ran at followed by the command output. After your wake tool call returns, reply only: scheduled.'
python3 scripts/e2e/telegram-user-driver.py send --chat "$GID" --thread-id "$TID" --text "$SCENARIO" --timeout-ms 60000 >/dev/null 2>&1
# collect in-topic bot messages: turn reply ("scheduled.") then the wake-triggered
# heartbeat reply (THE proof). Stop early once the wake text shows up.
for i in 1 2 3 4; do
  python3 scripts/e2e/telegram-user-driver.py wait --chat "$GID" --thread-id "$TID" --from-bot "$BOTUID" --timeout-ms 120000 > "$CAP/topicmsg$i-$LABEL.json" 2>&1 || true
  TXT=$(python3 -c "import json;print((json.load(open('$CAP/topicmsg$i-$LABEL.json')).get('message',{}).get('text') or '')[:200])" 2>/dev/null)
  echo "[topic msg $i] $TXT"
  case "$TXT" in *PROOF-83738*) break;; esac
done
# record whether anything landed OUTSIDE the topic (root lane) for the before/after contrast
python3 scripts/e2e/telegram-user-driver.py wait --chat "$GID" --from-bot "$BOTUID" --timeout-ms 45000 > "$CAP/rootlane-$LABEL.json" 2>&1 || true
wait $FF 2>/dev/null

WAKEJSON=""
for i in 4 3 2 1; do
  T=$(python3 -c "import json;print((json.load(open('$CAP/topicmsg$i-$LABEL.json')).get('message',{}).get('text') or '')[:200])" 2>/dev/null)
  case "$T" in *PROOF-83738*) WAKEJSON="$CAP/topicmsg$i-$LABEL.json"; break;; esac
done
[ -z "$WAKEJSON" ] && WAKEJSON="$CAP/topicmsg2-$LABEL.json"
MID=$(python3 -c "import json;d=json.load(open('$WAKEJSON'));m=d.get('message',{}).get('messageId',0);print(int(m)>>20 if m else 0)" 2>/dev/null)
echo "wake reply post id: $MID"
[ -z "$MID" ] && MID=0
if [ "$MID" -gt 0 ]; then
  DISPLAY=:99 timeout 6 /opt/Telegram/Telegram -workdir "$CAP/tdata" "tg://privatepost?channel=$CHANNEL&post=$MID" >/dev/null 2>&1 || true
else
  DISPLAY=:99 timeout 6 /opt/Telegram/Telegram -workdir "$CAP/tdata" "tg://privatepost?channel=$CHANNEL&post=$TOPICPOST" >/dev/null 2>&1 || true
fi
sleep 3; apply_geom; sleep 2
DISPLAY=:99 ffmpeg -y -loglevel error -f x11grab -video_size 1300x1080 -i :99 -frames:v 1 "$CAP/$LABEL-full.png" >/dev/null 2>&1
ffmpeg -y -loglevel error -i "$CAP/$LABEL-full.png" -vf "$CROP" "$CAP/$LABEL.png" >/dev/null 2>&1
ffmpeg -y -loglevel error -i "$CAP/$LABEL-raw.mp4" -vf "$CROP,$SCALE,fps=$FPS" "$CAP/$LABEL-motion.gif" >/dev/null 2>&1

# --- diagnostics: wake routing lines + where each reply landed ---
echo "--- gateway wake/heartbeat lines ($LABEL) ---"
grep -aiE "wake|heartbeat|cron" "$CAP/gw-$LABEL.log" | grep -av "getUpdates" | tail -25 || true
for i in 1 2 3 4; do
  echo "--- topic msg $i: $(python3 -c "import json;d=json.load(open('$CAP/topicmsg$i-$LABEL.json'));m=d.get('message',{});print(m.get('threadId'),repr((m.get('text') or '')[:90]))" 2>/dev/null)"
done
echo "--- root-lane extra: $(python3 -c "import json;d=json.load(open('$CAP/rootlane-$LABEL.json'));m=d.get('message',{});print(m.get('threadId'),repr((m.get('text') or '')[:90]))" 2>/dev/null)"
pkill -f "run-node.mjs gateway" 2>/dev/null || true; pkill -x openclaw 2>/dev/null || true
echo "[done] $LABEL artifacts under $CAP"
