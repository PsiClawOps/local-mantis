# Mantis Architecture Review — Building a Clickclack Proof-Capture System

**Author:** Chisel (Product)
**Date:** 2026-06-10
**Repo:** PsiClawOps/local-mantis (fork of the OpenClaw Mantis local-capture workflow)
**Status:** Analysis + implementation plan. No code changed in this pass.

---

## TL;DR

The `local-mantis` fork is a working, battle-tested rig for capturing **Telegram-visible, video-grade behavior proof** of an OpenClaw change, run entirely on local Docker through Crabbox. The mechanism is sound and reusable. The Telegram coupling is real but shallow: it lives in three swappable layers (the **observer**, the **driver**, and the **render geometry**). Everything else, the disposable box, the in-box gateway, the record-while-driving loop, the crop/motion-GIF pipeline, the preflight discipline, is channel-agnostic and worth keeping verbatim.

Our actual target is not Telegram. It is **high-quality clickclack proof**: a real clickclack surface, a real user driving it, the agent responding live, captured as screenshot + motion GIF + transcript, suitable for a PR body or a product demo. This document maps what we keep, what we replace, and the concrete steps to build a `clickclack` edition.

The single biggest open question is the **observer**: Telegram gives us a native desktop client (tdesktop) we can film. Clickclack's equivalent is its **web UI**, so the observer becomes a headless-but-visible browser pointed at the clickclack web client, driven and filmed the same way. That is the load-bearing design decision, and it is favorable: a browser observer is easier to provision than a logged-in tdesktop session, and it removes the entire tdata/tdlib credential apparatus.

---

## 1. What Mantis Actually Is

"Mantis" upstream is OpenClaw's end-to-end behavior-proof system. The idea: prove a change does what it claims by running the **real runtime** over the **real transport**, on a known-bad baseline ref and a candidate ref, and publishing **visible before/after evidence** (screenshots, video, GIFs, redacted transcripts) that a maintainer can open from a PR.

The cloud Mantis bot (`@openclaw-mantis`) does this in CI. The `local-mantis` fork does the same thing **locally on Docker via Crabbox**, so an operator (or an agent) can mint the same caliber of proof without waiting on CI infra or shared cloud capacity.

The proof has two ingredients that matter for us:

1. **Real transport, real render.** Not a screenshot of a unit test. An actual message goes over an actual channel, the actual agent answers, and the actual client UI renders it. That is what makes it compelling.
2. **Motion.** A trimmed GIF showing the answer *arriving* (streaming tokens, progress drafts, tool-status chips updating) is far more persuasive than a static still. Most of the engineering effort in this repo is about making that motion clean and small enough to attach to a PR.

For PsiClawOps, both ingredients map directly onto our need: we want compelling **proof that our product works**, captured from a real surface, for PR review and for demos.

---

## 2. Architecture of the Existing System

The rig decomposes into seven layers. I am labeling them so the rest of this doc can refer to them precisely.

```
┌─────────────────────────────────────────────────────────────────┐
│ L0  HOST ORCHESTRATION   preflight-host.sh, crabbox job, export   │
│     - disk/credential/poller preflight, lease the box, stage,     │
│       run capture, pull artifacts back to host for the PR         │
├─────────────────────────────────────────────────────────────────┤
│ L1  DISPOSABLE BOX       crabbox local-container (Docker)         │
│     - ubuntu + node + pnpm + GUI libs + ffmpeg + the client       │
│     - checkpoint image so we don't reprovision every run          │
├─────────────────────────────────────────────────────────────────┤
│ L2  SUT GATEWAY          in-box `openclaw gateway` (the thing    │
│     under test)          we are proving), isolated config + state  │
├─────────────────────────────────────────────────────────────────┤
│ L3  TRANSPORT            Telegram Bot API  ◄── SWAPPABLE          │
│     - bot token, channel/group, streaming config                  │
├─────────────────────────────────────────────────────────────────┤
│ L4  OBSERVER             telegram-desktop (tdesktop)  ◄── SWAP    │
│     - logged-in client we FILM; the surface that renders          │
├─────────────────────────────────────────────────────────────────┤
│ L5  DRIVER               telegram-user-driver (tdlib)  ◄── SWAP   │
│     - the "user" that sends the prompt + waits for the reply      │
├─────────────────────────────────────────────────────────────────┤
│ L6  CAPTURE              Xvfb + WM + ffmpeg x11grab + crop +      │
│     (channel-agnostic)   palette GIF + deep-link framing          │
└─────────────────────────────────────────────────────────────────┘
```

