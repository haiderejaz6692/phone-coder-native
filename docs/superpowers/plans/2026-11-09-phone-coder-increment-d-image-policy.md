# Phone Coder Increment D Image and Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship native local image generation with auditable owner-visible policy behavior and no hidden prompt/output classifier in the sideload flavor.

**Architecture:** Adapt upstream `ImageGenerationService` behind the text inference coordinator. A bundled machine-readable policy manifest drives Owner Controls and CI assertions; image history is a separate opt-in store, and device safety failures remain distinct from owner preferences and model output.

**Tech Stack:** SwiftUI, MLX Stable Diffusion vendor code, CryptoKit, XCTest, shell artifact inspection.

**Spec:** `docs/superpowers/specs/2026-11-09-phone-coder-native-design.md`

## Global Constraints

- Sideload flavor declares `post_generation_classifier: none` and `prompt_blocklist: owner_only_off_by_default`.
- No hidden classifier model, remote policy, prompt scan, generated-image scan, or silent withholding path may ship.
- Memory, thermal, lifecycle, crash-marker, model-file, and residency protections remain active and non-disableable.
- Generated-image history is off by default and local-only when enabled.
- Image generation may unload text; the server must report temporary unavailability instead of stale readiness.
- Model weights stay outside Git and retain their own licenses.

## Review Focus

- Manifest/executable divergence: Task 1 validates source, bundle, and UI against one typed manifest.
- Upstream checker entering through a merge/resource: Task 1 scans source and IPA for forbidden modules, strings, and classifier assets.
- Text work accepted during image residency: Task 2 tests coordinator health transitions.
- Image saved while history is off or after failure: Task 4 tests every terminal path.
- Device refusal mislabeled as policy: Tasks 2, 3, and 5 assert distinct typed codes and copy.

---

## File Structure

- Create `IOSLocalLLM/PhoneCoder/Policy/PhoneCoderPolicyManifest.swift` and `phone-coder-policy.json`.
- Create `IOSLocalLLM/PhoneCoder/Policy/OwnerControlsStore.swift`.
- Create `IOSLocalLLM/PhoneCoder/Runtime/PhoneCoderImageRuntime.swift` and `OnDeviceImageRuntimeAdapter.swift`.
- Create `IOSLocalLLM/PhoneCoder/Models/ImageHistoryStore.swift`.
- Create `IOSLocalLLM/PhoneCoder/Views/ImageStudioView.swift`, `ImageStudioViewModel.swift`, and `OwnerControlsView.swift`.
- Modify upstream image, coordinator, settings/root, wipe, project, and CI files named in tasks.
- Create `scripts/validate_policy_flavor.sh` and focused tests.

### Task 1: Make shipped policy machine-readable and testable

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Policy/phone-coder-policy.json`
- Create: `IOSLocalLLM/PhoneCoder/Policy/PhoneCoderPolicyManifest.swift`
- Create: `IOSLocalLLMTests/PhoneCoderPolicyManifestTests.swift`
- Create: `scripts/validate_policy_flavor.sh`
- Modify: `project.yml`

**Interfaces:**
- Produces: `PhoneCoderPolicyManifest.current`, bundled JSON, CI validator.
- Consumes: `PhoneCoderBuildManifest.policyFlavor`.

- [ ] **Step 1: Write failing manifest tests**

Assert schema version 1, flavor `sideload-owner-controlled`, classifier `none`, blocklist `owner_only_off_by_default`, refusal source `model`, mandatory gates `[memory, thermal, lifecycle, model_integrity]`, no remote policy URL, and JSON/Swift equality.

- [ ] **Step 2: Write failing source/artifact validator tests**

The validator rejects forbidden policy modules/resources and the generic withholding strings, inspects an unpacked IPA, and allows those strings only in an explicit test-fixture allowlist.

- [ ] **Step 3: Run and confirm RED**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderPolicyManifestTests` and `bash scripts/validate_policy_flavor.sh --source .`; expect missing manifest/validator failures.

