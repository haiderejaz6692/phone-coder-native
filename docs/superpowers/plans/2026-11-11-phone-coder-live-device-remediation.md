# Phone Coder Live-Device Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the proven keyboard obstruction, make image execution diagnosable and truthful, expose real working-memory information, and polish the five existing screen interiors without changing the approved dock.

**Architecture:** Add narrow, injectable presentation boundaries around existing memory and image owners. Views consume immutable snapshots and typed operation state; runtime admission and lifecycle owners remain unchanged. Each behavior is developed test-first, reviewed independently, and then qualified as synthetic, native integration, and physical-device evidence.

**Tech Stack:** Swift 6, SwiftUI, UIKit image decoding, Darwin task/process memory APIs, XCTest, XcodeGen, existing MLX/Stable Diffusion runtime.

**Spec:** `docs/superpowers/specs/2026-11-09-phone-coder-native-design.md` (Live-device remediation amendment — 2026-11-11)

## Global Constraints

- Preserve Chat / Models / Server / Images / Settings, existing tab IDs and SF Symbols, and default center Server selection.
- Preserve `ModelResidency`, `MLXGenerationGate`, memory/thermal/lifecycle gates, cancellation drain, crash recovery, server security, and local-only inference.
- Do not add a content classifier, prompt scanning, cloud fallback, parallel loader, or raw prompt/image/credential/path data to diagnostics.
- Use native controls, semantic colors, system typography, 44-point targets, Dynamic Type, VoiceOver, RTL, Reduce Motion, safe areas, and light/dark mode.
- Strict TDD: add one failing behavioral test, record the expected RED, add only the minimal production behavior, then record GREEN. Ubuntu source checks are not substitutes for native XCTest or physical verification.
- Do not push, publish, merge, install, sign, or alter device/network state without explicit user approval.

## Review Focus

- Missing/zero kernel readings remain “Unavailable” and never become fake free memory — Task 1 tests it.
- A previous generated image cannot survive as the apparent result of a failed/cancelled/new request — Task 2 tests operation identity and clearing.
- PNG decode failure and post-denoise finalization are visible failures/phases, not false success at 100% — Task 2 tests both.
- Done/scroll dismissal preserves multiline and numeric drafts while successful actions clear focus — Task 3 native UI tests it.
- Large Dynamic Type, landscape, RTL, dark mode, and reduced motion retain actions and the approved dock — Task 4 verifies the fixture matrix.

---

### Task 1: Shared working-memory and device-safety snapshot

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Presentation/PhoneCoderDeviceSnapshot.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Views/SettingsView.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Views/ModelsView.swift`
- Test: `IOSLocalLLMTests/PhoneCoderViewModelTests.swift`

**Interfaces:**
- Consumes: `MemoryAdvisor` and `DeviceSafetyMonitor` readings.
- Produces: immutable `PhoneCoderDeviceSnapshot`, injectable `PhoneCoderDeviceSnapshotProviding`, and formatted rows that label raw, derived, estimated, and unavailable values.

- [ ] **Step 1: Write failing snapshot/presentation tests** for physical capacity vs footprint vs process ceiling/headroom, unavailable zero readings, entitlement state, thermal state, and stable redacted diagnostics output.
- [ ] **Step 2: Verify RED** with the focused native test selector when available; on Ubuntu record native tool absence and run the narrow source/test-registration gate that must fail because the new interface is missing.
- [ ] **Step 3: Implement the minimal injectable sampler and presentation**, refresh on view appearance/foreground/manual refresh, and use it in Settings and Models without duplicating runtime admission logic.
- [ ] **Step 4: Verify GREEN** with focused tests and project/test membership validation; record native execution separately from Ubuntu checks.
- [ ] **Step 5: Commit** `feat: show real Phone Coder memory headroom`.

### Task 2: Honest image readiness, phases, results, and diagnostics

**Files:**
- Modify: `IOSLocalLLM/Services/ImageGenerationService.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Views/ImagesView.swift`
- Modify: `IOSLocalLLM/PhoneCoder/PhoneCoderPresentation.swift`
- Create: `IOSLocalLLMTests/PhoneCoderImageGenerationTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: Task 1 snapshot provider and existing image download/residency/generation owners.
- Produces: typed redacted image stage/failure/readiness presentation, operation identity, explicit finalizing/decode boundary, and safe Copy/Share diagnostics text.

