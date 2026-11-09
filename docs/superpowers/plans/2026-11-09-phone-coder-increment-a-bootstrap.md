# Phone Coder Increment A Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a reproducible Phone Coder native shell, unsigned IPA, checksum, and Ubuntu-to-SideStore installation proof.

**Architecture:** Fork the upstream server-only `OnDeviceLAS` target at the approved commit, rename it without rewriting inference code, compile only the llama.cpp native framework required by release one, and package an unsigned IPA on GitHub's macOS runner. The first device build is a shell with Server as its center tab; functional serving arrives in Increment B.

**Tech Stack:** SwiftUI, XcodeGen, XCTest, Bash, llama.cpp XCFramework, GitHub Actions, SideStore/iloader.

**Spec:** `docs/superpowers/specs/2026-11-09-phone-coder-native-design.md`

## Global Constraints

- Baseline commit: `cc4e2d3f25dfe77e9ef9e629ee6ddc7e3134ac88`.
- iOS 18.0 minimum; iPhone-only target; product name `Phone Coder`; bundle identifier `com.haider.phonecoder`.
- Use `project.yml`; do not hand-edit generated project settings as the source of truth.
- Build only the release-one native dependency; do not build or link whisper.cpp, voice, vision, RAG, cloud, iCloud, or Mac-agent features.
- CI artifacts contain no model weights, signing credentials, provisioning profiles, or generated dependency caches.
- The unsigned IPA must be installable through SideStore after on-device signing.

## Review Focus

- Upstream identity remaining in bundle IDs, Keychain services, URL schemes, or visible copy: Task 1 includes recursive identity tests.
- Two `@main` app entries or excluded source accidentally compiling: Task 2 builds the exact target and tests source membership.
- Standard runner disk exhaustion: Task 3 asserts llama-only build behavior and records peak disk use.
- IPA with wrong archive layout or signed residue: Task 4 inspects `Payload/Phone Coder.app` and rejects embedded provisioning/signatures.
- Linux instructions drifting from the real artifact: Task 5 verifies commands against the downloaded IPA and checksum.

---

## File Structure

- Modify `project.yml` — Phone Coder target, scheme, identifiers, sources, resources, tests.
- Modify `IOSLocalLLM/IOSLocalLLMApp.swift` — Phone Coder app entry and lifecycle hook.
- Create `IOSLocalLLM/PhoneCoder/App/PhoneCoderRootView.swift` — five-tab shell.
- Create `IOSLocalLLM/PhoneCoder/App/PhoneCoderBuildManifest.swift` — auditable product/build/policy metadata.
- Create `IOSLocalLLMTests/PhoneCoderAppIdentityTests.swift` — identity and build-manifest tests.
- Modify `scripts/build_native_frameworks.sh` — explicit `--llama-only` mode.
- Create `scripts/tests/test_build_native_frameworks.sh` — CLI/selection regression tests.
- Create `scripts/package_unsigned_ipa.sh` — deterministic IPA packaging.
- Create `scripts/tests/test_package_unsigned_ipa.sh` — package-layout/signing-residue tests.
- Create `.github/workflows/phone-coder-ios.yml` — build, test, package, checksum, artifact upload.
- Create `scripts/validate_phone_coder_workflows.sh` — pinned workflow invariants.
- Create `docs/installation/ubuntu-sidestore.md` — Linux bootstrap, install, refresh, recovery.
- Create `docs/installation/device-acceptance-a.md` — physical launch/install checklist.
- Modify `README.md`, `THIRD_PARTY_NOTICES.md`, `PRIVACY_POLICY.md` — fork identity, provenance, exclusions.

### Task 0: Materialize the approved upstream fork

**Files:**
- Create repository: `/home/haider/Documents/ChatGPT/ubuntu/phone-coder-native`
- Create: `UPSTREAM_BASELINE`
- Create: `docs/superpowers/specs/2026-11-09-phone-coder-native-design.md`
- Create: `docs/superpowers/plans/2026-11-09-phone-coder-*.md`

**Interfaces:**
- Produces: the implementation repository at the exact approved upstream commit on branch `codex/phone-coder-native`.
- Consumes: the approved design and plan set from the parent workspace.

- [ ] **Step 1: Clone with submodules and pin the exact baseline**

Run:

```bash
git clone --recurse-submodules https://github.com/Mesutcydev/ios-local-llm.git \
  /home/haider/Documents/ChatGPT/ubuntu/phone-coder-native
git -C /home/haider/Documents/ChatGPT/ubuntu/phone-coder-native checkout \
  -b codex/phone-coder-native cc4e2d3f25dfe77e9ef9e629ee6ddc7e3134ac88
```

- [ ] **Step 2: Verify source and submodule identity before editing**

Run:

```bash
test "$(git -C /home/haider/Documents/ChatGPT/ubuntu/phone-coder-native rev-parse HEAD)" = \
  cc4e2d3f25dfe77e9ef9e629ee6ddc7e3134ac88
git -C /home/haider/Documents/ChatGPT/ubuntu/phone-coder-native submodule status --recursive
```

Expected: exact baseline SHA and no submodule line prefixed with `-`, `+`, or `U`.

- [ ] **Step 3: Copy the approved design/plan records and add baseline metadata**

Copy the approved `docs/superpowers/specs` and `docs/superpowers/plans` directories from the parent workspace. Add `UPSTREAM_BASELINE` containing repository URL, commit SHA, retrieval date, and MIT license reference.

- [ ] **Step 4: Run upstream validation before product changes**

Run `./scripts/validate_open_source.sh` from the native repository.

Expected: PASS at the pinned baseline; record any upstream-only environmental failure before continuing.

- [ ] **Step 5: Commit the planning/provenance layer**

```bash
git add UPSTREAM_BASELINE docs/superpowers
git commit -s -m "docs: pin Phone Coder upstream baseline"
```

### Task 1: Pin the fork and establish Phone Coder identity

**Files:**
- Modify: `project.yml`
- Create: `IOSLocalLLM/PhoneCoder/App/PhoneCoderBuildManifest.swift`
- Create: `IOSLocalLLMTests/PhoneCoderAppIdentityTests.swift`
- Modify: `README.md`
- Modify: `THIRD_PARTY_NOTICES.md`
- Modify: `Podfile`

**Interfaces:**
- Produces: `PhoneCoderBuildManifest.current: PhoneCoderBuildManifest` with `productName`, `bundleIdentifier`, `upstreamRepository`, `upstreamCommit`, `apiProfile`, `policyFlavor`.
- Consumes: no earlier task interfaces.

- [ ] **Step 1: Write failing identity tests**

Add tests named `testBuildManifestPinsApprovedUpstreamCommit`, `testProductIdentityHasNoOnDeviceBundleIdentifier`, and `testSideloadFlavorDeclaresNoContentClassifier`. Assert the exact baseline commit, `com.haider.phonecoder`, API profile `phone-coder-api/1`, and policy flavor `sideload-owner-controlled`.

- [ ] **Step 2: Run the focused test target and confirm RED**

Run on macOS CI or a local Xcode host:

```bash
xcodebuild test -workspace OnDeviceLAS.xcworkspace -scheme OnDeviceLAS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:OnDeviceLASTests/PhoneCoderAppIdentityTests
```

Expected: FAIL because `PhoneCoderBuildManifest` and the Phone Coder target identity do not exist.

- [ ] **Step 3: Add the manifest and rename the target configuration**

Define:

```swift
struct PhoneCoderBuildManifest: Codable, Equatable, Sendable {
    let productName: String
    let bundleIdentifier: String
    let upstreamRepository: URL
    let upstreamCommit: String
    let apiProfile: String
    let policyFlavor: String
    static let current: Self
}
```

Rename target/scheme/test target in `project.yml` to `PhoneCoder`/`PhoneCoderTests`, set `CFBundleDisplayName` to `Phone Coder`, and use unique Phone Coder bundle/Keychain namespaces. Preserve the upstream MIT notice and record adapted files.

- [ ] **Step 4: Regenerate and run identity tests**

Run:

```bash
xcodegen generate
pod install
xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:PhoneCoderTests/PhoneCoderAppIdentityTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add project.yml IOSLocalLLM/PhoneCoder/App/PhoneCoderBuildManifest.swift \
  IOSLocalLLMTests/PhoneCoderAppIdentityTests.swift README.md THIRD_PARTY_NOTICES.md Podfile
git commit -s -m "chore: establish Phone Coder fork identity"
```

### Task 2: Build the native five-tab shell