### L0 — Host orchestration
`preflight-host.sh` is an executable fail-fast gate: host disk free, Docker VM internal free, and a probe for a competing `getUpdates` poller (a 409 means another box owns the bot token). The crabbox job leases the box and builds the PR. `stage-box.sh` unpacks credentials/state into the box. The capture script runs. Artifacts (`<LABEL>.png`, `<LABEL>-motion.gif`) get pulled back to the host for the PR body.

**Keep:** the philosophy and the structure. Preflight-is-executable is the most important operating principle in the whole repo and it is channel-agnostic.

### L1 — Disposable box
A Crabbox `local-container` lease: an Ubuntu container on local Docker with node 22, pnpm, GUI libraries (critically including `libopengl0` — without it the GUI app maps no window and captures are silently black), ffmpeg, a window manager, and the client app. A `docker commit` checkpoint image avoids reprovisioning on every run.

**Keep:** entirely. This is the crabbox layer, covered in depth in the companion doc in the crabbox fork.

### L2 — SUT gateway
An isolated `openclaw gateway` running inside the box on a loopback port, with a hand-written `openclaw.json` that wires up exactly the channel + streaming config under test, a deterministic model (a streaming mock or a real claude-cli backend), and `dangerouslyDisableDeviceAuth` for the control UI. State dir is wiped per run; the bot's pending updates are drained so a prior run's messages don't replay.

**Keep:** the pattern (isolated config, wiped state, drained backlog, deterministic model). **Replace:** the `channels.telegram` block with a `channels.clickclack` block.

### L3 — Transport (SWAPPABLE)
Telegram Bot API. Token from env, `dmPolicy`/`groupPolicy`, streaming mode. This is where "it's Telegram" first appears in config.

**Replace:** with clickclack's channel/account config.

### L4 — Observer (SWAPPABLE, load-bearing)
A logged-in Telegram Desktop client, restored from a portable `tdata` archive, launched under Xvfb with calibrated window geometry. This is the surface we film. It is the single hardest thing to provision (QR-login a tdesktop in a Linux box, archive the session, restore it per box) and the source of most gotchas (GL libs, workdir nesting, login-screen-on-broken-workdir).

**Replace:** with a **clickclack web client in a browser**. This is the central adaptation and is detailed in §4.

### L5 — Driver (SWAPPABLE)
`telegram-user-driver.py` (a tdlib client acting as the "user"): sends the scenario prompt, then `wait`s for the bot's reply, anchored on the message id it just sent (`--after-message-id`) so backlog replay can't satisfy a naive wait. Outputs an `observed.json` with the reply's message id, used to deep-link-frame the reply in the observer.

**Replace:** with a clickclack send/wait driver. For clickclack this can be either an API-level driver (send via clickclack's send API, poll for the assistant reply) or a UI-level driver (type into the same browser we're filming). Detailed in §4.