- [ ] **Step 4: Implement manifest and validator**

Define `PhoneCoderPolicyManifest: Codable, Equatable, Sendable` with exact schema/flavor/classifier/prompt/gate/remote-policy fields. Bundle the JSON and fail closed if it is missing or disagrees with the Swift constants.

- [ ] **Step 5: Run tests and commit**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderPolicyManifestTests` and `bash scripts/validate_policy_flavor.sh --source .`, then commit the five files with message `feat: declare auditable Phone Coder policy`.

### Task 2: Coordinate image generation with text runtime residency

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Runtime/PhoneCoderImageRuntime.swift`
- Create: `IOSLocalLLM/PhoneCoder/Runtime/OnDeviceImageRuntimeAdapter.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Runtime/InferenceCoordinator.swift`
- Modify: `IOSLocalLLM/Services/ImageGenerationService.swift`
- Create: `IOSLocalLLMTests/PhoneCoderImageRuntimeTests.swift`

**Interfaces:**
- Consumes: Increment B inference coordinator and upstream image service.
- Produces: `PhoneCoderImageRuntime`, `PhoneCoderImageRequest`, `PhoneCoderImageResult`, coordinator image lease.

- [ ] **Step 1: Write failing runtime/coordinator tests**

Test image lease draining text, server health `temporarily_unavailable:image_generation`, progress, cancel, background terminal, memory/thermal/integrity refusals, crash-marker downshift, stale callback rejection, and success returning image data with no classifier stage.

- [ ] **Step 2: Run and confirm RED**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderImageRuntimeTests`; expect missing protocol/adapter.

- [ ] **Step 3: Implement the adapter and lease**

Define `installedModels()`, `generate(_:onProgress:)`, `cancel()`, and `unload()` on `PhoneCoderImageRuntime`. Adapt upstream download validation, memory admission, global generation gate, two-stage decode, crash marker, and cleanup without prompt/output scanning.

- [ ] **Step 4: Run image, residency, safety, and server health tests**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderImageRuntimeTests -only-testing:PhoneCoderTests/DeviceTierAdvisorTests`; expected PASS.

- [ ] **Step 5: Commit**

Commit runtime/adapter/coordinator/service/tests with message `feat: coordinate native image runtime`.

### Task 3: Build the Image Studio experience

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Views/ImageStudioView.swift`
- Create: `IOSLocalLLM/PhoneCoder/Views/ImageStudioViewModel.swift`
- Modify: `IOSLocalLLM/PhoneCoder/App/PhoneCoderRootView.swift`
- Create: `IOSLocalLLMTests/PhoneCoderImageStudioViewModelTests.swift`

**Interfaces:**
- Consumes: image coordinator and policy manifest.
- Produces: prompt/model/options/generation/result UI.

- [ ] **Step 1: Write failing view-model tests**

Test empty prompt; model missing/download/load/generate/cancel/progress/success; option validation; device, owner-rule, model, and technical error mappings; policy line always present; and no generic withheld result.

- [ ] **Step 2: Run and confirm RED**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderImageStudioViewModelTests`; expect missing types.

- [ ] **Step 3: Implement the screen**

Use prompt/model/Generate defaults, expandable supported options, square preview, progress, cancel, retry, share, and visible “Local generation · No output filter” text sourced from the manifest. Give memory, heat, lifecycle, owner rule, model refusal, and technical errors different icons/codes.

- [ ] **Step 4: Run tests and accessibility checks**

Verify large text, VoiceOver, light/dark, landscape, Reduce Motion, long names, and disabled states.

- [ ] **Step 5: Commit**

Commit screen/view-model/root/tests with message `feat: add transparent Image Studio`.

