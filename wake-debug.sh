#!/bin/bash
# FAST headless debug of the #83738 wake chain — no desktop, no video, no blind waits.
# Watches the DEBUG gateway log for each stage: inbound -> cron wake RPC -> heartbeat
# -> outbound send (with message_thread_id). Args: $1=payload $2=LABEL $3=BUILDDIR
set -uo pipefail
CAP=/tmp/cap; PAY="${1:?}"; LABEL="${2:?}"; BUILDDIR="${3:?}"
GID=-1003900553563
cd "$BUILDDIR"
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill "$pid" 2>/dev/null; done
sleep 2; pkill -f "claude --output-format stream-json" 2>/dev/null||true
for pid in $(pgrep -f "run-node.mjs gateway" 2>/dev/null) $(pgrep -x openclaw 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
pkill -f "telegram-user-driver" 2>/dev/null||true; fuser -k "$CAP/driver/db/td.binlog" 2>/dev/null||true
sleep 2; mkdir -p "$CAP/state-$LABEL"
SUT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sutToken'])" "$PAY")
BOTUID=${SUT%%:*}
curl -s "https://api.telegram.org/bot$SUT/deleteWebhook?drop_pending_updates=true" >/dev/null || true

cat > "$CAP/openclaw-$LABEL.json" <<CONF
{ "logging": { "level": "debug" },
  "agents": { "defaults": { "model": "claude-cli/claude-sonnet-4-6", "thinkingDefault": "low", "workspace": "$BUILDDIR",
  "heartbeat": { "every": "1h", "target": "last" },
  "cliBackends": { "claude-cli": { "command": "claude", "input": "stdin", "maxPromptArgChars": 1, "sessionMode": "always", "systemPromptMode": "replace",
    "args": ["-p","--output-format","stream-json","--include-partial-messages","--verbose","--setting-sources","user","--permission-mode","bypassPermissions"] } } } },
  "auth": { "order": { "anthropic": ["anthropic:claude-cli"] } },
  "gateway": { "port": 18789, "mode": "local", "bind": "loopback", "auth": { "mode": "token", "token": "test-token" } },
  "channels": { "telegram": { "enabled": true, "groupPolicy": "open", "groups": { "$GID": { "requireMention": false } },
    "botToken": { "id": "TELEGRAM_BOT_TOKEN", "provider": "default", "source": "env" }, "streaming": { "mode": "off" } } },
  "tools": { "profile": "coding", "exec": { "security": "full", "ask": "off" } },
  "plugins": { "entries": { "anthropic": {"enabled": true}, "browser": {"enabled": false}, "codex": {"enabled": false} } } }
CONF
GW="$CAP/gw-$LABEL.log"
OPENCLAW_CONFIG_PATH="$CAP/openclaw-$LABEL.json" OPENCLAW_STATE_DIR="$CAP/state-$LABEL" TELEGRAM_BOT_TOKEN="$SUT" OPENCLAW_GATEWAY_TOKEN=test-token \
  pnpm openclaw gateway --port 18789 --allow-unconfigured > "$GW" 2>&1 &
for i in $(seq 1 30); do grep -aqE "\[gateway\] ready" "$GW" && break; sleep 3; done
grep -aqE "\[gateway\] ready" "$GW" || { echo "GATEWAY NOT READY"; tail -5 "$GW"; exit 1; }
echo "[gateway up after ~$((i*3))s]"

export TELEGRAM_USER_DRIVER_STATE_DIR="$CAP/driver"
export TELEGRAM_USER_DRIVER_TDLIB_PATH="$(node -e "console.log(require('/tmp/node_modules/prebuilt-tdlib').getTdjson())")"
export TELEGRAM_USER_DRIVER_API_ID="$(python3 -c "import json;print(json.load(open('$PAY'))['telegramApiId'])")"
export TELEGRAM_USER_DRIVER_API_HASH="$(python3 -c "import json;print(json.load(open('$PAY'))['telegramApiHash'])")"
export TELEGRAM_USER_DRIVER_DB_ENCRYPTION_KEY="$(python3 -c "import json;print(json.load(open('$PAY'))['tdlibDatabaseEncryptionKey'])")"

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
try:
    d.client.request({"@type": "loadChats", "chat_list": {"@type": "chatListMain"}, "limit": 50}, timeout=20)
except Exception:
    pass
time.sleep(2)
req({"@type": "getChat", "chat_id": GID})
req({"@type": "toggleSupergroupIsForum", "supergroup_id": SGID, "is_forum": True, "has_forum_tabs": False})
time.sleep(1)
topic = req({"@type": "createForumTopic", "chat_id": GID, "name": f"DBG-83738 {sys.argv[1]}",
             "icon": {"@type": "forumTopicIcon", "color": 0x6FB9F0, "custom_emoji_id": "0"}})
info = topic.get("info", topic) if isinstance(topic, dict) else {}
print(int(info.get("message_thread_id") or 0))
PYTOPIC
)
TID=$(echo "$TID" | tail -1)
echo "[topic] thread_id=$TID"
[ -z "$TID" ] || [ "$TID" = "0" ] && { echo "FAIL: no topic"; exit 1; }

SCENARIO='Call the openclaw "cron" tool exactly once with arguments {"action":"wake","mode":"now","text":"Reply with exactly: PROOF-83738 wake delivered"}. Do not use any other scheduling or task tool. Then reply with exactly: scheduled.'
python3 scripts/e2e/telegram-user-driver.py send --chat "$GID" --thread-id "$TID" --text "$SCENARIO" --timeout-ms 30000 >/dev/null 2>&1
echo "[sent] scenario into topic $TID at $(date -u +%T)"

# Active log watch: print each chain stage the moment it appears; hard deadline 150s.
watch_stage(){ local name="$1" pat="$2" deadline="$3"
  local until=$(( $(date +%s) + deadline ))
  while [ "$(date +%s)" -lt "$until" ]; do
    if grep -aqE "$pat" "$GW"; then echo "[stage OK] $name:"; grep -aE "$pat" "$GW" | head -3; return 0; fi
    sleep 3
  done
  echo "[stage MISSING after ${deadline}s] $name (pattern: $pat)"; return 1
}
watch_stage "inbound from topic"      "telegram.*(inbound|message).*topic|topic.*$TID|message_thread_id.*$TID" 40
watch_stage "agent turn started"      "cli exec: provider=claude-cli" 90
watch_stage "cron wake RPC"           "\"method\":\"wake\"|method=wake|cron.*wake|wake.*(rpc|request|enqueue)" 150
watch_stage "heartbeat triggered"     "trigger=heartbeat" 120
watch_stage "outbound send to topic"  "sendMessage.*$TID|message_thread_id.*$TID.*send|telegram.*send.*thread|deliver.*$TID" 90

echo "=== last 40 interesting log lines ==="
grep -aivE "getUpdates|poll" "$GW" | tail -40
