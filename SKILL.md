---
name: local-mantis
description: >
  Capture a Telegram-visible "mantis-level" proof for an openclaw PR locally (Windows), the way
  ClawSweeper's @openclaw-mantis bot would — telegram-desktop + user-driver + screen recording, run
  in a local-container crabbox box. Use this WHENEVER a PR needs a telegram/webchat behavior proof
  (live streaming, persistProgress, commentary, channel-echo) instead of hand-rolling a box, a
  gateway, a capture, or "wiring up". Everything is already baked into the scripts below.
---

# local-mantis — Telegram-visible PR proof, locally

**Do not re-derive this.** The crabbox box + desktop capture + deep-link framing + crop calibration
+ all the gotchas are baked into the scripts. Pick the variant, run it, export the artifact.

## Assets (host)
- Capture scripts: `C:\Users\Cameron\clawd\.agents\skills\local-mantis\`
  - `mantis-dm.sh <payload> <LABEL> <SCENARIO> <persist-on|persist-off|commentary|separate|plain>` — bot **DM** render (e.g. #89850 persistProgress, #89834 commentary).
  - `mantis-group.sh <payload> <LABEL> <SCENARIO> <streamkey>` — **native** supergroup reply (driver sends a telegram msg, films the in-group reply).
  - `mantis-echo.sh <payload> <LABEL> <SCENARIO>` — **#88815 channel-echo**: webchat `chat.send` → echoed live into the supergroup. Webchat-origin drive + deterministic streaming mock; the rest identical.
  - `mantis-topic-wake.sh <payload> <LABEL> <BUILDDIR>` — **#83738 forum-topic cron-wake**: creates a forum topic, drives a cron-wake scenario in it, films the wake reply landing back in the topic. BUILDDIR selects before (`/opt/openclaw-main`) vs after (`/opt/openclaw`) builds.
  - `wake-debug.sh <payload> <LABEL> <BUILDDIR>` — **FAST headless chain-debug** (no video/desktop): debug-level gateway log + per-stage watch loop. **ALWAYS run this FIRST and only record video once every stage passes** — never idle-poll telegram waiting for a message the broken chain will never send.
  - `make-group.py` — (re)create the proof supergroup + add/promote bot #2.
- Crabbox job (leases the desktop box, clones+builds the PR): `C:\Users\Cameron\crabbox-proof\crabbox.yaml` (jobs `proof-88815-echo`, `proof-89834`; template to copy per PR).
- Crabbox CLI (Windows): `C:\Users\Cameron\clawd\.crabbox-allpr\crabbox.exe` (use `dangerouslyDisableSandbox` — it drives docker). The `.crabbox-206/crabbox-bin` is a Linux ELF — ignore on Windows.

## Credentials (already on host — never reinvent, never cat)
- Test bot **#2** token: `~/.openclaw/crabbox-test.env` (`TELEGRAM_BOT_TOKEN`). Job: `envFromProfile` (ABSOLUTE path `C:\Users\Cameron\.openclaw\crabbox-test.env`) + `allowEnv:[TELEGRAM_BOT_TOKEN]`. **NEVER the daily-driver bot — 409 → daily-driver outage.** (`@JeeevesOpenClawTelegram2bot` = id 8685483103 = the safe one; verify with getMe before any send.)
- Telegram observer tdata: `~/.openclaw/tg-tdata.tgz` → restore into the box's Telegram Desktop (`$CAP/driver` = tdlib auth; `$CAP/tdata` = desktop workdir). Supergroup **-1003900553563** (bot #2 admin).
- Claude agent auth (if using a real claude-cli model, not the mock): copy host `~/.claude/.credentials.json` → box, and **run a 15s host→box sync loop for the capture duration** — the host auto-rotates the token (~hourly) so a one-time copy goes stale mid-run → 401. Mock model (mantis-echo default) avoids this entirely.

## Procedure
1. **Host preflight FIRST**: `bash C:\Users\Cameron\clawd\.agents\skills\local-mantis\preflight-host.sh [budget-gb]` - checks host C: free and docker-VM internal free against the job's anticipated footprint (dual openclaw build + captures ~= 15GB), and probes the bot token for a competing poller (409). Jobs also carry an in-box `[0/N]` df gate. NEVER launch a build job without this (2026-06-10: C: hit 100% mid-batch, engine collapsed, box unrecoverable).
2. **Lease + build the box** (desktop:true): `cd /c/Users/Cameron/crabbox-proof && crabbox.exe job run proof-<pr>` (deps-base checkpoint image at ROOT of yaml — plain ubuntu → `ERR_NO_TYPESCRIPT`). For a **current-head** proof, point the job's checkout at the PR head you actually want (push your fix to the PR branch first, or `git fetch pull/<pr>/head`).
3. **Stage** payload.json + tdata into the box; for a real model, start the creds sync loop.
4. **Capture**: run the matching `mantis-*.sh` inside the box. It cleans orphans, drains the bot's pending updates (`deleteWebhook?drop_pending_updates=true`), writes config, starts the gateway, opens telegram-desktop under a WM with geometry applied BEFORE recording, drives the scenario on a FRESH `/new` session, deep-link frames the reply, and emits `<LABEL>.png` + `<LABEL>-motion.gif` under `/tmp/cap`.
5. **Export** the png/gif to the host for the PR body (`docker cp` is flaky on Windows Docker Desktop — use `docker exec -i … 'cat > …'` / `base64`; see crabbox-windows-docker-cp-bug note). PUBLISH = just attach to the PR (no R2 needed).
6. **In the PR body, state explicitly** it's a recreation of the Mantis telegram-desktop-proof flow using the patched local crabbox (same mechanism: telegram-desktop + user-driver + screen capture, run locally) — so ClawSweeper reads it as Mantis-equivalent E2E, not an ad-hoc screenshot.

## Hard-won gotchas (already coded in the scripts; here so you don't undo them)
- Geometry must be applied BEFORE ffmpeg starts (else the motion file shows the maximized default).
- `/new` a FRESH session before the scenario (else it answers from memory).
- `--from-bot` = the BOT USER ID (`sutToken.split(':')[0]`), NOT the chat/group id.
- Crop is calibrated to OUR telegram-desktop build (`435:920:285:78` @ 720x1050 maximized), NOT the cloud Mantis absolute constants.
- Deep-link post id = tdlib msgid `>> 20` (server id); only works in a `-100` supergroup.
- NEVER `rm -rf $CAP/driver` (tdlib auth) — only clear `$CAP/state`.
- A failed run leaves unconsumed updates → next gateway replays them → wrong reply captured. The `deleteWebhook` drain prevents it.
- In-box gateway run as `crabbox` auto-rebuilds if the tree is git-dirty and hits EACCES on root-owned `dist`/`.git` — commit in-box + `chown -R crabbox:crabbox` after any in-box source change.
- `docker rm` with a `crab` grep matches ALL crabbox-* boxes — match the FULL box name.
- The in-box gateway reads the config from the HOME of the user it runs as — run it as the right user (`HOME=/home/crabbox`) or it silently runs unconfigured (wrong session store, ignores controlUi → device-identity rejection).

## Box provisioning from scratch (when no deps checkpoint image exists)
Checkpoint image first: `docker images | grep crabbox-checkpoint` (latest good: `crabbox-checkpoint-oc-deps-83738-fixed`). If none, plain `ubuntu:24.04` works with:
- apt: `git curl ca-certificates python3 sudo xvfb openbox wmctrl ffmpeg psmisc dbus-x11 xz-utils x11-utils` + GUI libs `libgtk-3-0t64 libglib2.0-0t64 libxkbcommon-x11-0 libnss3 libasound2t64 libxcb-* ` + **`libopengl0 libglvnd0 libgl1-mesa-dri`** — *without `libopengl0` Telegram Desktop runs but maps NO window → captures are silently BLACK; this cost a whole re-shoot.*
- node 22 (NodeSource) + `pnpm@11.2.2`; create user `crabbox` + sudoers.
- Telegram Desktop: official tarball `https://telegram.org/dl/desktop/linux` → `/opt/Telegram`; **`chown -R crabbox /opt/Telegram`** (root-owned ⇒ auto-updater crashes the app: `_basePath is empty in writeSettings()`).
- `pnpm install` in boxes MUST run with **`CI=true`** (pnpm v11 prompts "modules dir purge?" with no TTY and silently hangs FOREVER — this masqueraded as a 50-min network wedge).
- tdlib for the driver: `npm i prebuilt-tdlib@td-1.8.14` in /tmp; resolve the .so via `require('prebuilt-tdlib').getTdjson()` (path differs per version). System 1.8.0 lacks forum-topic APIs.
- Driver patch for tdlib ≥1.8.6 (both checkouts): `td_params_current()` must put the db key INSIDE `setTdlibParameters` as `database_encryption_key`, passing the configured key string VERBATIM (re-encoding it = "Wrong database encryption key").
- After provisioning + first green run: **`docker commit` a new checkpoint immediately** (no `timeout` wrapper — commit pauses the container; a timeout kill leaves it paused).

