# Phone Coder Native — Product and Technical Design

**Status:** Proposed for approval  
**Date:** 2026-11-09  
**Selected approach:** Fork OnDevice Local AI Studio and reshape it into Phone Coder  
**Baseline:** `Mesutcydev/ios-local-llm` at commit `cc4e2d3f25dfe77e9ef9e629ee6ddc7e3134ac88`

## Intent

Phone Coder turns an iPhone into a private local inference appliance for coding work performed on an Ubuntu computer. The iPhone runs downloaded language and image models. The Ubuntu companion owns repository access, terminal commands, patches, tests, approvals, and Git operations. The two communicate over the user's Tailscale network through an authenticated, OpenAI-compatible API.

The project exists because the current Safari/WebGPU prototype proves the end-to-end idea but cannot provide dependable long-request behavior. Safari may refresh, suspend the page, evict caches, or dispose the WebGPU runtime. The OnDevice App Store build proves that native MLX inference and image generation work on the phone, but its image workflow includes an app-level content checker that is not present in the published source. Phone Coder must provide native reliability and transparent behavior: no hidden prompt or output filtering, clear separation between model refusals and app safety gates, and user-visible recovery when memory, temperature, network, or iOS lifecycle limits interrupt work.

## Product definition

Phone Coder is one product with two cooperating components:

1. **Phone Coder iOS** — a native SwiftUI app that downloads and runs compatible MLX/GGUF language models and Stable Diffusion image models, exposes a foreground-only authenticated local API, and provides local chat, image generation, model management, connection status, and diagnostics.
2. **Phone Coder Agent for Ubuntu** — a local coding agent that reads and edits the selected workspace, runs commands with approval, prepares bounded context for the phone model, streams responses, and recovers from phone/network interruptions.

The iPhone is the inference engine. Ubuntu is the tool executor. The phone never receives unrestricted filesystem or shell access, and the iPhone app does not attempt to control other iOS apps.

## Goals

- Replace the fragile WebGPU inference path with native MLX/llama.cpp inference.
- Support useful local coding models that fit the phone; target 3B–8B quantized models first.
- Allow Ubuntu tools to call the phone through a documented OpenAI-compatible API.
- Provide a Codex-like coding loop on Ubuntu: inspect, propose, patch, run tests, show diffs, and request approval for risky actions.
- Recover predictably from network loss, foreground/background transitions, model reloads, cancellation, memory pressure, and thermal pressure.
- Keep prompts, repository context, generated text, and generated images local unless the user deliberately enables an external feature.
- Make policy behavior transparent. The sideload build performs no hidden post-generation image content filtering. Model-level refusals are shown as model output, not mislabeled as an app restriction.
- Build without a locally owned Mac by using a pinned GitHub Actions macOS runner and install from Ubuntu through SideStore/iloader.
- Preserve the existing PWA and relay as a diagnostic fallback until the native path passes physical-device acceptance tests.

## Non-goals

- Running a 70B model on the iPhone. The memory and sustained-performance requirements are not realistic for this product.
- Keeping an inference server alive indefinitely in the background. iOS may suspend the app; serving is explicitly foreground-only.
- Controlling the whole iPhone or automating arbitrary third-party iOS apps.
- Training or fine-tuning models on the phone.
- App Store distribution in the first release.
- Cloud inference, accounts, subscriptions, analytics, advertising, or telemetry.
- Replacing a strong hosted coding model for large autonomous refactors. The first release is optimized for private, focused local work.

## Anti-goals

The project is considered a failure even if it technically generates text when any of the following is true:

- A user cannot tell whether a failure came from the model, content policy, memory, heat, connectivity, or iOS suspension.
- The app silently discards or withholds generated output.
- A transient disconnect loses a coding request after work has started without explaining whether it is safe to retry.
- The server claims to be available while no model is usable.
- The Ubuntu agent can execute destructive commands without a clear approval boundary.
- Installing an update requires access to a personally owned Mac.
- Long prompts crash or refresh the interface instead of being rejected or compacted deliberately.

## Constraints