**Files:**
- Modify: `IOSLocalLLM/IOSLocalLLMApp.swift`
- Create: `IOSLocalLLM/PhoneCoder/App/PhoneCoderRootView.swift`
- Create: `IOSLocalLLM/PhoneCoder/App/PhoneCoderTab.swift`
- Create: `IOSLocalLLMTests/PhoneCoderRootNavigationTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `PhoneCoderBuildManifest.current` from Task 1.
- Produces: `enum PhoneCoderTab: String, CaseIterable, Identifiable` and `PhoneCoderRootView` with Chat, Models, Server, Images, Settings in that order.

- [ ] **Step 1: Write failing navigation tests**

Test that the five stable tab IDs are `chat`, `models`, `server`, `images`, `settings`; `server` has index 2; and each tab has a nonempty accessibility label and SF Symbol.

- [ ] **Step 2: Run and confirm RED**

Run:

```bash
xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:PhoneCoderTests/PhoneCoderRootNavigationTests
```

Expected: FAIL because the types do not exist.

- [ ] **Step 3: Implement the shell and app entry**

Create `PhoneCoderTab` and `PhoneCoderRootView(selection: Binding<PhoneCoderTab> = ...)`. Use native `TabView`; Server is selected on first launch. Placeholder screens show “Available in the next build” and never claim a model/server is ready. Replace the upstream `@main` app entry with `PhoneCoderApp` and retain lifecycle startup hooks needed by memory/pressure services.

- [ ] **Step 4: Verify tests and build source membership**

Run:

```bash
xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:PhoneCoderTests/PhoneCoderRootNavigationTests
xcodebuild build -workspace PhoneCoder.xcworkspace -scheme PhoneCoder \
  -destination 'generic/platform=iOS Simulator'
```

Expected: PASS and exactly one app entry point.

- [ ] **Step 5: Commit**

```bash
git add IOSLocalLLM/IOSLocalLLMApp.swift IOSLocalLLM/PhoneCoder/App \
  IOSLocalLLMTests/PhoneCoderRootNavigationTests.swift project.yml
