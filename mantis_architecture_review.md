# local-mantis architecture review and PsiClawOps proof-capture plan

Status: architectural review and implementation plan
Date: 2026-06-12
Repos reviewed: `PsiClawOps/local-mantis`, `PsiClawOps/crabbox`
Primary product target: high-quality Clickclack behavior proof, not Telegram-specific test coverage

## Executive summary

`local-mantis` is already more than a script bundle. It is a working proof-capture pattern: disposable Crabbox desktop box, real human-visible client, real OpenClaw gateway, deterministic or live model turn, screen recording, cropped still, motion GIF, logs, and a repeatable operator flow.

The current fork is Telegram-shaped because the original Mantis proof need was Telegram-visible PR validation. That is the wrong boundary for PsiClawOps. The durable product boundary should be:

> Capture compelling proof that a real user surface behaved correctly during a real agent turn.

Telegram should become one adapter. Clickclack should be the next target and likely the default proof format for PsiClawOps because it is our own surface, it can show the interaction more cleanly, and it avoids implying that we are testing Telegram itself.

The recommended direction is to turn `local-mantis` into a small proof-capture runtime with pluggable editions:

- `telegram-desktop` edition: keep current behavior for compatibility and regression proof.
- `clickclack-web` edition: launch the Clickclack web surface in a controlled browser, drive a real message, capture the live reply, and export stills, GIF or MP4, run logs, and a proof manifest.
- `headless-debug` edition for every visual edition: prove the chain before paying for a filmed take.
- `deterministic-stream` model mode: default for visual proof, so proof failures isolate UI and routing defects instead of model randomness.

The long-term product should be named around proof, not Mantis itself. Internally we can keep `local-mantis` as the fork, but the architecture should be `ProofRig`: a local, reproducible evidence system for OpenClaw behavior.

## What exists today

The repo currently contains:

- `README.md`, a concise operator overview.
- `SKILL.md`, a detailed skill/manual with the real capture flow and hard-won failure modes.
- `mantis-dm.sh`, for bot DM render proof.
- `mantis-group.sh`, for native Telegram supergroup reply proof.
- `mantis-echo.sh`, for webchat-origin messages echoed into Telegram.
- `mantis-topic-wake.sh` and `mantis-topic-wake-notarget.sh`, for forum-topic cron wake proof.
- `mantis-verbose.sh`, for verbose/commentary capture.
- `mantis-capture.sh`, the original/base capture path.
- `wake-debug.sh`, for fast headless chain debugging before recording.
- `preflight-host.sh`, for host readiness checks before spending box time.
- `stage-box.sh`, for staging payload and capture assets into a Crabbox box.
- `make-group.py`, for one-time Telegram observer group creation.

The scripts are scenario-oriented. Each script owns enough of the runtime that new scenarios tend to copy and mutate a full shell script. That was a good survival path, but it is now the main scaling risk.

## Current architecture

### Runtime path

The current Telegram proof path is:

1. Host operator runs preflight.
2. Crabbox leases or reuses a local-container desktop box.
3. The box has OpenClaw source, Telegram Desktop, tdlib driver state, ffmpeg, Xvfb, a window manager, Node, pnpm, Python, and runtime libraries.
4. `stage-box.sh` restores capture payloads under `/tmp/cap`.
5. A `mantis-*.sh` script writes an isolated `openclaw.json`.
6. The script starts `openclaw gateway` against a dedicated test bot token.
7. The script starts a virtual display and Telegram Desktop with observer `tdata`.
8. The script applies known window geometry before recording.
9. The driver sends a fresh scenario message or a webchat `chat.send`.
10. The script records the screen, waits for the observed reply, deep-links or frames the result, and exports PNG, cropped PNG, MP4, GIF, logs, and observed JSON.
11. The operator attaches proof artifacts to the PR or issue.

### Control/data boundaries

The current system has useful boundaries:

- Host owns secrets and box lifecycle.
- Crabbox owns the disposable execution environment and artifact movement.
- `local-mantis` owns proof orchestration.
- OpenClaw gateway owns the behavior under test.
- Telegram Desktop is a real observer surface, not a mocked renderer.
- The user-driver owns real user input and waits.
- ffmpeg owns the durable visual artifact.

The weak boundary is that proof orchestration, adapter behavior, scenario setup, preflight, gateway config, and artifact packaging are fused inside each shell script.

## What works well

1. **Real surface proof**
   The system films an actual desktop client. That is more compelling than a unit test, log excerpt, or synthetic DOM assertion.

2. **Disposable execution**
   Running inside Crabbox local-container boxes gives clean state, reproducibility, and a practical cleanup story.