- Development workstation: Ubuntu only.
- iOS build environment: GitHub-hosted macOS/Xcode runner; toolchain and dependencies must be pinned.
- Installation: SideStore/iloader from Linux. A free Apple Account implies seven-day refreshes and the normal Personal Team app limits.
- Runtime: iOS 18 or newer, with newer features conditionally enabled rather than raising the minimum unnecessarily.
- Network: Tailscale is the supported primary path. Plain LAN exposure is disabled by default. Direct USB transport is not in the first release.
- Lifecycle: API serving works only while the app is foregrounded. Serving mode requests the idle timer remain disabled and explains the battery cost.
- Memory: only one heavy inference family is resident at once. Switching between chat, vision, and image generation may unload another model.
- Device protection: memory and thermal gates are always enabled and cannot be disguised as content restrictions.
- Models retain their own licenses and built-in behavior. Phone Coder cannot guarantee that a selected instruction-tuned model never refuses a request.
- The public OnDevice source and App Store binary are not assumed identical. Every policy and generation path used by Phone Coder must be auditable in the fork.

## Release-one qualification targets

- Primary and required physical device: the owner's iPhone 17 Pro Max. Its installed iOS build is recorded during Increment A and becomes the release qualification baseline.
- The project retains the upstream iOS 18 minimum where dependencies allow, but devices other than the iPhone 17 Pro Max are compatibility targets, not release blockers, until measured on real hardware.
- Required Ubuntu target: Ubuntu 26.04 LTS on x86_64. Other current Ubuntu LTS releases and arm64 are best-effort until they have CI or physical validation.
- Vision/multimodal inference is excluded from release one. Attached-image understanding may be designed later without changing the chat, image-generation, or coding-agent boundaries.
- Release one includes both the `phone-coder` CLI and a loopback-only Ubuntu compatibility proxy at `127.0.0.1:8765/v1`. Generic clients receive chat inference only; repository tools are available solely through the Phone Coder agent and its approval engine.

## Approaches considered

### 1. Fork OnDevice Local AI Studio — selected

Reuse the published SwiftUI app's MLX, llama.cpp, model download, image generation, memory protection, and local API foundations. Replace its product shell, narrow the feature set, audit policy behavior, and add Phone Coder's server and Ubuntu-agent contract.

This is selected because native model lifecycle work is the highest-risk part of the product, and the source already contains practical recovery for iOS memory and thermal behavior. It also avoids repeating the Safari/WebGPU failure mode.

### 2. Greenfield SwiftUI app

Build a minimal native app around MLX Swift and llama.cpp. This provides the cleanest ownership boundary but repeats model download, quantization compatibility, memory recovery, and image-runtime work. It remains a future option if the fork proves too tightly coupled to unrelated features.

### 3. Continue the WebGPU PWA

Continue improving the existing browser worker and relay. It remains valuable as a fallback and protocol test harness but is rejected as the primary product because application code cannot control Safari's GPU-process, cache, or background lifecycle.

## Experience principles

1. **Status before decoration.** Every primary screen shows what model is loaded, whether it is usable, and whether the phone is serving.
2. **One primary action per state.** Examples: Download, Load, Start serving, Stop, Retry, or Cool down.
3. **Failures name the layer.** “Model refused,” “Phone went to background,” “Tailscale unreachable,” and “Not enough memory” are distinct states.
4. **No hidden work.** Downloads, model loads, prompt compaction, recovery, and tool execution appear in activity history.
5. **Owner-visible policy.** Settings state exactly which checks exist. A build with no post-generation classifier says so.
6. **Native iPhone behavior.** Dynamic Type, VoiceOver, high contrast, Reduce Motion, haptics, swipe actions, sheets, and system share affordances are first-class.
7. **Coding remains laptop-shaped.** The phone UI is for runtime control and quick local chat, not for reviewing large diffs or operating a terminal.

## Information architecture

The native app uses five bottom tabs:

1. **Chat** — quick local conversation and model smoke tests.
2. **Models** — installed models, discovery/import, compatibility, storage, load/unload.
3. **Server** — serving state, pairing, connection health, active request, and recent activity.
4. **Images** — local image generation, history, model settings, and export.
5. **Settings** — privacy, owner controls, network, appearance, diagnostics, legal, and data reset.

Server is the center tab and receives the strongest visual emphasis because it is the bridge to Ubuntu coding work.

## Screen designs

### Server

```text
┌─────────────────────────────────────┐
│ Phone Coder                  ● Ready│
│ Qwen Coder · 7B · 4-bit             │
├─────────────────────────────────────┤
│          SERVING UBUNTU             │
│      Encrypted through Tailscale    │
│                                     │
│          [ Stop serving ]           │
├─────────────────────────────────────┤
│ Ubuntu workstation        Connected │
│ Last request                  8s ago │
│ Queue                            0/4 │
│ Session                       42 min │
├─────────────────────────────────────┤
│ Current activity                    │
│ Waiting for a coding request…       │
├─────────────────────────────────────┤
│ Pair device   Rotate key   Diagnose │
└─────────────────────────────────────┘
```

States are Stopped, Starting, Ready, Serving, Generating, Recovering, Paused in background, Cooling down, Low memory, Authentication error, and Network unavailable. The primary button and explanation change together. A reconnect action is offered only when it is meaningful.

Pairing displays a QR code containing the server address, API version, certificate or tailnet identity, and a one-time exchange token. The long-lived bearer key is returned only after the user approves the pairing on the phone. Keys can be named, individually revoked, and rotated.

### Models

```text
┌─────────────────────────────────────┐
│ Models              31.2 GB free    │
│ [ Installed ] [ Discover ] [ Import]│
├─────────────────────────────────────┤
│ ● Qwen Coder 7B · 4-bit             │
│   Loaded · Good fit · 4.8 GB        │
│   [Unload]                [Details] │
├─────────────────────────────────────┤
│   Smaller Coder 3B · 4-bit          │
│   Installed · Excellent fit         │
│   [Load]                  [Delete]  │
└─────────────────────────────────────┘
```

Every model card separates download size, estimated working memory, context limit, runtime, license, and verified device status. “Good fit” is based on measured headroom, not marketing labels. Models that are likely to crash are not hidden; they show a specific warning and require an explicit attempt.

### Chat

Chat is a compact validation and private-notes surface. It supports streaming, stop, retry, copy, share, model selection, context usage, and an expandable generation-details footer. It does not expose Ubuntu tools. A tool-looking response is rendered as text so there is no ambiguity about where execution occurs.

### Images

```text
┌─────────────────────────────────────┐
│ Image Studio        SDXL Turbo  ▾   │
│                                     │
│ Describe an image…                  │
│                                     │
│ [ Style ] [ Size ] [ Seed ] [More] │
│                                     │
│            [ Generate ]             │
├─────────────────────────────────────┤
│ Local generation · No output filter │
│ Device-safety limits remain active  │
├─────────────────────────────────────┤
│ Generated image / progress          │
└─────────────────────────────────────┘
```

The default view shows prompt, selected model, and Generate. More exposes negative prompt, steps, guidance, seed, and supported resolution. The policy line is always visible and opens Owner Controls. Memory or heat blocks appear above Generate and name the device condition.

Generated images are stored only when the user enables local history or explicitly saves them. Share uses the system share sheet. The app never substitutes a blank preview after generation; success, failure, cancellation, and withholding by an optional owner rule are distinct result types.

### Owner Controls

Owner Controls is not branded as “safety” when it describes content preferences. It contains:

- **Post-generation image classifier:** Not installed in the sideload build.
- **Prompt blocklist:** Off by default; if the owner creates entries, each is visible and editable.
- **Model refusals:** Cannot be overridden by the app; the selected model generated them.
- **Device protection:** Memory and thermal limits are always on.
- **Network exposure:** Tailscale only by default; LAN mode is a separate explicit choice.

There is no secret bypass gesture, remote configuration, or server-controlled ruleset. If a future distribution requires a different policy, it must use a named build flavor and disclose the difference on this screen and in release notes.

### Ubuntu agent

