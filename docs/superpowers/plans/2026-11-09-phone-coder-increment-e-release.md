# Phone Coder Increment E Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the working Phone Coder system into a verifiable release with accessibility, privacy-safe diagnostics, migration/reset behavior, model qualification, physical-device soak evidence, licensing, checksums, and recovery documentation.

**Architecture:** Release qualification is evidence-driven. Automated checks validate UI semantics, redaction, storage migrations, policy/build metadata, Ubuntu sandbox behavior, and artifact contents; physical-device scripts validate only properties Simulator cannot prove. One release manifest links source, IPA, checksum, policy, dependencies, tests, and device reports.

**Tech Stack:** XCTest/XCUITest, SwiftUI accessibility, Python/pytest, Bash, GitHub Actions attestations, SPDX SBOM, SideStore.

**Spec:** `docs/superpowers/specs/2026-11-09-phone-coder-native-design.md`

## Global Constraints

- Simulator results never establish Jetsam, Metal residency, sustained thermal, battery, or background-suspension claims.
- Diagnostics contain no API keys, prompts, responses, repository content, tool arguments, generated images, credentials, or unredacted user paths.
- Release artifacts contain no model weights, generated dependency caches, signing material, provisioning profiles, transcripts, or user data.
- The exact iPhone 17 Pro Max/iOS build, Ubuntu 26.04 x86_64 environment, model revisions/quantizations, and source SHA are recorded.
- A known failure remains a documented limitation; it is not converted into a passing claim by retrying until one run succeeds.

## Review Focus

- Accessibility label exists but action/state is unusable at large text: Task 1 exercises real flows at accessibility sizes.
- Redaction misses nested errors or command output: Task 3 uses seeded canary secrets across every diagnostic input.
- Update/reset revives deleted history/pairings: Task 4 tests schema upgrades, wipe, reinstall, and SideStore update.
- Model tool-calling looks good on one hand-picked task: Task 5 uses a versioned multi-case benchmark and publishes failures.
- Soak report omits interruptions or only counts successes: Task 6 records every attempt and terminal category.

---

## File Structure

- Create `IOSLocalLLMUITests/PhoneCoderAccessibilityUITests.swift` and supporting launch fixtures.
- Create `IOSLocalLLM/PhoneCoder/Diagnostics/DiagnosticEvent.swift`, `DiagnosticStore.swift`, `DiagnosticExporter.swift`.
- Create `IOSLocalLLM/PhoneCoder/Models/PhoneCoderDataSchema.swift`, `PhoneCoderMigration.swift`.
- Modify localization resources, settings/reset, project/workflows, privacy/legal/SBOM/release docs.
- Create `benchmarks/coding-agent/` fixtures/runner/expected outcomes.
- Create `scripts/qualification/phone_coder_soak.py` and tests.
- Create `.github/workflows/phone-coder-release.yml` and release validators.

### Task 1: Complete accessibility and adaptive-layout qualification

**Files:**
- Create: `IOSLocalLLMUITests/PhoneCoderAccessibilityUITests.swift`
- Create: `IOSLocalLLM/PhoneCoder/App/PhoneCoderUITestFixture.swift`
- Modify: `project.yml`
- Create: `docs/qualification/accessibility.md`

**Interfaces:**
- Produces: deterministic launch fixtures for all major states and XCUITest coverage for core flows.
- Consumes: all five tabs and their view models.

- [ ] **Step 1: Write failing UI tests**

Cover VoiceOver identifiers/order, keyboard navigation where supported, 44-point targets, accessibility text sizes, portrait/landscape, light/dark, increased contrast, Reduce Motion, RTL, long model/client names, Server start/stop, pairing approval, model selection, Chat send/stop, Image generate/cancel, Owner Controls, and error recovery.

- [ ] **Step 2: Run and confirm RED**

Run the UI test scheme against an iPhone 17 Pro Simulator; expect missing fixtures/identifiers or layout failures.

- [ ] **Step 3: Add deterministic fixtures and repair UI semantics/layout**

Inject fake services through launch arguments/environment; never require model weights in UI tests. Replace clipped fixed layouts with adaptive stacks/scrolling and ensure status is conveyed by text/icon as well as color.

- [ ] **Step 4: Run the complete UI matrix**

Run XCUITest for standard and accessibility text sizes in portrait and landscape, plus RTL/high-contrast/Reduce Motion fixture runs. Record screenshots as CI artifacts, not source assets.

- [ ] **Step 5: Commit**

Commit tests/fixtures/project/report with message `test: qualify Phone Coder accessibility`.