git commit -s -m "feat: add Phone Coder native shell"
```

### Task 3: Add a llama-only native framework build

**Files:**
- Modify: `scripts/build_native_frameworks.sh`
- Create: `scripts/tests/test_build_native_frameworks.sh`
- Modify: `SETUP_INSTRUCTIONS.md`

**Interfaces:**
- Produces: `./scripts/build_native_frameworks.sh --llama-only` and preserves existing no-argument behavior for upstream compatibility.
- Consumes: pinned llama.cpp submodule and tracked iOS patch.

- [ ] **Step 1: Write the failing shell regression test**

The test runs the script against stubbed builder commands and asserts `--llama-only` invokes llama once, never invokes whisper, rejects unknown flags with exit 64, and leaves generated frameworks untracked.

- [ ] **Step 2: Run and confirm RED**

Run `bash scripts/tests/test_build_native_frameworks.sh`.

Expected: FAIL because `--llama-only` is unsupported.

- [ ] **Step 3: Implement explicit component selection**

Parse `--llama-only`, `--with-catalyst`, and `--help` without positional ambiguity. Skip whisper submodule/build checks entirely in llama-only mode. Print disk usage before and after the native build for CI diagnostics.

- [ ] **Step 4: Run shell tests and syntax checks**

Run:

```bash
bash -n scripts/build_native_frameworks.sh
bash scripts/tests/test_build_native_frameworks.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/build_native_frameworks.sh scripts/tests/test_build_native_frameworks.sh SETUP_INSTRUCTIONS.md
git commit -s -m "build: support llama-only iOS framework"
```

### Task 4: Package and validate an unsigned IPA

**Files:**
- Create: `scripts/package_unsigned_ipa.sh`
- Create: `scripts/verify_unsigned_ipa.sh`
- Create: `scripts/tests/test_package_unsigned_ipa.sh`

**Interfaces:**
- Produces: `package_unsigned_ipa.sh <archive-or-app-path> <output.ipa>` and `verify_unsigned_ipa.sh <ipa>`.
- Consumes: `Phone Coder.app` produced with `CODE_SIGNING_ALLOWED=NO`.

- [ ] **Step 1: Write failing package tests with a fake `.app` bundle**

Assert deterministic `Payload/Phone Coder.app/` layout, presence of executable and Info.plist, absence of `embedded.mobileprovision`, `_CodeSignature`, model files, and credentials, plus stable SHA-256 across identical inputs.

- [ ] **Step 2: Run and confirm RED**

Run `bash scripts/tests/test_package_unsigned_ipa.sh`.

Expected: FAIL because packaging scripts do not exist.

- [ ] **Step 3: Implement packaging and verification**

Use `ditto -c -k --sequesterRsrc --keepParent Payload` on macOS, normalize copied file timestamps before archiving, and fail closed on forbidden contents. Emit `<ipa>.sha256`.

- [ ] **Step 4: Run tests**

Run:

```bash
bash scripts/tests/test_package_unsigned_ipa.sh
bash -n scripts/package_unsigned_ipa.sh scripts/verify_unsigned_ipa.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/package_unsigned_ipa.sh scripts/verify_unsigned_ipa.sh scripts/tests/test_package_unsigned_ipa.sh
git commit -s -m "build: package verified unsigned IPA"
```

### Task 5: Add the macOS CI build and artifact workflow

**Files:**
- Create: `.github/workflows/phone-coder-ios.yml`
- Create: `scripts/validate_phone_coder_workflows.sh`
- Modify: `.github/workflows/validate.yml`

**Interfaces:**
- Produces: workflow artifact `phone-coder-unsigned-<sha>.ipa`, checksum, test result bundle, and build metadata.
- Consumes: Tasks 1–4 commands.

- [ ] **Step 1: Write failing workflow invariant checks**

Assert the workflow pins actions by commit SHA, uses a pinned macOS/Xcode image, checks out submodules, runs repository/unit tests before archive, invokes `--llama-only`, sets `CODE_SIGNING_ALLOWED=NO`, verifies the IPA, uploads checksum and metadata, and has no signing-secret references.

- [ ] **Step 2: Run and confirm RED**

Run `bash scripts/validate_phone_coder_workflows.sh`.

Expected: FAIL because the workflow does not exist.

- [ ] **Step 3: Implement the workflow**

Build in separate dependency/test/archive steps; run `df -h` around native compilation; remove DerivedData and package caches before archive if required; never upload XCFramework caches as release artifacts. Generate `build-metadata.json` with source SHA, Xcode version, dependency lock hashes, policy flavor, and API profile.

- [ ] **Step 4: Validate locally and in GitHub Actions**

Run `bash scripts/validate_phone_coder_workflows.sh`, push a branch, and require a successful `phone-coder-ios` run with artifact verification.

Expected: local check PASS and CI green.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/phone-coder-ios.yml .github/workflows/validate.yml \
  scripts/validate_phone_coder_workflows.sh
git commit -s -m "ci: build unsigned Phone Coder IPA"
```

### Task 6: Document and prove Ubuntu-to-SideStore installation

**Files:**
- Create: `docs/installation/ubuntu-sidestore.md`
- Create: `docs/installation/device-acceptance-a.md`
- Modify: `README.md`

**Interfaces:**
- Produces: repeatable installation/refresh/recovery instructions and a signed-off physical-device record.
- Consumes: verified IPA/checksum from Task 5.

- [ ] **Step 1: Draft the acceptance checklist before installing**

Include Ubuntu 26.04 x86_64, `usbmuxd`, official `iloader`, LocalDevVPN, Apple Account trust, Developer Mode, SideStore refresh, IPA checksum, install, first launch, update-over-existing-build, seven-day refresh, and failure recovery.

- [ ] **Step 2: Verify every copyable command on Ubuntu**

Run commands exactly as written through checksum verification and device discovery. Record tool versions without storing Apple credentials or device secrets.

- [ ] **Step 3: Install on the iPhone 17 Pro Max**

Import the IPA into SideStore, sign/install, launch, exercise all five tabs, background/foreground the shell, and update with a second build while preserving app settings.

- [ ] **Step 4: Record evidence and limitations**

Fill `device-acceptance-a.md` with iOS version/build, Phone Coder source SHA, IPA SHA-256, SideStore/iloader versions, pass/fail for each step, and unresolved issues. Do not claim inference or thermal qualification in Increment A.

- [ ] **Step 5: Commit documentation**

```bash
git add docs/installation README.md
git commit -s -m "docs: verify Ubuntu SideStore installation"
```

## Increment A Completion Check

Run repository validation, focused XCTest suites, shell tests, the GitHub workflow, checksum verification, and the recorded physical install checklist. Increment A is complete only when the unsigned IPA launches on the iPhone 17 Pro Max and can be refreshed from the Ubuntu-supported SideStore flow.
