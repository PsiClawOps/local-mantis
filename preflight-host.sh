#!/bin/bash
# HOST-side preflight for local-mantis crabbox proof jobs. Run BEFORE `crabbox.exe job run`.
# Anticipates the job's disk footprint so the Docker engine cannot collapse mid-capture
# (2026-06-10: C: hit 100% during a dual-build batch, engine died, box unrecoverable).
# Usage: preflight-host.sh [job-budget-gb] [bot-env-file]
#   job-budget-gb: expected CoW footprint of the job (default 15 = dual openclaw build + captures)
set -uo pipefail
export MSYS_NO_PATHCONV=1   # git-bash rewrites "/" args into the Git install dir — breaks in-container df
BUDGET_GB="${1:-15}"
ENVFILE="${2:-$HOME/.openclaw/crabbox-test.env}"
FAIL=0

# 1) Host drive free space: the docker VHDX grows on C:; demand budget + 10GB margin.
HOST_FREE_GB=$(python3 - <<'PY'
import shutil
print(shutil.disk_usage("C:\\").free // (1024**3))
PY
)
NEED_HOST=$((BUDGET_GB + 10))
if [ "$HOST_FREE_GB" -lt "$NEED_HOST" ]; then
  echo "FAIL: C: has ${HOST_FREE_GB}GB free; job needs ~${NEED_HOST}GB (budget ${BUDGET_GB} + 10 margin)."
  echo "      NOTE: if docker system df shows big reclaimables, freeing them gives the VM"
  echo "      internal headroom (VHDX stops growing) even though C: free doesn't change."
  FAIL=1
else
  echo "ok: host C: free ${HOST_FREE_GB}GB >= ${NEED_HOST}GB"
fi

# 2) Docker VM internal free space (the binding constraint once the VHDX is large).
# Prefer df inside an already-running container (works with zero free space);
# fall back to a throwaway alpine run.
RUNNING=$(docker ps -q | head -1)
# POSIX df -Pk (KB) — busybox containers lack GNU -BG.
if [ -n "$RUNNING" ]; then
  VM_FREE_GB=$(docker exec "$RUNNING" df -Pk / 2>/dev/null | awk 'NR==2{print int($4/1048576)}')
else
  VM_FREE_GB=$(docker run --rm alpine df -Pk / 2>/dev/null | awk 'NR==2{print int($4/1048576)}')
fi
if [ -z "${VM_FREE_GB:-}" ]; then
  echo "WARN: could not read docker VM free space (engine down?)"
  FAIL=1
elif [ "$VM_FREE_GB" -lt "$BUDGET_GB" ]; then
  echo "FAIL: docker VM has ${VM_FREE_GB}GB free < job budget ${BUDGET_GB}GB. Prune dead"
  echo "      containers/images first (docker ps -as; docker system df)."
  FAIL=1
else
  echo "ok: docker VM free ${VM_FREE_GB}GB >= ${BUDGET_GB}GB"
fi

# 3) Competing getUpdates poller on the test bot (lesson #16: a stale box = 409 death-loop).
if [ -f "$ENVFILE" ]; then
  TOKEN=$(sed -n "s/^TELEGRAM_BOT_TOKEN=//p" "$ENVFILE" | tr -d "\r\"' ")
  if [ -n "$TOKEN" ]; then
    CODE=$(curl -s -m 8 "https://api.telegram.org/bot${TOKEN}/getUpdates?timeout=0&limit=1" | python3 -c "import json,sys;d=json.load(sys.stdin);print('ok' if d.get('ok') else d.get('error_code'))" 2>/dev/null || echo probe-failed)
    if [ "$CODE" = "409" ]; then
      echo "FAIL: bot token already polled elsewhere (409). Find it: docker ps; kill the stale box."
      FAIL=1
    else
      echo "ok: bot getUpdates probe: $CODE (no competing poller)"
    fi
  fi
fi

[ "$FAIL" -eq 0 ] && echo "PREFLIGHT_OK" || { echo "PREFLIGHT_FAILED"; exit 1; }