### Task 2: Add localization stress and copy consistency

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Resources/Localizable.xcstrings`
- Create: `IOSLocalLLMTests/PhoneCoderLocalizationTests.swift`
- Modify: Phone Coder views to use stable localization keys.

**Interfaces:**
- Produces: typed/stable keys for status, errors, owner policy, approvals, and primary actions.
- Consumes: typed state/error enums.

- [ ] **Step 1: Write failing localization tests**

Assert every user-visible state/error/action/policy code has a key; no raw technical error leaks to UI; format placeholders agree; English strings avoid “safe” for content preferences; and pseudo-localized 2× strings remain reachable.

- [ ] **Step 2: Run and confirm RED**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderLocalizationTests`; expect hard-coded/missing keys.

- [ ] **Step 3: Move release-one copy to the string catalog**

Keep logs/API codes unlocalized; localize only user-facing copy. Ensure memory, thermal, lifecycle, owner rule, model refusal, authentication, and network messages remain distinct.

- [ ] **Step 4: Run tests and pseudo-localized UI suite**

Expected: PASS.

- [ ] **Step 5: Commit**

Commit catalog/view/test changes with message `feat: localize Phone Coder interface`.

### Task 3: Implement privacy-safe diagnostics and export

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Diagnostics/DiagnosticEvent.swift`
- Create: `IOSLocalLLM/PhoneCoder/Diagnostics/DiagnosticStore.swift`
- Create: `IOSLocalLLM/PhoneCoder/Diagnostics/DiagnosticExporter.swift`
- Create: `IOSLocalLLMTests/PhoneCoderDiagnosticsTests.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Views/ServerView.swift`

**Interfaces:**
- Produces: allowlisted diagnostic events, seven-day retention, redacted export bundle.
- Consumes: server/controller/runtime/activity terminal metadata only.

- [ ] **Step 1: Write failing redaction/retention tests**

Seed canary API keys, prompts, model output, paths, filenames, command args/output, URLs with tokens, nested NSError fields, pairing IDs, image bytes, and Unicode secrets. Assert none appear in store/export; assert only allowlisted fields survive; test rotation, seven-day pruning, Clear now, file protection, and interrupted export cleanup.

- [ ] **Step 2: Run and confirm RED**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderDiagnosticsTests`; expect missing store/exporter.

- [ ] **Step 3: Implement allowlist-first diagnostics**

Use structured event enums rather than arbitrary strings. Export build/policy/API versions, redacted device/runtime state, timings, counts, and terminal codes to a temporary ZIP or directory; delete temporary exports after share completion/timeout.

- [ ] **Step 4: Run diagnostics plus static log scan**

Add CI grep/static checks that forbid direct prompt/output/key logging calls in Phone Coder modules. Run tests; expect PASS.

- [ ] **Step 5: Commit**

Commit diagnostics/UI/tests/validator with message `feat: add privacy-safe diagnostics`.

### Task 4: Lock storage schemas, migration, wipe, and update behavior

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Models/PhoneCoderDataSchema.swift`
- Create: `IOSLocalLLM/PhoneCoder/Models/PhoneCoderMigration.swift`
- Create: `IOSLocalLLMTests/PhoneCoderMigrationTests.swift`
- Modify: `IOSLocalLLM/Services/WipeAllDataService.swift`
- Modify: `IOSLocalLLM/Models/ConversationStore.swift`
- Modify: pairing/activity/image/owner-control stores.

**Interfaces:**
- Produces: versioned migration coordinator and explicit wipe scopes.
- Consumes: all persisted Phone Coder stores.

- [ ] **Step 1: Write failing migration/wipe tests**

Cover new install, current schema no-op, supported previous schema, corrupted record quarantine, interrupted migration resume/rollback, history-disabled memory-only behavior, conversation delete persistence, pairing/key wipe, owner-rule wipe, image/history wipe, activity/diagnostics wipe, model-preserve option, erase-everything option, and SideStore update preserving intended data without reviving deleted records.

- [ ] **Step 2: Run and confirm RED**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderMigrationTests`; expect missing schema coordinator.

- [ ] **Step 3: Implement versioned stores and reset transaction**

Each store declares a schema version and migration. Wipe first blocks new work/stops server, cancels inference, clears in-memory replay, deletes selected stores/Keychain items atomically where possible, records completion without sensitive data, and updates UI only after verification.

- [ ] **Step 4: Run automated tests and physical update/reset matrix**

Install build N, create representative data, update to N+1 through SideStore, verify persistence/deletions, exercise both reset scopes, relaunch, and record results without committing private contents.

- [ ] **Step 5: Commit**

Commit schema/migrations/store changes/tests with message `feat: version Phone Coder local data`.

### Task 5: Qualify release-one coding models

**Files:**
- Create: `benchmarks/coding-agent/README.md`
- Create: `benchmarks/coding-agent/cases.json`
- Create: `benchmarks/coding-agent/run.py`
- Create: `benchmarks/coding-agent/test_run.py`
- Create: `docs/qualification/model-matrix.md`

**Interfaces:**
- Produces: versioned benchmark results for candidate 3B–8B models.
- Consumes: PhoneClient/agent, deterministic disposable repositories, model metadata.