### L6 — Capture (channel-agnostic)
Xvfb + window manager + `ffmpeg x11grab` recording while the scenario is driven, then a calibrated `crop` to the conversation column, a lanczos `scale`, and a palettegen/paletteuse GIF trimmed to the build-and-reply window (so the GIF isn't mostly static). Stills via a single-frame grab; motion via the trimmed GIF. Deep-link framing re-opens the exact reply so the crop lands on it.

**Keep:** almost verbatim. The only per-channel tuning is the crop rectangle (calibrated to the rendered conversation column) and the GIF trim window (calibrated to the scenario's reply timing). Both are constants we re-derive once for the clickclack surface.

---

## 3. The Hard-Won Lessons (and which ones survive the channel swap)

The SKILL.md encodes ~22 lessons paid for in re-shoots. They sort into three buckets:

**Channel-agnostic (keep all of these — they are the real value):**
- Preflight is executable, not prose. Run it before any box spend.
- Headless-debug-first: prove the chain with a fast no-video loop before filming. Every new capture variant needs its own preflight + debug loop derived, not just its capture.
- Geometry/crop must be applied BEFORE ffmpeg starts, or the motion file shows the wrong layout.
- Window-mapping can take minutes on llvmpipe; verify a real window exists (`xwininfo`) before recording, or you film a black screen.
- GIF export must use palette + low fps + scale, or you blow past GitHub's ~10MB cap.
- Identical PNG byte-sizes across takes = you're screenshotting the same dead screen. Look at the first artifact immediately.
- Never `pkill -f <pattern>` from an inline shell whose own command line contains the pattern (it SIGKILLs its own shell). Patterns live in script files.
- The gateway log (`sendMessage ok` / equivalent) is ground truth that the run worked; check it before blaming the agent side.
- Disk discipline: a full disk corrupted the Docker VHDX and destroyed checkpoint images.
- `pnpm` in non-TTY box sessions needs `CI=true` AND closed stdin AND a timeout, or it wedges forever.
- Frame scenarios as the user's own intent ("I am testing X, please…"), not imperative tool commands (which get refused as injection nondeterministically).

**Telegram-specific (these DISAPPEAR with the channel swap — a net simplification):**
- tdata/tdlib credential apparatus, QR login, workdir nesting, db-encryption-key handling.
- `deleteWebhook?drop_pending_updates=true` backlog drain (Telegram-specific transport quirk).
- 409 competing-poller detection (Telegram bot tokens are single-poller).
- Deep-link post-id math (`tdlib msgid >> 20`), `-100` supergroup requirements, forum-topic APIs.
- `--from-bot` = bot user id not chat id; `tg://resolve` / `tg://privatepost` deep links.

**New clickclack-specific (we will pay these down once):**
- Clickclack web-client login/session persistence in a box (cookie/localStorage archive instead of tdata).
- Clickclack send/wait API shape (or the DOM selectors if we drive via UI).
- The crop rectangle and GIF trim window for the clickclack conversation surface.
- Whether clickclack streaming renders as message edits (like the echo lane) or append-only, which changes what the motion GIF should show.

The trade is favorable: we delete a large, fragile, credential-heavy Telegram-desktop apparatus and replace it with a browser, which Crabbox already knows how to provision (`--browser`, `--desktop`) and film.

---

## 4. The Clickclack Edition — Design

### 4.1 Observer: browser instead of tdesktop

Clickclack has no native desktop client to film; its user surface is the **web UI**. So the observer becomes a Chromium instance, launched under the same Xvfb + WM, pointed at the clickclack web client, logged into a dedicated test account, framed to the conversation, and filmed exactly as tdesktop is today.

Two sub-options for "logged in":

- **(A) Session archive (mirrors today's tdata pattern).** Log into the clickclack web client once in a box, archive the browser profile (cookies + localStorage + IndexedDB), restore it per box. Same shape as `tg-tdata.tgz`, but a browser profile dir. Crabbox's local-container `--browser` already pins a per-lease profile; we layer a restored authenticated profile on top.
- **(B) Token/deep-link auth.** If the clickclack web client accepts a session token or a magic-link style URL, the box opens the client already authenticated, no profile archive needed. This is strictly better if clickclack supports it; check the clickclack web client's auth surface before committing to (A).

**Recommendation:** target (B) if clickclack's web client supports headless/token auth; fall back to (A) (profile archive) otherwise. Either way, the entire tdlib/tdata layer is gone.

### 4.2 Driver: API send vs UI type

- **API driver (preferred for determinism).** Send the scenario prompt through clickclack's send path (the same one OpenClaw's clickclack channel uses outbound/inbound), then wait for the assistant message, anchored on the id of the message we just posted (same anti-backlog discipline as `--after-message-id`). This is the clickclack analog of `telegram-user-driver.py`. It is deterministic and doesn't depend on DOM stability.
- **UI driver (more "real", more fragile).** Type into the same browser we're filming via Crabbox `desktop type` / `desktop paste` / `desktop click`. This produces the most authentic motion (you see the user typing), but couples the proof to DOM selectors.

**Recommendation:** build the **API driver first** (deterministic, matches the proven Telegram pattern), and treat the UI driver as an optional "extra realism" mode for hero demos once the API path is green. The companion crabbox doc proposes both as separate "editions/adapters."

### 4.3 SUT gateway config

Replace the `channels.telegram` block with `channels.clickclack`. The streaming config is the interesting part: the clickclack channel's streaming renderer (partial/progress/commentary) is exactly what we want the motion GIF to show. The existing `mantis-echo.sh` already proves the streaming-edit pattern against a deterministic word-by-word mock; that mock is **channel-independent** and should be reused unchanged so the streamed text is known and reproducible.

### 4.4 Capture tuning

Re-derive two constants against the clickclack web surface:
- **Crop rectangle:** the conversation column of the clickclack web client at our chosen window size. Calibrate once from a screenshot, same method as the current `crop=435:920:285:78`.
- **GIF trim window (`GIF_SS`/`GIF_T`):** the slice of the recording where the answer builds and lands, so the GIF isn't mostly static.

Everything else in L6 (Xvfb, WM, x11grab, lanczos scale, palette GIF) is reused verbatim.

### 4.5 What "deep-link framing" becomes

Today the rig re-opens the exact reply via a `tg://` deep link so the crop lands on it. For a web client, the analog is a **scroll-to / anchor** action: scroll the conversation to the assistant message (or use a message-anchored URL fragment if the clickclack web client supports one) before the final still + GIF. Crabbox `desktop` input helpers cover the scroll if there's no anchor URL.

---

## 5. Target Architecture (Clickclack Edition)

```
┌─────────────────────────────────────────────────────────────────┐
│ L0  HOST ORCHESTRATION   preflight-host.sh (KEEP, drop 409 probe) │
├─────────────────────────────────────────────────────────────────┤
│ L1  DISPOSABLE BOX       crabbox local-container + --browser      │
│                          checkpoint image w/ chromium + ffmpeg    │
├─────────────────────────────────────────────────────────────────┤
│ L2  SUT GATEWAY          in-box openclaw gateway,                │
│                          channels.clickclack + streaming config   │
├─────────────────────────────────────────────────────────────────┤
│ L3  TRANSPORT            clickclack channel/account  (was TG API) │
├─────────────────────────────────────────────────────────────────┤
│ L4  OBSERVER             chromium @ clickclack web client         │
│                          token-auth (pref) or profile archive     │
├─────────────────────────────────────────────────────────────────┤
│ L5  DRIVER               clickclack-user-driver (API send/wait)   │
│                          optional: UI driver via desktop type     │
├─────────────────────────────────────────────────────────────────┤
│ L6  CAPTURE              Xvfb + WM + x11grab + crop + palette GIF  │
│                          (KEEP; re-calibrate crop + GIF window)    │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. Implementation Plan

Phased so each phase produces a checkable artifact and de-risks the next.

### Phase 0 — Decisions & probes (½ day)
- [ ] Probe the clickclack web client auth surface: does it accept token/magic-link auth (observer option B) or do we need a profile archive (option A)?
- [ ] Identify clickclack's send/receive API shape for the driver (the same surface OpenClaw's clickclack channel uses). Confirm we can post as a test user and read the assistant reply with a stable message id.
- [ ] Decide: API driver first (recommended), UI driver later.
- [ ] Confirm the streaming render mode for clickclack (edit-in-place vs append) — this sets what the GIF should capture.
- **Artifact:** a short `DECISIONS.md` recording auth mode, driver mode, streaming mode.

### Phase 1 — Box image (1 day)
- [ ] Extend/clone the checkpoint provisioning to include Chromium (Crabbox `--browser` provides a binary; bake it into the checkpoint for speed) + ffmpeg + WM + GUI libs (keep `libopengl0`).
- [ ] Drop the tdesktop/tdlib provisioning entirely.
- [ ] `docker commit` a `clickclack-checkpoint` image.
- **Artifact:** a checkpoint image that boots a visible Chromium under Xvfb and can be filmed (verify with `xwininfo` + a test screenshot that is NOT black).

### Phase 2 — Headless debug chain (1 day)
- [ ] Write `clickclack-wake-debug.sh`: no video. Start the in-box gateway with `channels.clickclack`, drive one scenario through the API driver, watch the gateway log for the outbound assistant send, dump the observed reply. This is the analog of `wake-debug.sh` and MUST be green before any filming (lesson: headless-debug-first).
- [ ] Build `clickclack-user-driver` (send + anchored wait + observed.json).
- **Artifact:** a green debug run showing prompt-in → assistant-reply-out with a captured reply id, zero video.

### Phase 3 — First filmed capture (1 day)
- [ ] Write `mantis-clickclack-dm.sh` (analog of `mantis-dm.sh`): launch Chromium under Xvfb/WM, authenticate (token or restored profile), open the conversation, start x11grab, drive the scenario via the API driver, scroll/anchor to the reply, emit `<LABEL>.png` + `<LABEL>-motion.gif`.
- [ ] Calibrate the crop rectangle and GIF trim window against the clickclack surface.
- [ ] LOOK at the first artifact immediately (lesson #20).
- **Artifact:** a clean PNG + a <10MB motion GIF of a real clickclack exchange.

### Phase 4 — Streaming/echo edition (1 day)
- [ ] Port `mantis-echo.sh`'s deterministic streaming mock (it's channel-independent) and prove the clickclack streaming renderer: tokens arriving live, progress/commentary chips, no duplicate final send.
- [ ] This is the "winning" capture — live streaming into a real clickclack UI is the most compelling proof.
- **Artifact:** a motion GIF showing live token streaming in the clickclack web client.

### Phase 5 — Host orchestration + preflight (½ day)
- [ ] Adapt `preflight-host.sh`: keep disk/Docker-VM gates, drop the 409 bot-poller probe, add a clickclack-reachability/auth probe instead.
- [ ] Wire a `crabbox job` template for `clickclack-proof` (lease → build PR → stage → capture → export).
- **Artifact:** one-command host-side capture from a clean checkout.

### Phase 6 — Docs + skill (½ day)
- [ ] Update README + SKILL.md for the clickclack edition; keep the channel-agnostic lessons, replace the Telegram-specific ones with clickclack-specific ones.
- [ ] Document the crop/GIF constants and the auth-archive procedure.
- **Artifact:** a skill an agent can load and run without re-deriving anything.

**Total:** ~6 working days to a repeatable, documented clickclack proof rig, most of it reuse.

---

## 7. Risks & Open Questions

1. **Clickclack web-client auth in a box.** Biggest unknown. If token/magic-link auth works, Phase 0 is trivial; if we need a profile archive, it's the new analog of the tdata apparatus (still simpler than tdlib). **Mitigation:** probe in Phase 0 before committing.
2. **Streaming render fidelity.** If clickclack's web client renders streaming differently from what the gateway emits, the motion GIF may under-sell the feature. **Mitigation:** the deterministic mock makes this debuggable; calibrate in Phase 4.
3. **DOM stability (only if we use the UI driver).** Selector drift breaks UI-driven captures. **Mitigation:** API driver is the default; UI driver is opt-in for hero demos.
4. **Clickclack as the SUT channel vs clickclack as the observer.** We are both proving clickclack *and* filming clickclack. Keep the SUT gateway's clickclack config and the observer's clickclack web client clearly separated (different accounts) so we don't confuse the agent's outbound with the user's inbound — the Telegram rig learned this with bot-#2-as-observer.
5. **Cost/speed.** Each filmed take is a Docker box + a build. The checkpoint image and the headless-debug-first discipline are what keep this cheap. Do not regress on either.

---

## 8. Why This Is Worth Building

We need compelling proof that our products work — for PR review, for demos, for the governance record. A static screenshot is weak evidence. A short motion clip of a real user prompting a real agent over a real clickclack surface, with the answer streaming in live, is the strongest evidence short of a live demo, and it's reproducible, attachable, and automatable.

The `local-mantis` fork already solved the hard parts (disposable box, in-box gateway, record-while-driving, clean small GIFs, preflight discipline) for Telegram. Re-pointing the observer at a browser and the driver at clickclack's API is a focused, ~6-day adaptation that gives us a permanent capability: **mint clickclack proof on demand.**

---

## Appendix A — File map of the existing rig

| File | Layer | Keep / Replace |
|---|---|---|
| `preflight-host.sh` | L0 | Keep; drop 409 probe, add clickclack probe |
| `stage-box.sh` | L0/L1 | Replace tdata/tdlib unpack with browser-profile unpack (if option A) |
| `mantis-capture.sh` | L2/L4/L5/L6 | Template; fork to `mantis-clickclack-*.sh` |
| `mantis-dm.sh` | L2/L4/L5/L6 | Template for `mantis-clickclack-dm.sh` |
| `mantis-group.sh` | L2/L4/L5/L6 | Optional; clickclack group/channel analog |
| `mantis-echo.sh` | L2/L4/L5/L6 | Port the streaming mock verbatim (channel-independent) |
| `mantis-topic-wake*.sh` | L2/L4/L5/L6 | Defer; cron-wake proof is channel-agnostic but lower priority |
| `mantis-verbose.sh` | L2/L4/L5/L6 | Port for commentary-lane proof |
| `wake-debug.sh` | debug | Template for `clickclack-wake-debug.sh` |
| `make-group.py` | L3 setup | Replace with clickclack test-account/conversation setup |
| `run-verbose-batch.sh` | L0 | Keep pattern |

## Appendix B — The capture pipeline, distilled

The reusable core, stripped of Telegram:

```
1. cleanup orphans (patterns in a FILE, never inline)
2. wipe SUT state; (channel backlog drain if the transport needs it)
3. write isolated openclaw.json (channel + streaming + deterministic model)
4. start in-box gateway; WAIT on a readiness log line (not a fixed sleep)
5. Xvfb + WM; launch the OBSERVER (browser/desktop client)
6. apply window geometry BEFORE recording
7. start ffmpeg x11grab
8. DRIVE the scenario (send prompt as the user, anchored wait for reply)
9. anchor/scroll the observer to the reply
10. single-frame still + palette GIF trimmed to the reply window
11. verify artifacts are non-trivial (byte size, look at it)
12. teardown
```

That is the whole machine. The channel only touches steps 2, 3, 5, 8, 9.