- [ ] **Step 1: Write failing tests** for installed-vs-admitted language, loading/denoising/finalizing ordering, invalid PNG failure, stale callback rejection, old-result clearing, user/background cancellation, safe error categorization, and diagnostic redaction sentinels.
- [ ] **Step 2: Verify RED** before modifying service code; preserve the first failure output.
- [ ] **Step 3: Implement the minimal typed state and image publication seam**. Clear/associate results at operation start, fail on undecodable PNG, expose finalizing after denoise, and map existing errors without weakening safety or changing vendor generation code.
- [ ] **Step 4: Refresh Images around readiness and result** with one primary Download/Generate/Cancel action, inline recovery, technical-details disclosure, memory fit, and result visibility.
- [ ] **Step 5: Verify GREEN** with focused image tests plus existing residency/coordinator/device-safety tests.
- [ ] **Step 6: Commit** `fix: make image generation state observable and honest`.

### Task 3: Native keyboard ownership and dismissal

**Files:**
- Modify: `IOSLocalLLM/PhoneCoder/Views/ChatView.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Views/ImagesView.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Views/SettingsView.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Views/PairingSheet.swift` if it contains editable text.
- Create: `IOSLocalLLMUITests/PhoneCoderKeyboardTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: existing model actions and validation.
- Produces: scoped `FocusState` values, visible keyboard Done action, interactive scroll dismissal, and action-specific focus clearing.

- [ ] **Step 1: Write failing native UI tests** for Chat multiline draft, Images prompt/negative prompt/steps/seed, Settings port, and discovered pairing input: Done preserves values, number pads dismiss, failed validation preserves focus/value, accepted actions dismiss, and tabs do not trap focus.
- [ ] **Step 2: Verify RED** on the native UI target; if native execution is unavailable locally, retain the tests as RED-pending and do not call the behavior verified until the pinned macOS run.
- [ ] **Step 3: Implement scoped focus and dismissal** using `@FocusState`, keyboard toolbar, and `.scrollDismissesKeyboard(.interactively)` where scrolling exists. Do not add a global tap recognizer.
- [ ] **Step 4: Verify GREEN** on the UI target and run focused view-model regressions.
- [ ] **Step 5: Commit** `fix: make Phone Coder keyboards dismissible`.

### Task 4: Cohesive native screen hierarchy and integration gate

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Presentation/PhoneCoderDesignSystem.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Views/ChatView.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Views/ModelsView.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Views/ServerView.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Views/ImagesView.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Views/SettingsView.swift`
- Modify: `IOSLocalLLMTests/PhoneCoderViewModelTests.swift`
- Modify: `IOSLocalLLMTests/PhoneCoderRootNavigationTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3 presentation/state APIs.
- Produces: shared native spacing/surface/status components and coherent five-screen interiors; root navigation remains unchanged.

- [ ] **Step 1: Write failing presentation/navigation tests** for one primary action, nonempty status/recovery labels, long-name wrapping, stable tab order/default Server, and accessibility labels.
- [ ] **Step 2: Verify RED** and preserve the first failure.
- [ ] **Step 3: Apply the minimal visual pass**: clean conversation canvas and bottom composer; compact status/readiness headers; grouped native cards/sections; progressive technical details; consistent spacing, materials, progress, error and empty states. Use semantic system colors and SF Symbols only.
- [ ] **Step 4: Run focused GREEN tests**, then the native visual/accessibility fixture matrix at small phone/landscape/light/dark/RTL/largest Dynamic Type/reduced motion.
- [ ] **Step 5: Run meaningful integration gates once**: local workflow validation, qualification probe unit suite, CI regression suite, full pinned native XCTest/archive/package workflow for the candidate SHA, and independent whole-diff review. Preserve any first failure/retry classification.
- [ ] **Step 6: Commit** `feat: polish Phone Coder native experience`.

### Task 5: Exact-build physical qualification and release-readiness record

**Files:**
- Modify: `docs/qualification/native-server-iphone17promax.md`
- Create: `.superpowers/sdd/2026-11-11-phone-coder-live-device-remediation/release-readiness.md`

**Interfaces:**
- Consumes: reviewed packaged candidate, checksum, signing/install provenance, and existing qualification probe.
- Produces: separated synthetic/native/live evidence and an evidence-based go/no-go recommendation.

- [ ] **Step 1: Verify package metadata/checksum and rollback path** without installing or altering the device until the user explicitly approves that external step.
- [ ] **Step 2: On approval, install the exact build and execute keyboard, memory, image success/share/cancel/background/text-image-text, real Keychain, and complete small/target-model Tailscale matrix.** Record no prompts, outputs, images, bearers, or full identifiers.
- [ ] **Step 3: Record PASS/FAIL/BLOCKED/NOT RUN separately** for synthetic, native integration, and live checks. One successful image is scoped to its exact model/preset/run.
- [ ] **Step 4: Independently review all fixes and the evidence record; resolve every Critical/Important finding.**
- [ ] **Step 5: Produce release-readiness and rollback recommendation.** Do not claim completion while required physical behavior is unverified.
