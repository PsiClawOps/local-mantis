#!/bin/bash
# Runs the four verbose-commentary proof captures sequentially IN the box.
# Scenario text lives here (not in a host-side quoted arg) to avoid shell-quoting bugs.
set -uo pipefail
PAY=/tmp/cap/payload.json
SCEN="I am testing my bot's progress display. Please run a small two-step check: first run date -u with your exec tool, then run uname -a, then finish with a one-line summary of both outputs. Briefly tell me what you are about to do before each command."
run() {
  local label="$1" key="$2" build="$3"
  echo "=== CAPTURE $label ($key, $build) ==="
  bash /tmp/mantis-verbose.sh "$PAY" "$label" "$SCEN" "$key" "$build" 2>&1 | tail -3
}
run after-stream-off  verbose-stream-off /opt/openclaw
run after-stream-on   verbose-stream-on  /opt/openclaw
run before-stream-off verbose-stream-off /opt/openclaw-main
run before-stream-on  verbose-stream-on  /opt/openclaw-main
echo "BATCH_DONE"
ls -la /tmp/cap/*.png /tmp/cap/*-motion.gif 2>/dev/null | awk '{print $5, $9}'