## Capture preflight (all baked into the scripts — keep them there)
1. `wake-debug.sh` (or scenario equivalent) green BEFORE any video run.
2. Gateway readiness = wait-loop on `[gateway] ready` (fixed sleeps race cold starts).
3. Driver state sanity: `$CAP/driver/db` must exist — a partial unpack (only `files/`) passes naive "dir non-empty" checks; re-unpack from payload if missing. Stale `td.binlog` locks: `fuser -k`.
4. Telegram window check before recording: `xwininfo -root -tree` must list a "Telegram" window; a live process with 0 windows = missing GL/tray-hidden = black video.
5. Config MUST include `agents.defaults.heartbeat: {"every":"1h","target":"last"}` for any wake/heartbeat-reply scenario — without it the heartbeat turn runs and its reply is silently dropped.
6. Scenario phrasing: frame as the USER's own test intent ("I am testing X, please…"). Imperative "Call tool X with args {...} and reply exactly Y" gets refused as prompt injection nondeterministically.
7. GIF export: palette + fps 6 + scale 380 (`palettegen/paletteuse`) — naive full-fps GIFs hit 200MB; GitHub caps ~10MB. mp4s attach fine.
8. New supergroup chats on a fresh tdlib session need `loadChats` + `getChat` before `toggleSupergroupIsForum`/`createForumTopic` ("Supergroup not found").
9. Host disk space ≥ 60GB free before dual in-box builds — a full disk corrupted the Docker VHDX and destroyed the checkpoint images once already.