The Ubuntu experience begins as a CLI and local OpenAI-compatible endpoint, then may gain a desktop UI. A typical task looks like:

```text
$ phone-coder run "fix the failing authentication test"

Connected: iPhone · Qwen Coder · 7B
Workspace: /home/haider/project

1. Search repository                         approved automatically
2. Read auth/session.py                      approved automatically
3. Propose patch                             review required
4. Run pytest tests/test_session.py          review required

[Approve patch] [Edit request] [Stop]
```

Read-only repository inspection may be allowed by a workspace profile. File writes, commands, network access, and destructive operations have separate approval policies. The final response contains changed files, tests run, failures, and the remaining uncertainty.

## Visual system

- Follow native SwiftUI layout and material behavior rather than imitating a desktop IDE.
- Use semantic system colors. Accent defaults to electric blue; green is reserved for healthy/ready, amber for recoverable attention, and red for stopped/error/destructive actions.
- Use SF Pro for interface text and SF Mono for model IDs, addresses, tokens, logs, and code.
- Minimum control height is 44 points. Primary controls use 52–56 points.
- Support Dynamic Type without clipping through accessibility sizes. Status cards become vertical rather than shrinking text.
- Animations communicate state transitions only. Reduce Motion replaces transforms with fades.
- Never rely on color alone; every status has an icon and label.
- Long model names, localization expansion, right-to-left layout, VoiceOver order, and landscape are acceptance cases rather than later polish.

## System architecture

```text
┌──────────────── Ubuntu ────────────────┐
│ Phone Coder Agent                     │
│  Workspace index/context builder      │
│  Approval engine                      │
│  File/patch/terminal/git tools        │
│  OpenAI client + retry coordinator    │
└──────────────────┬─────────────────────┘
                   │ Tailscale + bearer key
                   │ SSE / JSON
┌──────────────────▼─────────────────────┐
│ Phone Coder iOS                       │
│  API server + pairing                 │
│  Request ledger and stream buffer     │
│  Inference coordinator                │
│   ├─ MLX language runtime             │
│   ├─ llama.cpp GGUF runtime           │
│   └─ Stable Diffusion runtime         │
│  Model store/download manager         │
│  Memory/thermal/lifecycle monitor     │
│  SwiftUI state and diagnostics        │
└────────────────────────────────────────┘
```

### Fork boundaries

The fork retains and audits the upstream model catalog, download manager, MLX generation gate, MLX and llama.cpp runtimes, image generation service, memory advisor, device safety monitor, diagnostics, and local API foundations. It removes or disables unrelated cloud/provider integrations, paired-Mac automation that overlaps the Ubuntu agent, iCloud sync, analytics hooks if introduced upstream, and any policy module not explicitly represented in Owner Controls.

The product shell, navigation, pairing, server state model, API contract, activity ledger, policy declaration, and Ubuntu companion are Phone Coder-owned modules. Upstream merges must pass a policy-diff review before entering the main branch.

### Inference ownership

`InferenceCoordinator` is the sole owner of heavy runtimes. It serializes GPU work and enforces a generation lease. Chat, vision, and image services request the lease; none creates an independent engine behind the coordinator. A model session has a unique generation ID so stale callbacks cannot mutate a newly loaded session.

Loading a new language model cancels or drains current work, publishes an explicit transition, releases the old engine, clears safe caches, measures memory, then loads. Image generation unloads the language runtime when required and tells the API client that the coding model is temporarily unavailable rather than claiming the server is healthy.

### Server contract

First release endpoints:

- `GET /health` — app, lifecycle, server, model, memory, thermal, queue, and API-version status.
- `GET /v1/models` — loaded and installed callable models.
- `POST /v1/chat/completions` — text chat, SSE streaming, usage, cancellation, and bounded generation parameters.
- `POST /v1/responses` — tool-call-capable response format used by the Ubuntu agent once model qualification passes.
- `DELETE /v1/requests/{id}` — idempotent cancellation for a queued or active request.
- `POST /pair/exchange` — one-time pairing exchange requiring on-phone confirmation.
- `DELETE /pairings/{id}` — on-phone administrative action, not remotely callable with a normal client key.

