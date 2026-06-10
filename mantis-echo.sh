#!/bin/bash
# CANONICAL local-mantis ECHO capture (runs IN a crabbox desktop box). For #88815 channel-echo /
# session pinning: a WEBCHAT chat.send is mirrored ("echoed") into a pinned Telegram supergroup,
# and — when the channel has a streaming renderer — rendered LIVE there (one message, edited as
# tokens arrive). This is the ONE thing the native mantis-group.sh can't show: that script drives a
# real Telegram message and films the in-group NATIVE reply; here the origin is webchat and the reply
# ECHOES into the group. Everything else (desktop, geometry, deep-link framing, crop, motion gif) is
# the same baked machinery as mantis-dm.sh / mantis-group.sh — DO NOT re-hand-roll it.
#
# Model source = a deterministic word-by-word openai-responses MOCK (so the streamed text is known +
# reproducible and the run never depends on in-box claude oauth). The ECHO PIPELINE under test —
# agent-event bus -> mirror resolver -> telegram draft stream -> live editMessageText, + the post-hoc
# duplicate gating — is 100% the PR's real code, exercised by real token deltas. Override the model
# via MANTIS_ECHO_MODEL=claude-cli/... if you want a real backend (needs the host->box creds sync loop).
#
# Args: $1=payload  $2=LABEL  $3=SCENARIO   (SCENARIO = the webchat user prompt; the mock ignores it
#                                            for text but it still drives a real turn + prompt echo)
set -uo pipefail
CAP=/tmp/cap; PAY="${1:?}"; LABEL="${2:?}"; SCENARIO="${3:?give a webchat prompt}"
GID=-1003900553563; CHANNEL=3900553563                 # supergroup -100 id; channel = id sans -100
SK_KEY=${MANTIS_ECHO_SESSION:-agent:main:mantis-echo}  # webchat-origin session that holds the echo pin
# Calibrated to OUR Telegram Desktop build (see mantis-dm.sh): small display + MAXIMIZED window,
# crop = our conversation column (sidebar ~285px, messages ~435px). Re-calibrate if build/display changes.
DISP_W=720; DISP_H=1050; CROP="crop=435:920:285:78"; SCALE="scale=435:-2:flags=lanczos"; FPS=12
RECSECS=${MANTIS_RECSECS:-48}; GIF_SS=${MANTIS_GIF_SS:-6}; GIF_T=${MANTIS_GIF_T:-30}
MOCK_PORT=${MANTIS_MOCK_PORT:-8899}
MODEL=${MANTIS_ECHO_MODEL:-openai/mock-model}          # default: deterministic streaming mock
OC_SRC=${MANTIS_OC_SRC:-/opt/openclaw}                 # openclaw source tree (has scripts/e2e/*)
# user-driver tdlib creds (from payload) — a fresh-restored $CAP/driver needs these or "Wrong password"
export TELEGRAM_USER_DRIVER_API_ID=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('telegramApiId',''))" "$PAY" 2>/dev/null)
export TELEGRAM_USER_DRIVER_API_HASH=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('telegramApiHash',''))" "$PAY" 2>/dev/null)
export TELEGRAM_USER_DRIVER_DB_ENCRYPTION_KEY=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('tdlibDatabaseEncryptionKey',''))" "$PAY" 2>/dev/null)
cd "$OC_SRC"

# --- orphan cleanup (patterns live in this file => can't self-match) ---
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill "$pid" 2>/dev/null; done
sleep 2; pkill -f "streammock.mjs" 2>/dev/null||true
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
pkill -x Telegram 2>/dev/null||true; pkill -x openbox 2>/dev/null||true; pkill -x Xvfb 2>/dev/null||true; sleep 3
# Wipe ONLY gateway state (telegram ingress spool/offset). NEVER touch "$CAP/driver" (tdlib auth).
rm -rf "$CAP/state"; mkdir -p "$CAP/state"
SUT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sutToken'])" "$PAY")
BOTUID=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sutToken'].split(':')[0])" "$PAY")
# Drain pending bot updates so a prior/failed run's messages aren't replayed (see mantis-dm.sh).
curl -s "https://api.telegram.org/bot${SUT}/deleteWebhook?drop_pending_updates=true" >/dev/null 2>&1 || true