### Task 4: Add opt-in image history and export

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Models/ImageHistoryStore.swift`
- Create: `IOSLocalLLMTests/PhoneCoderImageHistoryTests.swift`
- Modify: `IOSLocalLLM/PhoneCoder/Views/ImageStudioViewModel.swift`
- Modify: `IOSLocalLLM/Services/WipeAllDataService.swift`

**Interfaces:**
- Produces: `ImageHistoryStore.save`, `list`, `delete`, `clear`; share/export URL.
- Consumes: successful image result and history preference only.

- [ ] **Step 1: Write failing history tests**

Test default off; no write on success while off, failure, cancel, or owner rule; atomic protected PNG+metadata write when on; corrupt cleanup; bounded thumbnail cache; delete/clear; migration; reset; and share without enabling history.

- [ ] **Step 2: Run and confirm RED**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderImageHistoryTests`; expect missing store.

- [ ] **Step 3: Implement history storage**

Use a schema-versioned app-container directory with model ID, non-secret parameters, timestamp, and image hash. Store prompt text only when the separate “include prompts” option is enabled; default off.

- [ ] **Step 4: Run history, wipe, and migration tests**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderImageHistoryTests -only-testing:PhoneCoderTests/WipeKeychainTests`; expected PASS.

- [ ] **Step 5: Commit**

Commit store/view-model/wipe/tests with message `feat: add opt-in local image history`.

### Task 5: Implement Owner Controls and policy diagnostics

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Policy/OwnerControlsStore.swift`
- Create: `IOSLocalLLM/PhoneCoder/Views/OwnerControlsView.swift`
- Create: `IOSLocalLLM/PhoneCoder/Views/SettingsView.swift`
- Create: `IOSLocalLLMTests/PhoneCoderOwnerControlsTests.swift`

**Interfaces:**
- Consumes: policy manifest, image history preference, network/server configuration.
- Produces: visible declaration and optional exact owner blocklist.

- [ ] **Step 1: Write failing owner-control tests**

Test classifier “Not installed,” blocklist default off, visible entries, literal normalized matching, no regex behavior, remove/clear, model refusals non-overridable, device gates non-toggleable, v1 Tailscale mode read-only, and reset behavior.

- [ ] **Step 2: Run and confirm RED**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderOwnerControlsTests`; expect missing store/view.

- [ ] **Step 3: Implement settings and matching**

Use owner-created literal phrases with Unicode normalization/case folding; match before generation and return `owner_rule_blocked(ruleID:)`. Add no built-in phrases and no output scan.

- [ ] **Step 4: Run tests and UI checks**

Expected: PASS with every policy statement derived from typed data.

- [ ] **Step 5: Commit**

Commit policy/settings/tests with message `feat: add owner-visible policy controls`.

### Task 6: Qualify image generation and inspect the IPA

**Files:**
- Create: `docs/qualification/image-studio-iphone17promax.md`
- Modify: `.github/workflows/phone-coder-ios.yml`

**Interfaces:**
- Consumes: built IPA, validator, supported downloaded image model.
- Produces: device report and artifact policy evidence.

- [ ] **Step 1: Add policy validation to CI artifact job**

Validate source and unpacked IPA before upload; include policy JSON hash in `build-metadata.json`.

- [ ] **Step 2: Run the benign qualification matrix**

Verify download/repair, generation, progress, cancel, background cancel, share, history off/on, text-server temporary unavailability, memory refusal, thermal behavior, model switch, and relaunch.

- [ ] **Step 3: Verify transparent policy behavior**

Confirm Owner Controls matches the manifest, owner rules work only when enabled, no classifier asset exists, successful images display directly, and no generic local-content-withholding state exists.

- [ ] **Step 4: Record evidence**

Record device/iOS/app/model/version/quantization, policy and IPA hashes, observable memory/thermal data, durations, pass/fail, and limitations without committing private generated images.

- [ ] **Step 5: Commit**

Commit report/workflow with message `test: qualify transparent image generation`.

## Increment D Completion Check

Run policy, image-runtime, Image Studio, history, owner-control, wipe/migration, safety/residency, CI artifact inspection, and physical-device qualification. Increment D is complete only when the shipped IPA's declared policy matches its executable/resources and image output is never silently withheld.