`/v1/chat/completions` targets the same strict subset already validated by the PWA: `model`, text-only `system`/`user`/`assistant` messages, `stream`, `stream_options.include_usage`, `temperature`, `top_p`, `max_tokens` or `max_completion_tokens`, and up to four string stops. Unsupported fields fail explicitly. The `/v1/responses` release-one profile is versioned as `phone-coder-api/1` and supports text/message input, JSON-schema function tools, `tool_choice` (`auto`, `none`, or `required`), bounded output, usage, and streamed response/output-item/function-call events. It is a documented subset, not a claim of complete OpenAI API parity.

Each request carries `X-Phone-Coder-Request-ID`. Stream events contain monotonically increasing IDs. To reattach, the client repeats the identical POST with the same request ID plus `Last-Event-ID`; the server verifies the request-body fingerprint and attaches to the existing request or bounded completed-response buffer. A mismatched body returns `409 request_conflict`; an expired buffer returns `410 replay_expired`. Reattachment never starts a second inference. A request is automatically rebuilt and retried only when no output event was committed. Cancellation, model-session replacement, backgrounding, or a second runtime failure produces a terminal event and prevents replay as new inference.

Unsupported OpenAI fields return explicit structured errors. Context that exceeds the selected model's limit is rejected with measured token counts; the Ubuntu agent owns compaction and tries again with a new request ID.

### Serving state machine

Serving intent and connectivity are separate:

```text
Stopped → Starting → Ready → Serving ↔ Recovering
                          ↘ Generating ↗
Any active state → PausedBackground → Recovering
Any active state → CoolingDown / LowMemory → Ready
Any state → AuthenticationError / FatalModelError → Stopped
```

Leaving the foreground immediately cancels queued and active generation, closes streams with a background-interrupted terminal result when iOS permits, and marks any remaining request record terminal. Generation is never resumed after backgrounding. Foreground return resumes only the owner's serving intent when the same usable model session remains; clients must submit interrupted work with a new request ID. Manual Stop clears serving intent. Network recovery uses bounded exponential backoff with an immediate Retry action. The UI never loops authentication or pairing failures.

### Ubuntu agent boundary

The Ubuntu agent receives model text/tool proposals and decides whether a tool exists, whether its arguments are valid, and whether approval is required. The phone cannot invoke tools directly. Tool results are size-limited, redacted for configured secrets, and added to the next model turn with stable IDs.

Initial tools are workspace-scoped search, list, read, apply patch, run a command, inspect Git diff/status, and run tests. Shell commands execute without a login shell, with a controlled working directory and environment. Recursive deletes, credential access, privilege escalation, broad filesystem targets, and external network mutations require explicit approval or are rejected.

Command execution also uses OS-level isolation, not prompts alone. On the required Ubuntu target, the runner uses Bubblewrap to bind the selected workspace, provide a minimal read-only system view, hide the user's home and credential stores, and disable network access by default. A task that explicitly needs network access receives a separate approval and a new sandbox with that capability. If the required sandbox cannot initialize, write and command tools fail closed; read-only model chat remains available.

## Privacy and security

- Default and only release-one remote transport is plain HTTP plus bearer authentication carried inside the encrypted Tailscale tunnel. The app does not embed a Tailscale SDK, issue its own TLS certificate, expose plain LAN mode, or advertise an Internet-facing endpoint. Pairing records the phone's tailnet address and refuses non-tailnet destinations in the Ubuntu client.
- The listener accepts only while serving is enabled and the app is active.
- Pairing keys are random, stored in Keychain on iOS and in an owner-only file/keyring on Ubuntu, named per client, and revocable.
- Pairing QR codes use a one-time token and never embed the final reusable bearer key.
- Prompts, responses, file contents, tool results, and generated images are excluded from ordinary logs.
- Diagnostics use event names, durations, byte/token counts, error categories, and redacted model/session identifiers.
- No cloud fallback is automatic. Enabling a future remote provider is a separate feature with explicit disclosure.
- LAN mode, if added, requires app-managed TLS/pinning or a comparably authenticated encrypted transport; plain unauthenticated LAN serving is never shipped.