3. **Deterministic model option**
   `mantis-echo.sh` uses a streaming mock by default. That is the correct default for proof capture because it makes the surface and routing pipeline the subject.

4. **Hard failure lessons are encoded**
   The manual captures real operational failure modes: token poller conflicts, stale OAuth credentials, tdlib path drift, Telegram window mapping delays, stale update replay, and broken `pkill` patterns.

5. **Headless debug exists**
   `wake-debug.sh` proves the chain before video capture. This should become mandatory for every edition.

6. **Artifacts are PR-ready**
   Cropped PNG plus motion GIF is a good review artifact pair. The MP4 should remain the canonical raw/motion source when GIF size or fidelity is a problem.

## Main product gaps

### 1. Surface is hardcoded to Telegram

The current scripts assume Telegram-specific assets and mechanics:

- Bot token and `getUpdates` drain.
- Telegram Desktop `tdata`.
- tdlib driver state.
- Telegram deep links.
- Chat IDs and supergroup IDs.
- Telegram-specific crop constants.

That is useful for Telegram regressions, but it makes the proof system feel like a Telegram test rig instead of a general OpenClaw proof rig.

### 2. Scenario variants duplicate the runtime

Each `mantis-*.sh` variant redefines cleanup, config generation, gateway startup, display startup, driving, waits, capture, export, and teardown. This makes the next edition expensive and raises the chance that one path misses a hard-won fix.

### 3. Artifacts lack a single manifest contract

Humans can inspect the files, but automation needs a normalized manifest:

```json
{
  "proofId": "proof_...",
  "edition": "clickclack-web",
  "scenario": "streaming-reply",
  "subject": "OpenClaw gateway Clickclack renderer",
  "repo": "openclaw",
  "commit": "...",
  "startedAt": "...",
  "endedAt": "...",
  "artifacts": {
    "still": "...png",
    "crop": "...png",
    "motion": "...mp4",
    "reviewGif": "...gif",
    "logs": "...log",
    "observed": "...json"
  },
  "verdict": "passed",
  "notTested": ["Telegram transport"]
}
```

Without this, Crabbox and PR automation cannot safely consume proof results.

### 4. Proof validity is implicit

A capture can produce a nonzero PNG and GIF while still being invalid. The Telegram notes already call this out: identical PNG byte sizes meant a dead screen was captured. The product needs a validation gate that checks more than file existence.

### 5. Clickclack is not first-class yet

The highest-value PsiClawOps proof target is high-quality Clickclack examples:

- Real user message in Clickclack.
- Live assistant progress and final reply.
- Commentary/status behavior when enabled.
- Tool-use visible state when relevant.
- Mobile and desktop capture variants.
- A polished artifact that can be used in PR review, product demos, and release notes.

The current repo can be adapted to this, but not by copying `mantis-echo.sh` again. It needs an adapter seam.

## Product goal

Build a proof-capture system that can answer this in one command:

> Did a real OpenClaw user surface show the right behavior during a real or deterministic agent turn, and can we attach compelling proof?

The system should not only prove correctness. It should create product-grade evidence.

For Clickclack, the winning artifact is not just a screenshot. It is a short, high-fidelity clip that shows:

- The user's message entering the channel.
- The assistant turn starting.
- Streaming or status state evolving.
- The final answer landing cleanly.
- No duplicate, stale, or wrong-session message.

## Proposed target architecture

### Core concept: ProofRig

Split the repo into a core runtime plus editions.

```text
local-mantis/
  bin/
    proofrig
  proofrig/
    core/
      preflight.sh
      box.sh
      gateway.sh
      display.sh
      recorder.sh
      artifacts.sh
      validate.sh
      manifest.sh
    editions/
      telegram-desktop/
        adapter.sh
        preflight.sh
        validate.sh
        scenarios/*.json
      clickclack-web/
        adapter.sh
        preflight.sh
        validate.sh
        scenarios/*.json
      clickclack-mobile/
        adapter.sh
        preflight.sh
        validate.sh
        scenarios/*.json
    models/
      deterministic-openai-responses.mjs
      claude-cli.sh
    docs/
      proof-manifest.md
      edition-authoring.md
```

Shell is acceptable for v1, but the orchestration should move toward a small TypeScript or Go CLI once the adapter contract stabilizes. A typed CLI will reduce quoting bugs, process cleanup bugs, and JSON/config generation risks.

### Edition contract

Each edition should implement the same steps:

```text
preflight        confirm host and edition-specific prerequisites
stage            place payload, credentials, state, fixtures
configure        generate OpenClaw and surface config
start_surface    launch the observer surface
warmup           load session, open channel, verify visible state
drive            send the user action
observe          wait for the expected assistant/user-visible event
frame            navigate or scroll to the evidence target
capture          record still and motion artifacts
validate         prove the artifact is not stale or blank
teardown         stop processes and clean state
manifest         emit normalized proof metadata
```

Edition adapters should not own generic cleanup, ffmpeg command construction, manifest writing, or host disk checks. They should only own surface-specific actions.

### Proof manifest

Add `proof.json` as a required artifact. Example:

```json
{
  "schema": "psiclawops.proofrig.v1",
  "proofId": "proof_clickclack_20260611_0700",
  "edition": "clickclack-web",
  "scenario": "streaming-reply-basic",
  "subject": "Clickclack live assistant reply rendering",
  "surface": {
    "kind": "web",
    "name": "Clickclack",
    "url": "http://127.0.0.1:..."
  },
  "runtime": {
    "crabboxProvider": "local-container",
    "containerImage": "psiclawops/proofrig-clickclack:...",
    "openclawCommit": "...",
    "proofrigCommit": "..."
  },
  "drive": {
    "origin": "clickclack-ui",
    "message": "Show a concise status update with one tool call proof point"
  },
  "expected": {
    "events": ["user-message-visible", "assistant-stream-visible", "final-visible"],
    "forbidden": ["duplicate-final", "wrong-channel", "blank-screen"]
  },
  "observed": {
    "passed": true,
    "messageId": "...",
    "durationMs": 27340
  },
  "artifacts": [
    {"kind": "still", "path": "proof.png", "sha256": "..."},
    {"kind": "motion", "path": "proof.mp4", "sha256": "..."},
    {"kind": "review-gif", "path": "proof.gif", "sha256": "..."},
    {"kind": "log", "path": "gateway.log", "sha256": "..."}
  ],
  "notTested": ["Telegram client behavior", "public network delivery"]
}
```

This manifest is the bridge to Crabbox artifacts, PR comments, dashboards, and later proof search.

## Clickclack edition design

### Target behavior

The first Clickclack edition should prove a single group-channel user flow:

1. Launch OpenClaw gateway in a proof state directory.
2. Launch the Clickclack web app or local Clickclack surface.
3. Open a known test channel.
4. Send a message as the user through the actual UI, not only via API.
5. Observe the assistant response in the channel.
6. Capture progress, streaming, and final reply.
7. Validate that the reply belongs to the correct session/channel and is not a stale replay.

### Why Clickclack should be the first non-Telegram edition

- It is our product surface, so proof artifacts double as product examples.
- We control the UI and can add stable `data-proof-id` selectors if needed.
- We can produce a more polished visual than Telegram Desktop without fighting Telegram layout drift.
- We can capture both correctness and UX quality, including spacing, status chips, progress feed, and reply timing.
- It avoids framing the proof as transport-specific.

### Clickclack capture modes

Start with three modes:

1. `clickclack-web-basic`
   - Desktop browser, one user message, deterministic streaming reply, still plus MP4/GIF.

2. `clickclack-web-progress`
   - Shows commentary/tool/status progress during a turn. Uses a deterministic tool-bearing prompt or mock stream.

3. `clickclack-web-regression`
   - Given a bug/pr scenario, drive a specific message and validate the absence of the old failure: duplicate reply, wrong channel, missing stream, stale content, clipped mobile pill, etc.

Add mobile later after desktop is stable.

### Browser approach

Prefer Playwright or the existing OpenClaw browser automation control path over raw xdotool for Clickclack. The visual capture can still use ffmpeg, but driving should use DOM-aware selectors.

Recommended stack:

- Xvfb or native Crabbox desktop display.
- Chromium installed in the proof image.
- Playwright for UI drive and assertions.
- ffmpeg for raw screen recording.
- Optional browser tracing for debug artifacts.
- OpenClaw gateway as the system under test.
- Deterministic model server for default proof mode.

### Clickclack validation gates

A Clickclack proof should fail if any of these are true:

- Browser page did not load expected channel.
- User message is not visible after drive.
- Assistant response is not visible within timeout.
- Assistant message does not have the expected session/channel correlation.
- More than one final response is visible for a one-response scenario.
- Screenshot is blank, login screen, or unchanged from pre-drive baseline.
- Motion artifact is under a minimum duration or file-size threshold.
- Gateway log lacks the expected turn start and final delivery markers.

Validation should combine DOM checks, gateway logs, screenshot diff/hash checks, and manifest fields.

## Implementation plan: build our own Mantis-equivalent

### Phase 0: preserve current value