## More capture preflight lessons (2026-06-10 v3 session)
10. **NEVER `pkill -f <pattern>` from an inline `bash -c` whose command line contains the pattern** — it SIGKILLs its own shell (exit 137). Three separate incidents. Patterns must live in a script FILE.
11. Telegram Desktop window mapping in the box can take **2–4 minutes** (llvmpipe + cold sync), and a WM-less session can persist a degenerate 10x10 geometry. Preflight wait ≥ 4 min; `apply_geom` fixes size once mapped; record AFTER the window check, not on a fixed schedule.
12. `claude live session turn failed … error=FailoverError` in the box = **stale OAuth creds** (host rotates ~hourly). Re-copy `~/.claude/.credentials.json` and keep the 15s sync loop running for the WHOLE capture session, not just 40 min.
13. When the monolithic capture script misbehaves, fall back to **phased orchestration** (phase1 gateway / phase2 desktop-with-verified-window / phase3 topic+record+drive), verifying state between phases — much easier to debug than one 120-line bash -lc.
14. Tool-bearing wake proof: have the wake text instruct the woken turn to run `date -u` via exec and embed the output — distinguishes "a real second agent turn ran" from "a delayed canned reply" on video.


## Lessons from the verbose-commentary proof (2026-06-10, 4 takes — all env, zero feature)
15. **Deriving a new mantis-*.sh variant? Derive its PREFLIGHT too, not just its capture.** The 4-take session happened because mantis-dm.sh (the template) lacks the `chats --json` warmup that mantis-capture.sh has, and there was no DM-flow equivalent of wake-debug.sh. Headless-debug-first applies to EVERY variant.
16. **Before any capture: probe for a competing poller.** `curl getUpdates` with a 1s timeout — a 409 means some other box/process owns the token (this time: a week-old `oc83738` container still running). `docker ps` and kill stale proof containers FIRST.
17. **tdlib for the driver lives at `/tmp/node_modules/prebuilt-tdlib/prebuilds/tdlib-linux-x64/libtdjson.so` in the checkpoint** — the driver only probes system paths; always `export TELEGRAM_USER_DRIVER_TDLIB_PATH` (now baked into mantis-verbose.sh).
18. **A fresh/checkpointed tdlib session is wait-blind until `chats --json` runs** (gotcha #8 strikes again); and right after the warmup the unread backlog replays as `updateNewMessage`, so **anchor waits with `--after-message-id <id-of-the-message-you-just-sent>`** or a stale reply satisfies the wait (now baked into mantis-verbose.sh).
19. **`-workdir D` means auth lives at `D/tdata/key_datas` — NEVER flatten the nesting** when unpacking `desktopTdataArchiveBase64` (stage-box.sh now FATALs if the layout is wrong). Symptom of a broken workdir: Telegram boots to the "Start Messaging" login screen.
20. **Identical png byte-sizes across takes = you are screenshotting the same dead screen. LOOK at the first artifact immediately** — reading the image after take 1 would have saved two takes.
21. The gateway log (`sendMessage ok chat=… message=N`) is ground truth that the run worked — check it BEFORE blaming the agent side; the driver `wait` consumes raw `updateNewMessage` with no history fallback, so an empty `observed` usually means the OBSERVER is broken, not the bot.
22. **pnpm in crabbox jobs needs `< /dev/null` AND `timeout 600`, not just `CI=true`.** The job's ssh session has stdin open-but-not-a-TTY; some pnpm v11 prompts ignore CI=true and block reading that stdin forever (38-min wedge, 2026-06-10; identical install completed in seconds with stdin at EOF). Close stdin on every pnpm invocation in job scripts and time-budget the step so a wedge fails fast.
