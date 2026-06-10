# local-mantis

Capture a **Telegram-visible, mantis-grade behavior proof** for an openclaw PR — locally, the way ClawSweeper's `@openclaw-mantis` bot would: a real telegram-desktop observer + a user-driver + screen recording, all running inside a disposable [crabbox](https://github.com/openclaw/crabbox) box.

Use this whenever a PR needs live channel-behavior proof (streaming, persistProgress, commentary lanes, channel echo) instead of hand-rolling a box, a gateway, and a capture rig every time.

`SKILL.md` is the operator manual (also loadable as a Claude Code skill); the scripts are the workflow.

## Script matrix

| Script | Scenario |
|---|---|
| `mantis-dm.sh <payload> <LABEL> <SCENARIO> <mode>` | Bot **DM** render (persist-on/off, commentary, separate, plain) |
| `mantis-group.sh <payload> <LABEL> <SCENARIO> <streamkey>` | **Native supergroup reply** — driver sends a message, films the in-group reply |
| `mantis-echo.sh <payload> <LABEL> <SCENARIO>` | **Channel echo** — webchat `chat.send` echoed live into the supergroup |
| `mantis-topic-wake.sh` / `-notarget.sh` | Topic-thread wake-chain captures (heartbeat target variants) |
| `mantis-verbose.sh` | Verbose-commentary progress captures |
| `mantis-capture.sh` | The original/base capture flow |
| `run-verbose-batch.sh` | Batch driver for verbose captures |
| `preflight-host.sh` | **Run first** — executable fail-fast host preflight (docker, image, creds, disk) |
| `stage-box.sh` | Stage a capture box (checkpoint restore + deps) |
| `wake-debug.sh` | Fast headless debug loop — debug the flow *before* paying for a filmed take |
| `make-group.py` | One-time: create the observer supergroup with the bot as admin |

## Prerequisites (bring your own)

None of these are in the repo — the scripts read them from local paths:

- **crabbox CLI** + a docker `deps-base` image (not bare ubuntu — deps matter)
- **A dedicated test bot token** in an env file (`TELEGRAM_BOT_TOKEN` via `envFromProfile` + `allowEnv`). **Never your production/daily-driver bot** — two pollers on one token = getUpdates 409 conflict = outage.
- **Telegram observer tdata** (`tg-tdata.tgz`): a logged-in tdesktop session minted via QR login in a Linux box (needs GTK3+OpenGL). Portable box-to-box.
- **An observer supergroup** with the test bot as admin (`make-group.py`)
- For real claude-cli models in the box: host `~/.claude/.credentials.json` synced into the box on a 15s loop (host rotates the OAuth token ~hourly; one-time copies go stale mid-capture). The deterministic streaming mock avoids this entirely.

## Operating principles (earned the hard way — full list in SKILL.md)

1. **Preflight is executable, not prose** — `preflight-host.sh` before any box spend.
2. **Headless-debug-first** — prove the flow with `wake-debug.sh` before filming; every new `mantis-*.sh` variant needs its preflight + debug loop derived too, not just its capture.
3. **Anchor waits on your own message id** (`--after-message-id`) — fresh tdlib sessions replay unread backlog and a stale reply will satisfy a naive wait.
4. **tdlib path is never auto-found** — `TELEGRAM_USER_DRIVER_TDLIB_PATH` always set (baked into newer variants).