# --- deterministic word-by-word openai-responses mock (streams 35-ish deltas @350ms) ---
cat > "$CAP/streammock.mjs" <<'MOCK'
import http from "http";
const PORT = Number(process.env.MOCK_PORT || 8899);
const TEXT = "The ocean covers about seventy percent of Earth's surface. It holds ninety-seven percent of all the planet's water. Its deepest known point is the Mariana Trench. Most of the ocean still remains unexplored by humans.";
function sse(res,o){ res.write(`event: ${o.type}\ndata: ${JSON.stringify(o)}\n\n`); }
http.createServer((req,res)=>{ let b=""; req.on("data",c=>b+=c); req.on("end", async ()=>{
  res.writeHead(200,{"Content-Type":"text/event-stream","Cache-Control":"no-cache","Connection":"keep-alive"});
  const id="msg_mock_1";
  sse(res,{type:"response.created",response:{id:"resp_mock",status:"in_progress"}});
  sse(res,{type:"response.output_item.added",output_index:0,item:{type:"message",id,role:"assistant",content:[],status:"in_progress"}});
  sse(res,{type:"response.content_part.added",item_id:id,output_index:0,content_index:0,part:{type:"output_text",text:"",annotations:[]}});
  const w=TEXT.split(" ");
  for(let i=0;i<w.length;i++){ sse(res,{type:"response.output_text.delta",item_id:id,output_index:0,content_index:0,delta:(i?" ":"")+w[i]}); await new Promise(r=>setTimeout(r,350)); }
  sse(res,{type:"response.output_text.done",item_id:id,output_index:0,content_index:0,text:TEXT});
  sse(res,{type:"response.content_part.done",item_id:id,output_index:0,content_index:0,part:{type:"output_text",text:TEXT,annotations:[]}});
  sse(res,{type:"response.output_item.done",output_index:0,item:{type:"message",id,role:"assistant",status:"completed",content:[{type:"output_text",text:TEXT,annotations:[]}]}});
  sse(res,{type:"response.completed",response:{id:"resp_mock",status:"completed",output:[{type:"message",id,role:"assistant",status:"completed",content:[{type:"output_text",text:TEXT,annotations:[]}]}],usage:{input_tokens:11,output_tokens:40,total_tokens:51}}});
  res.end();
}); }).listen(PORT,"127.0.0.1",()=>console.log("streammock "+PORT));
MOCK
MOCK_PORT=$MOCK_PORT node "$CAP/streammock.mjs" > "$CAP/streammock-$LABEL.log" 2>&1 & sleep 1

# --- config: openai mock provider + telegram (streaming on) + control-ui device-auth disabled.
# NOTE: isolated #88815 head — NO streaming.preview.interleaved* keys (those are persist-stack only
# and the isolated schema rejects them). streaming.mode:partial is enough for the echo renderer. ---
cat > "$CAP/openclaw.json" <<CONF
{ "gateway": { "port": 18789, "mode": "local", "bind": "loopback",
    "controlUi": { "enabled": true, "allowedOrigins": ["*"], "allowInsecureAuth": true, "dangerouslyDisableDeviceAuth": true },
    "auth": { "mode": "token", "token": "test-token" } },
  "channels": { "telegram": { "enabled": true, "dmPolicy": "pairing",
    "botToken": { "id": "TELEGRAM_BOT_TOKEN", "provider": "default", "source": "env" },
    "streaming": { "mode": "partial" } } },
  "tools": { "profile": "minimal" },
  "plugins": { "entries": { "openai": {"enabled": true}, "telegram": {"enabled": true} }, "allow": ["openai","telegram"] },
  "models": { "providers": { "openai": { "api": "openai-responses",
    "apiKey": { "id": "OPENAI_API_KEY", "provider": "default", "source": "env" },
    "baseUrl": "http://127.0.0.1:$MOCK_PORT/v1",
    "models": [ { "api": "openai-responses", "contextWindow": 128000, "id": "mock-model", "name": "mock-model" } ],
    "request": { "allowPrivateNetwork": true } } } } }
CONF

OPENCLAW_CONFIG_PATH="$CAP/openclaw.json" OPENCLAW_STATE_DIR="$CAP/state" \
HOME=/home/crabbox TELEGRAM_BOT_TOKEN="$SUT" OPENAI_API_KEY=mock-key OPENCLAW_GATEWAY_TOKEN=test-token OPENCLAW_LOG_LEVEL=debug \
  openclaw gateway run --port 18789 --bind loopback --allow-unconfigured > "$CAP/gw-$LABEL.log" 2>&1 &
# wait for ready
for i in $(seq 1 30); do grep -qiE "http server listening" "$CAP/gw-$LABEL.log" && break; sleep 1; done
grep -aiE "http server listening|EADDRINUSE|additional propert|error" "$CAP/gw-$LABEL.log" | tail -3

# --- pin the echo: the session must exist first, so seed it with one webchat send, then add the
# telegram group as an echo target (echoAssistant). drive.mjs = webchat chat.send via the gateway. ---
cat > "$CAP/drive.mjs" <<DRIVE
import { connectGateway } from "$OC_SRC/scripts/e2e/mcp-channels-harness.ts";
const [,, msg, sk] = process.argv;
const gw = await connectGateway({ url: "ws://127.0.0.1:18789", token: process.env.GW_TOKEN || "test-token" });
if (process.env.PIN === "1") {
  // ensure session exists, then pin the telegram group as an echo target
  await gw.request("sessions.echo", { key: sk, action: "add", channel: "telegram", to: process.env.GID, echoAssistant: true, echoUser: true }).catch(e=>console.log("pin:", String(e)));
  console.log("pinned");
} else {
  const r = await gw.request("chat.send", { sessionKey: sk, message: msg, model: process.env.ECHO_MODEL, idempotencyKey: "mantis-echo-" + msg.length });
  console.log("chat.send:", JSON.stringify(r));
}
setTimeout(()=>process.exit(0), 2500);
DRIVE
# seed session (a throwaway turn so the entry exists), then pin
GW_TOKEN=test-token ECHO_MODEL="$MODEL" node --experimental-strip-types "$CAP/drive.mjs" "warmup" "$SK_KEY" >/dev/null 2>&1 || true
sleep 6
GW_TOKEN=test-token GID="$GID" PIN=1 node --experimental-strip-types "$CAP/drive.mjs" "" "$SK_KEY" 2>&1 | tail -2

