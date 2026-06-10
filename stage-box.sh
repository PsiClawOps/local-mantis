#!/bin/bash
# Stage a local-mantis proof box AFTER the crabbox job built it (runs IN the box).
# Expects /tmp/cap/payload.json already copied in. Unpacks the desktop tdata +
# tdlib driver state from the payload archives. Idempotent: never touches an
# existing driver dir with a db/ (live tdlib auth), always refreshes tdata.
set -euo pipefail
CAP=/tmp/cap; PAY="$CAP/payload.json"
mkdir -p "$CAP"
python3 - "$PAY" <<'PYEOF'
import base64, hashlib, json, os, subprocess, sys
pay = json.load(open(sys.argv[1]))
cap = "/tmp/cap"

def unpack(b64key, shakey, dest, skip_if_db=False):
    if skip_if_db and os.path.isdir(os.path.join(dest, "db")):
        print(f"{dest}: existing tdlib db kept (live auth)")
        return
    raw = base64.b64decode(pay[b64key])
    digest = hashlib.sha256(raw).hexdigest()
    want = pay.get(shakey, "")
    if want and digest != want:
        raise SystemExit(f"{b64key}: sha256 mismatch ({digest} != {want})")
    tmp = os.path.join(cap, b64key + ".tgz")
    with open(tmp, "wb") as f:
        f.write(raw)
    subprocess.run(["rm", "-rf", dest], check=True)
    os.makedirs(dest, exist_ok=True)
    subprocess.run(["tar", "-xzf", tmp, "-C", dest], check=True)
    os.unlink(tmp)
    print(f"{dest}: unpacked ({len(raw)} bytes, sha ok)")

unpack("desktopTdataArchiveBase64", "desktopTdataArchiveSha256", f"{cap}/tdata")
unpack("tdlibArchiveBase64", "tdlibArchiveSha256", f"{cap}/driver", skip_if_db=True)
PYEOF
# Driver state sanity (capture preflight #3): db/ must exist after unpack.
[ -d "$CAP/driver/db" ] || { echo "FATAL: driver/db missing after unpack"; exit 1; }
# Telegram Desktop is launched with `-workdir $CAP/tdata` and expects the
# auth data NESTED at $CAP/tdata/tdata/key_datas (the archive already packs
# the `tdata/` prefix). NEVER flatten this layout — a half-flattened workdir
# silently boots to the login screen and every capture shows "Start Messaging".
[ -f "$CAP/tdata/tdata/key_datas" ] || { echo "FATAL: tdata/tdata/key_datas missing — wrong archive layout"; exit 1; }
echo "STAGE_OK tdata=$(ls "$CAP/tdata" | wc -l) driver=$(ls "$CAP/driver" | wc -l)"