## Persistence and retention

- Downloaded models, compatibility measurements, app settings, and named pairings persist until the owner deletes or resets them.
- Phone Chat history is local and enabled by default; the owner can disable history, delete individual conversations, or erase all conversations. Disabling history means prompts and responses remain memory-only for that session.
- API prompts, API responses, repository context, and tool results are never persisted on the iPhone. The active/replay request buffer is memory-only and disappears on termination or restart.
- Server activity persists redacted metadata only—time, client name, model, duration, token counts, terminal category—for seven days, with a Clear now action. It stores no request or response text.
- Generated-image history is off by default. Enabling it stores images and their generation parameters locally until individually deleted or erased through data reset.
- The Ubuntu agent stores task transcripts in the selected workspace's `.phone-coder/` directory only after the workspace owner enables history. Without that setting, model text and tool output are memory-only. Approval/audit records retain action type, decision, timestamp, and redacted target for seven days under owner-only permissions; raw secrets and full command output are excluded.
- Exported files and Git commits are outside app retention and are never silently deleted by data reset.

## Reliability design

- Model downloads are resumable and validated for required files and non-zero shard sizes before “Installed” appears.
- An incomplete or corrupt model receives a targeted repair action that preserves pairings and other models.
- Runtime disposal or GPU failure destroys the affected engine and permits one reconstruction/retry only before any output was emitted.
- A persisted in-flight marker detects jetsam/OOM termination and lowers the next safe image/model configuration or blocks a crash loop with an explanation.
- The global runtime gate prevents simultaneous heavy GPU jobs.
- Memory warnings reclaim discardable caches first; only critical pressure unloads model weights.
- Thermal serious reduces workload with visible status; thermal critical stops heavy work.
- Active requests have deadlines, cancellation, bounded output, and a stable terminal result.
- App upgrades preserve model files, settings, pairings, and conversation metadata when schemas are compatible; migrations are explicit and tested.
- The server screen exposes a downloadable redacted diagnostic bundle suitable for issue reports.

## Build and distribution

1. Development and normal tests run on Ubuntu where possible.
2. A public GitHub repository uses a pinned standard macOS/Xcode Actions runner to build the native dependencies, run Swift tests, archive without distribution signing, and package an unsigned IPA.
3. The workflow publishes the IPA, source commit, dependency lockfiles, SHA-256 checksum, and build provenance.
4. Ubuntu installs SideStore initially using the official Linux `iloader` path and USB.
5. The IPA is imported into SideStore and signed on device with the owner's Apple Account.
6. Free-account builds are refreshed within seven days. The app surfaces no misleading promise of permanent installation.

Signing credentials and the user's Apple Account are never stored in the project repository or ordinary CI secrets for the unsigned SideStore workflow.

## Delivery increments

This product is large enough to require separate implementation plans. Each increment produces working, testable software:

### Increment A — Reproducible native shell and installation

Fork and brand the source, reduce it to the selected features, establish Ubuntu tests and GitHub Actions, produce an unsigned IPA, and prove installation/launch/refresh through SideStore on the physical iPhone.

### Increment B — Native runtime and reliable server

Qualify one small coding model and one target coding model, implement the Phone Coder server state machine and API, pair Ubuntu, and pass repeated foreground streaming plus recovery tests. The Ubuntu client at this stage is read-only chat/CLI.

### Increment C — Ubuntu coding agent

Add workspace context, tool schemas, approval policy, patching, commands, tests, Git reporting, bounded agent turns, and failure summaries. Validate on disposable repositories before allowing real workspaces.

### Increment D — Image Studio and owner controls

Audit the upstream image path, remove any undisclosed classifier from the sideload flavor, add transparent Owner Controls and image history behavior, and qualify at least one image model on the physical phone.

### Increment E — Polish and release qualification

Accessibility, localization stress, diagnostics, migration, battery/thermal observations, long-run reliability, documentation, signed checksums, and a recovery playbook.