# --- desktop under a WM, geometry applied BEFORE recording (see mantis-dm.sh) ---
Xvfb :99 -screen 0 ${DISP_W}x${DISP_H}x24 >/dev/null 2>&1 & sleep 2
DISPLAY=:99 openbox >/dev/null 2>&1 & sleep 1
DISPLAY=:99 dbus-launch /opt/Telegram/Telegram -workdir "$CAP/tdata" >/dev/null 2>&1 & sleep 18
maximize(){ local w; w=$(DISPLAY=:99 wmctrl -lxG 2>/dev/null | awk 'tolower($0) ~ /telegram/ {print $1; exit}'); [ -n "$w" ] && DISPLAY=:99 wmctrl -ir "$w" -b add,maximized_vert,maximized_horz 2>/dev/null; }
maximize; sleep 1
DISPLAY=:99 /opt/Telegram/Telegram -workdir "$CAP/tdata" "tg://privatepost?channel=$CHANNEL&post=1" >/dev/null 2>&1 & sleep 5
maximize; sleep 1
export TELEGRAM_USER_DRIVER_STATE_DIR="$CAP/driver"
DISPLAY=:99 ffmpeg -y -loglevel warning -f x11grab -video_size ${DISP_W}x${DISP_H} -framerate $FPS -i :99 -t $RECSECS "$CAP/$LABEL-raw.mp4" >/dev/null 2>&1 & FF=$!
sleep 3

# --- DRIVE the echo: webchat chat.send on the pinned session -> response streams natively into the group ---
GW_TOKEN=test-token ECHO_MODEL="$MODEL" node --experimental-strip-types "$CAP/drive.mjs" "$SCENARIO" "$SK_KEY" 2>&1 | tail -1
# observe the bot's ECHOED message in the group to get its id for deep-link framing
python3 scripts/e2e/telegram-user-driver.py wait --chat "$GID" --from-bot "$BOTUID" --timeout-ms 120000 > "$CAP/observed-$LABEL.json" 2>&1 || true
wait $FF 2>/dev/null
MID=$(python3 -c "import json;d=json.load(open('$CAP/observed-$LABEL.json'));m=d.get('message',{}).get('messageId',0);print(int(m)>>20 if m else 0)" 2>/dev/null)
echo "echoed reply post id: $MID"

# --- deep-link FRAME the echoed reply, re-assert geometry, grab still + motion gif ---
DISPLAY=:99 timeout 6 /opt/Telegram/Telegram -workdir "$CAP/tdata" "tg://privatepost?channel=$CHANNEL&post=$MID" >/dev/null 2>&1 || true
sleep 3; maximize; sleep 2
DISPLAY=:99 ffmpeg -y -loglevel error -f x11grab -video_size ${DISP_W}x${DISP_H} -i :99 -frames:v 1 "$CAP/$LABEL-full.png" >/dev/null 2>&1
ffmpeg -y -loglevel error -i "$CAP/$LABEL-full.png" -vf "$CROP" "$CAP/$LABEL.png" >/dev/null 2>&1
ffmpeg -y -loglevel error -ss $GIF_SS -t $GIF_T -i "$CAP/$LABEL-raw.mp4" -filter_complex "$CROP,fps=$FPS,$SCALE,split[a][b];[a]palettegen[p];[b][p]paletteuse" "$CAP/$LABEL-motion.gif" >/dev/null 2>&1
# duplicate-gating evidence: count distinct outbound sends to the group this turn (prompt echo=1; a
# duplicate final would be a 2nd send AFTER the run completes — the fix prevents it).
SENDS=$(grep -cE "outbound send ok.*$GID.*sendMessage" "$CAP/gw-$LABEL.log" 2>/dev/null || echo "?")
echo "group outbound sendMessage count this run: $SENDS  (expect: 1 prompt-echo; response streams via edits; NO duplicate final)"
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill "$pid" 2>/dev/null; done
pkill -f "streammock.mjs" 2>/dev/null||true; pkill -x Telegram 2>/dev/null||true; pkill -x openbox 2>/dev/null||true; pkill -x Xvfb 2>/dev/null||true
echo "MANTIS_ECHO_DONE $LABEL png=$(stat -c%s "$CAP/$LABEL.png" 2>/dev/null||echo 0) gif=$(stat -c%s "$CAP/$LABEL-motion.gif" 2>/dev/null||echo 0) mid=$MID sends=$SENDS"