- Keep every existing Telegram script working.
- Add this architecture report as the baseline plan.
- Add a `docs/` directory for proof contracts.
- Do not rename the repo yet. Renaming before the seam exists would create churn without product value.

Acceptance:

- Existing scripts still run unchanged.
- The repo has a documented next architecture.

### Phase 1: normalize artifacts and manifests

Build a shared artifact footer used by all scripts:

- `proofrig/core/manifest.sh`
- `proofrig/core/artifacts.sh`
- SHA256 generation for every artifact.
- `proof.json` emitted by existing Telegram scripts.
- Standard names: `proof-full.png`, `proof-crop.png`, `proof-motion.mp4`, `proof-review.gif`, `gateway.log`, `observed.json`.

Acceptance:

- `mantis-dm.sh`, `mantis-group.sh`, and `mantis-echo.sh` emit `proof.json` without changing their visible behavior.

### Phase 2: factor shared shell runtime

Move common code into sourced modules:

- Process cleanup.
- Gateway config generation.
- Deterministic stream mock startup.
- Xvfb/openbox startup.
- ffmpeg recording and GIF export.
- Artifact size and blank-screen checks.

Acceptance:

- At least two existing scripts use the shared modules.
- No copy-pasted ffmpeg pipelines remain in new scripts.

### Phase 3: add Clickclack web proof MVP

Create `proofrig/editions/clickclack-web/` with:

- `preflight.sh`: checks node, browser, ports, free disk, and Clickclack build inputs.
- `adapter.sh`: starts OpenClaw gateway and Clickclack web app, opens Chromium, drives a message, waits for visible response.
- `scenarios/streaming-basic.json`: first deterministic scenario.
- `validate.sh`: DOM plus artifact validation.

Implementation notes:

- Use a dedicated state dir under `/tmp/cap/state`.
- Use deterministic streaming model first.
- Use the real Clickclack UI for send actions, not only gateway RPC.
- Use stable test selectors in Clickclack if they do not exist yet.
- Capture the whole browser first; crop later after calibration.

Acceptance:

- One command produces `proof.json`, PNG, MP4, GIF, gateway log, browser console log, and observed JSON for a Clickclack turn.
- The proof clearly shows user prompt, streaming/progress, and final answer.

### Phase 4: add proof quality layer

Add presentation rules:

- Fixed viewport presets: desktop 1440x1000, mobile 390x844.
- Optional crop presets for channel column.
- Cursor visible or hidden by mode.
- Intro freeze frame and ending buffer.
- GIF palette pipeline tuned under GitHub attachment limits.
- MP4 kept as canonical high-fidelity artifact.

Acceptance:

- Generated Clickclack proof is clean enough for release notes, not only PR debugging.

### Phase 5: integrate with Crabbox jobs

Create repo-local Crabbox job examples that run proof editions inside local-container:

```yaml
jobs:
  proof-clickclack-basic:
    provider: local-container
    target: linux
    desktop: true
    browser: true
    class: beast
    shell: true
    command: >
      bash proofrig/editions/clickclack-web/run.sh
      scenarios/streaming-basic.json
    downloads:
      - /tmp/cap/proof.json=.artifacts/proof/proof.json
      - /tmp/cap/proof-crop.png=.artifacts/proof/proof-crop.png
      - /tmp/cap/proof-motion.mp4=.artifacts/proof/proof-motion.mp4
      - /tmp/cap/proof-review.gif=.artifacts/proof/proof-review.gif
    stop: success
```

Acceptance:

- `crabbox job run proof-clickclack-basic` produces local artifacts without a manual export dance.

### Phase 6: PR/comment automation

Build a proof publisher that reads `proof.json` and writes a Markdown proof block:

```markdown
### Behavior proof

Scenario: Clickclack live assistant reply rendering
Environment: Crabbox local-container, OpenClaw commit `abc1234`
Result: Passed

Artifacts:
- Still: proof-crop.png
- Motion: proof-review.gif
- Full MP4: proof-motion.mp4

Not tested: Telegram transport, public network delivery
```

Acceptance:

- A PR can include machine-readable proof plus a human-ready proof block.

## Steps needed to build a first-class PsiClawOps Mantis equivalent

1. **Define the proof contract**
   Write `docs/proof-contract.md` with the manifest schema, artifact names, validity rules, and expected reviewer language.

2. **Introduce editions**
   Add an edition directory structure and require every edition to implement `preflight`, `drive`, `observe`, `capture`, `validate`, and `manifest`.

3. **Keep Telegram as compatibility edition**
   Move current scripts behind `telegram-desktop` without breaking old entrypoints.

4. **Build Clickclack web MVP**
   Launch Clickclack, drive a real UI send, use deterministic streaming, record Chromium, and export proof.