- [ ] **Step 1: Define benchmark cases and scoring before running models**

Include repository search, single-file bug fix, multi-file constrained refactor, test failure diagnosis, malformed-tool recovery, rejection handling, context-limit compaction, no-change explanation, and malicious repository instruction/tool-argument cases. Define pass criteria and maximum turns/tokens/time per case.

- [ ] **Step 2: Write runner tests**

Test deterministic fixture reset, result schema, timeout, partial failure, no secret capture, exact verification commands, score computation, and all-attempt accounting.

- [ ] **Step 3: Implement and verify the runner**

Run scripted fake-model fixtures first. Store only public fixture prompts/results and redacted performance metadata.

- [ ] **Step 4: Run candidates on the iPhone 17 Pro Max**

Record model repo/revision/quantization/license, disk/RAM estimates, context/output limits, tokens/sec, load time, task scores, malformed calls, thermal state, and failures. Select one compatibility model and one recommended coding model based on published criteria.

- [ ] **Step 5: Commit benchmark and report**

Commit public fixtures/runner/matrix with message `test: qualify local coding models`.

### Task 6: Run reliability, lifecycle, thermal, and battery soak

**Files:**
- Create: `scripts/qualification/phone_coder_soak.py`
- Create: `scripts/qualification/tests/test_phone_coder_soak.py`
- Create: `docs/qualification/iphone17promax-soak.md`

**Interfaces:**
- Produces: machine-readable attempt log and human qualification report.
- Consumes: native server, Ubuntu client, selected release models.

- [ ] **Step 1: Write soak-runner tests**

Test all-attempt recording, sequence duplication/missing detection, cancellation, scheduled disconnect, background checkpoint, key rotation, model reload, queue pressure, process restart, timeout, thermal refusal, and report aggregation that cannot drop failures.

- [ ] **Step 2: Implement the runner**

Provide scenario selection, bounded duration/request count, redacted JSONL output, deterministic request IDs, and an operator prompt for foreground/background/manual thermal checkpoints. Never automate retries beyond product rules.

- [ ] **Step 3: Execute physical soak**

Run at least: 100 sequential short requests, 20 bounded coding-agent tasks, 10 cancellation cases, 10 disconnect/reattach cases, 5 background/foreground interruptions, model unload/reload cycles, and a 60-minute foreground serving window. Record battery start/end, charging state, iOS thermal states, app terminations, latency, and every terminal category.

- [ ] **Step 4: Analyze honestly**

List pass rates and every failure. Any duplicate output, stale-session output, workspace escape, credential disclosure, unexplained app termination, or hidden withholding is release-blocking.

- [ ] **Step 5: Commit runner/report**

Commit with message `test: soak Phone Coder on iPhone 17 Pro Max`.

### Task 7: Produce the verified release artifact and recovery playbook

**Files:**
- Create: `.github/workflows/phone-coder-release.yml`
- Create: `scripts/validate_phone_coder_release.sh`
- Create: `docs/RELEASE.md`
- Create: `docs/RECOVERY.md`
- Create: `docs/SECURITY_MODEL.md`
- Modify: `SBOM.spdx.json`, `THIRD_PARTY_NOTICES.md`, `PRIVACY_POLICY.md`, `README.md`

**Interfaces:**
- Produces: source archive, unsigned IPA, SHA-256 files, attestation, build metadata, policy manifest, SBOM, test summaries, release notes.
- Consumes: all prior increment outputs/evidence.

- [ ] **Step 1: Write failing release validator checks**

Assert matching semantic version/tag/build manifest, exact upstream commit, policy hash, dependency locks, required qualification reports, passing CI summaries, IPA/source checksums, artifact forbidden-file scan, notices/SBOM coverage, unsigned state, and no credentials/user data.

- [ ] **Step 2: Run and confirm RED**

Run `bash scripts/validate_phone_coder_release.sh`; expect missing workflow/docs/evidence failures.

- [ ] **Step 3: Implement release workflow and documentation**

Pin actions by commit; build/test/package once from the tag; attest source and IPA; publish checksum/build metadata/policy/SBOM/reports. Recovery covers corrupt model repair, key loss/rotation, SideStore expiry, iPhone background interruption, runtime failure, low memory, heat, failed migration, and complete data reset.

- [ ] **Step 4: Dry-run and verify a release candidate**

Create an RC tag in a test release, download on Ubuntu, verify attestations/checksums, install/update through SideStore, run smoke probes, and confirm docs match the actual artifact.

- [ ] **Step 5: Commit release machinery**

Commit workflow/validators/docs/notices/SBOM with message `release: qualify Phone Coder distribution`.

## Increment E Completion Check

Run the entire plan-set verification matrix. A release is complete only when the same tagged source produces the published unsigned IPA, the artifact passes policy/privacy/licensing scans, Ubuntu verifies and installs it, and the iPhone 17 Pro Max qualification reports show no release-blocking failure.
