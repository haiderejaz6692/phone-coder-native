# Development setup

This guide builds the source-only distribution. Model weights, compiled native
frameworks, CocoaPods, and signing profiles are not stored in Git.

## Prerequisites

- Apple-silicon Mac
- Xcode 26 or newer
- Xcode command-line tools
- Homebrew
- At least 15 GB of free space for native framework builds and package caches

Install the project tools:

```bash
brew install cmake xcodegen cocoapods
```

## Clone

The llama.cpp and whisper.cpp sources are Git submodules:

```bash
git clone --recurse-submodules https://github.com/Mesutcydev/ios-local-llm.git
cd ios-local-llm
```

If the repository was cloned without submodules:

```bash
git submodule update --init --recursive
```

## Build native frameworks

OnDeviceLAS links the locally generated llama.cpp XCFramework. The tracked
root script builds the native slices from pinned submodules:

```bash
./scripts/build_native_frameworks.sh
```

For a llama-only build, initialize and build only the pinned llama.cpp submodule:

```bash
./scripts/build_native_frameworks.sh --llama-only
```

This mode skips whisper.cpp initialization, existing-artifact checks, and builds.
The no-argument command retains the upstream behavior of building both llama.cpp
and whisper.cpp. It initializes all recorded submodules recursively.

Add `--with-catalyst` when you also need the Apple-Silicon Mac Catalyst target.
Flags can appear in either order; for example:

```bash
./scripts/build_native_frameworks.sh --llama-only --with-catalyst
```

Use `--help` for usage without initializing submodules or building. Unknown
arguments exit with status 64. The script reports repository disk usage before
and after a successful native build for CI diagnostics.

The script may apply the tracked iOS-only patch inside the generated
llama.cpp build checkout; do not commit that submodule worktree change.

Expected outputs:

```text
ThirdParty/llama.cpp/build-apple/llama.xcframework
ThirdParty/whisper.cpp/build-apple/whisper.xcframework
```

The llama-only command produces only the first output. These outputs and native
build directories are ignored by Git and must not be committed. Remove an
existing generated XCFramework before rebuilding that component.

## Generate the workspace

`project.yml` is the source of truth for the Xcode project:

```bash
xcodegen generate
pod install
open OnDeviceLAS.xcworkspace
```

Open the workspace, not the `.xcodeproj`, so the generated CocoaPods
integration remains available if the target gains a native pod dependency.

SwiftPM may report a conflicting `mlx-swift` identity because the project pins
the PrismML fork for one-bit model kernels while another package declares the
upstream repository transitively. This is a documented forward-compatibility
risk in [Docs/XCODE_SECURITY_SETTINGS.md](Docs/XCODE_SECURITY_SETTINGS.md), not
a missing package in the current lockfile.

## Run in Simulator

Select the `OnDeviceLAS` scheme and an iOS 18 or newer Simulator. Simulator
builds do not require a paid Apple Developer Program membership.

The source-only build starts without bundled AI weights. Features that depend
on a model become available after the user downloads a compatible model from
the app's model catalog.

## Run on a physical device

Use your own signing identity:

1. Select the OnDeviceLAS project in Xcode.
2. For the app and unit-test targets, select your development team.
3. Replace the app and test bundle identifiers with values owned by your team,
   following [Docs/FORK_CONFIGURATION.md](Docs/FORK_CONFIGURATION.md).
4. Build and run on your device.

If you regenerate the project, make permanent identifier changes in
`project.yml`; XcodeGen overwrites manual project-file changes.

## Optional models

Models are deliberately separate from the repository.

- Use the in-app catalog for normal language, vision, and voice model
  downloads.
- `scripts/download_voice_models.sh` can stage supported voice models for
  development.
- `scripts/export_fastvlm_coreml.sh` documents an experimental FastVLM export
  path.

Read the upstream license before downloading or redistributing any model.
Apple FastVLM model weights are research-only and must not be presented as MIT
licensed or as part of this open-source distribution.

## Regenerating dependencies

After changing `project.yml` or `Podfile`:

```bash
xcodegen generate
pod install
```

Commit `project.yml`, `Podfile`, `Podfile.lock`, the generated shared Xcode
project, and shared package resolution files. Do not commit `Pods`,
`xcuserdata`, model weights, archives, signing material, or generated
frameworks.

## Tests

Run the native-build orchestration regression tests on Linux or macOS:

```bash
bash -n scripts/build_native_frameworks.sh
bash scripts/tests/test_build_native_frameworks.sh
```

These tests use disposable repositories and stubbed native builders; they do
not compile frameworks or require Xcode. Real framework builds require the Mac
prerequisites above.

Run the standalone voice-orb package tests:

```bash
swift test --package-path Packages/VoiceAgentOrb
```

Run app unit tests from Xcode or with a Simulator destination:

```bash
xcodebuild test \
  -workspace OnDeviceLAS.xcworkspace \
  -scheme OnDeviceLAS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The exact Simulator name depends on the runtimes installed on your Mac.

Thermal, Jetsam, Metal-residency, and battery claims require physical-device
validation; see [Docs/VALIDATION.md](Docs/VALIDATION.md).