## Acceptance criteria

### Installation

- A clean Ubuntu machine can trigger/download the documented IPA artifact and install it using the supported Linux SideStore bootstrap.
- The app launches after signing, survives an update without losing downloaded model metadata or pairings, and documents the seven-day free-account refresh.

### Local inference

- After model download, airplane mode plus an already-established local connection can complete local chat without a cloud model service.
- Twenty consecutive bounded coding prompts complete without a Safari/WebGPU-style page refresh because Safari is no longer in the inference path.
- Cancellation ends GPU work and produces one terminal response.
- Oversized context returns token counts and a structured error rather than truncating silently.

### Serving and recovery

- Ubuntu can pair, list the active model, stream a response, cancel it, and reconnect after a brief Tailscale interruption without duplicated output.
- Backgrounding the app ends or pauses the connection visibly; foreground return restores prior serving intent when safe.
- Manual Stop never reconnects by itself.
- Key rotation immediately invalidates the old client.
- A model reload or runtime recovery cannot deliver stale output into a newer session.

### Coding agent

- The agent can inspect a disposable repository, propose a patch, obtain approval, apply it, run a test, and report the diff.
- Read-only, write, command, network, and destructive actions follow distinct approval rules.
- Rejected approval stops that action without corrupting the conversation or workspace.
- Every final result lists changed files and verification actually run.

### Images and policy

- A supported image model generates and displays a benign test image locally.
- The sideload build contains no undisclosed prompt or output classifier and never replaces a generated image with the generic “withheld by local content check” result.
- Model refusals, owner-created rules, device limits, and technical failures have different UI and diagnostic codes.
- Memory and thermal protection remain active regardless of content preferences.

### Accessibility and privacy

- Core flows work with VoiceOver, large accessibility text, Reduce Motion, high contrast, portrait, and landscape.
- Ordinary logs and exported diagnostics contain no prompt, response, repository contents, API key, or generated image.

## Risks and mitigations

- **Fork drift:** keep the upstream commit explicit and review upstream changes by subsystem; never merge wholesale into policy or server modules.
- **Native dependency build time:** cache safe build products in CI, pin all revisions, and publish reproducible artifacts.
- **Model quality:** qualify models with a coding benchmark and tool-call suite; label weak models honestly rather than presenting every downloadable model as agent-capable.
- **iOS suspension:** make foreground-only serving a product rule, keep the screen awake while serving, and recover explicitly after foreground return.
- **Thermal and battery impact:** expose live status, use bounded generations, serialize heavy work, and document charging/heat expectations.
- **Free-signing friction:** provide SideStore refresh instructions and later support a paid developer profile without changing the app architecture.
- **Policy ambiguity:** keep a machine-readable build manifest declaring enabled policy modules and display it in Owner Controls.
- **Tool risk:** keep execution on Ubuntu behind scoped approvals, workspace boundaries, output limits, and an audit trail.

## Migration from the current prototype

- Preserve the existing `iphone-coder` PWA and Python relay unchanged during Increments A and B.
- Reuse its OpenAI request validation, explicit context limits, sequence-number tests, connection-recovery cases, and CLI ergonomics as behavioral references.
- Do not reuse the browser polling transport in the native server; native iOS can accept authenticated inbound requests directly while foregrounded.
- Keep the model alias `iphone-coder` for client compatibility.
- Once native acceptance passes, mark the PWA “Legacy diagnostic mode” and stop adding primary features to it.

## Decisions left to the builder

- Exact Swift file boundaries that follow the fork's current conventions.
- The specific lightweight HTTP/server library or Network.framework wrapper, provided it supports the contract and iOS lifecycle requirements.
- Exact animation durations, haptic patterns, and non-semantic icon choices.
- Internal diagnostics storage format and test-fixture organization.
- The first qualified 3B–8B coding models, based on measured device fit, license, runtime compatibility, and tool-call evaluation at implementation time.

These choices must not change the foreground-only model, owner-visible policy behavior, Ubuntu tool boundary, API compatibility, or acceptance criteria without a design revision.