5. **Add stable Clickclack test hooks**
   If needed, update Clickclack UI with stable selectors and proof-only diagnostics. Do not rely on brittle text search for everything.

6. **Package a proof image**
   Build a Docker image or Crabbox checkpoint with browser, ffmpeg, Playwright, fonts, OpenClaw prerequisites, and proof tooling installed.

7. **Make debug-first mandatory**
   Every visual edition needs a non-recording debug pass that proves gateway, surface, session, driver, and wait conditions.

8. **Normalize artifacts**
   Require `proof.json` and common filenames. Keep MP4 canonical; generate GIF for GitHub convenience.

9. **Integrate with Crabbox job downloads**
   Stop depending on manual `docker cp` or ad-hoc base64 export. Use Crabbox downloads/artifacts where possible.

10. **Add proof reviewer templates**
    Make it explicit what was tested and what was not tested. For Clickclack, say that the proof covers the Clickclack surface and OpenClaw behavior, not Telegram.

## Clickclack scenario backlog

High-value scenarios to capture first:

1. **Basic live response**
   User sends one message, assistant response streams and completes.

2. **Commentary/status visible**
   Assistant emits progress commentary or status feed while a tool-bearing turn runs.

3. **No duplicate final**
   Streaming response edits into the same message and does not send a duplicate final.

4. **Wrong-channel guard**
   Message in channel A must not appear in channel B.

5. **Stale replay guard**
   Fresh session does not capture an old assistant reply.

6. **Mobile channel proof**
   390px viewport shows the message/reply without clipping.

7. **Operator interrupt proof**
   Interrupt produces a clear user-visible state and no orphaned progress message.

## Risk register

### Risk: proof rig becomes a test framework clone

Mitigation: Keep the product boundary visual behavior proof. Unit/integration tests remain in OpenClaw and Clickclack repos. ProofRig is for high-confidence human evidence.

### Risk: browser automation hides real UX issues

Mitigation: Drive with Playwright, but capture the actual screen. Assertions should support the visual artifact, not replace it.

### Risk: deterministic model makes proof feel fake

Mitigation: State it clearly in the manifest. Deterministic mode proves UI/routing behavior. Add optional live-model mode when the model behavior itself matters.

### Risk: artifact generation passes despite stale screen

Mitigation: Add screenshot diff checks, DOM checks, visible message correlation, log correlation, and minimum motion duration.

### Risk: secrets leak through artifacts or logs

Mitigation: Redact logs before packaging, keep credentials out of argv, and include a manifest redaction pass. Never attach raw payloads with bot tokens or auth archives.

### Risk: Clickclack selectors drift

Mitigation: Add explicit proof selectors to the UI and treat them as a public testability contract.

## Recommended near-term build order

1. Add `proof.json` manifest support to current Telegram scripts.
2. Add `proofrig/core` shared helpers.
3. Build `clickclack-web-basic` with deterministic streaming.
4. Add `clickclack-web-progress` for status/commentary proof.
5. Wire a Crabbox job with downloads.
6. Add PR proof publisher.

This sequence keeps existing proof value alive while moving the product toward the real target: polished Clickclack evidence that can sell the behavior, not just prove the code path.

## Source material reviewed

Local repo material:

- `PsiClawOps/local-mantis` README and `SKILL.md`.
- Existing `mantis-*.sh` scripts, especially `mantis-dm.sh`, `mantis-group.sh`, `mantis-echo.sh`, and topic wake variants.
- `PsiClawOps/crabbox` docs consulted for the adaptation boundary:
  - `docs/architecture.md`
  - `docs/providers/local-container.md`
  - `docs/features/interactive-desktop-vnc.md`
  - `docs/features/lifecycle-cleanup.md`
  - `docs/getting-started.md`
  - `docs/infrastructure.md`
  - `docs/provider-backends.md`

External docs and reference material:

- Crabbox provider reference: https://crabbox.sh/providers/index.html
- Crabbox local-container provider: https://crabbox.sh/providers/local-container.html
- Crabbox getting started: https://crabbox.sh/getting-started.html
- Crabbox infrastructure/self-hosted broker notes: https://crabbox.sh/infrastructure.html
- Crabbox provider authoring: https://crabbox.sh/features/provider-authoring.html
- Crabbox architecture: https://crabbox.sh/architecture.html
- Crabbox interactive desktop and VNC: https://crabbox.sh/features/interactive-desktop-vnc.html
- Crabbox lifecycle and cleanup: https://crabbox.sh/features/lifecycle-cleanup.html
- Docker Compose lifecycle hooks: https://docs.docker.com/compose/how-tos/lifecycle/
