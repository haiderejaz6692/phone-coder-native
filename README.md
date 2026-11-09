# Phone Coder

Phone Coder is an independent, owner-controlled iPhone fork of
[iOS Local LLM](https://github.com/Mesutcydev/ios-local-llm), pinned to upstream
commit `cc4e2d3f25dfe77e9ef9e629ee6ddc7e3134ac88`. See
[UPSTREAM_BASELINE](UPSTREAM_BASELINE) for the source pin and
[third-party notices](THIRD_PARTY_NOTICES.md) for attribution and adapted files.

This bootstrap establishes the `PhoneCoder` app and scheme, `PhoneCoderTests`,
display/product name **Phone Coder**, and bundle ID `com.haider.phonecoder`.
The inherited runtime behavior is preserved here; the Phone Coder navigation
shell and new server features are implemented in later tasks. The existing
Core AI reference target remains separately identified.

`PhoneCoderBuildManifest.current` records API profile `phone-coder-api/1` and
policy flavor `sideload-owner-controlled`. These are build declarations;
the no-content-classifier runtime audit belongs to the later image-policy
increment. This bootstrap does not claim that audit is complete.

Phone Coder uses separate Keychain services under `com.haider.phonecoder`
for local API, web-tool, and Hugging Face credentials. Credentials from
upstream builds are not migrated into this fork.

Original upstream code and documentation retain their [MIT license](LICENSE).
Phone Coder is independent of the upstream OnDevice product line.

## Upstream reference

The material below describes inherited upstream capabilities and assets,
including optional features outside Phone Coder's first release. Upstream
OnDevice products and distribution links are reference material, not Phone
Coder releases. Older setup guides use the upstream `OnDeviceLAS` identity;
use `PhoneCoder` for this fork's workspace, target, and scheme.

## App screenshots

| Home | Assistant |
| --- | --- |
| <img src="Docs/Images/Screenshots/home.png" width="320" alt="OnDevice LLM home dashboard"> | <img src="Docs/Images/Screenshots/assistant.png" width="320" alt="On-device assistant chat screen"> |
| Models | Local vision onboarding |
| <img src="Docs/Images/Screenshots/models.png" width="320" alt="Model discovery and management screen"> | <img src="Docs/Images/Screenshots/local-vision.png" width="320" alt="Local vision onboarding screen"> |

These are inherited iPhone Simulator captures from the upstream source build.
They contain no user content, accounts, tokens, or model weights. Simulator UI
validation does not substitute for physical-device thermal, memory, or
performance evidence; see [validation policy](Docs/VALIDATION.md).

## Highlights

- On-device chat and code assistance with MLX models
- Live camera and image analysis
- Local voice activity detection, transcription, and speech synthesis
- Local OpenAI-compatible API server and Mac bridge
- Model discovery and downloads from Hugging Face
- iPhone and Apple-silicon Mac Catalyst targets

## AI and agent integration

External development tools and agents can use the opt-in local server through:

- OpenAI-style models, chat completions, Responses, streaming, and supported
  tool calls
- Anthropic Messages compatibility
- Ollama-compatible model, chat, and generation routes
- A versioned, pairing-authenticated iPhone-to-Mac tool protocol with explicit
  risk levels

The local API is bearer-authenticated HTTP intended for a trusted LAN and
stops when iOS backgrounds the app. Compatibility is intentionally scoped;
unsupported options fail explicitly. See
[AI and agent integration](Docs/AGENT_INTEGRATION.md) for routes, examples,
security boundaries, and integration guidance.

## For coding agents

This repository includes an agent-readable discovery layer:

- [AGENTS.md](AGENTS.md) — architecture, commands, constraints, and editing
  rules
- [llms.txt](llms.txt) — concise documentation and capability index
- [codemeta.json](codemeta.json) — structured software metadata
- [SBOM.spdx.json](SBOM.spdx.json) — SPDX source dependency inventory
- [.github/copilot-instructions.md](.github/copilot-instructions.md) —
  repository instructions for GitHub Copilot
- [Coding-agent implementation handoff](Docs/CODING_AGENT_IMPLEMENTATION.md) —
  a copy-paste brief for implementing selected components in another app

Agents should treat `project.yml` as the Xcode project source of truth and must
not add model weights, credentials, signing files, or generated native
frameworks to Git.

## Use parts in your own iOS local-LLM app

You do not need to adopt the whole application. The repository now includes:

- [Architecture](ARCHITECTURE.md) — system layers, runtime lifecycle,
  subsystem ownership, and safety invariants
- [Reusable component catalog](Docs/REUSABLE_COMPONENTS.md) — exact source
  files, dependencies, tests, portability level, and extraction guidance
- [Coding-agent implementation handoff](Docs/CODING_AGENT_IMPLEMENTATION.md) —
  a ready-to-share prompt, workflow, and definition of done
- [LocalAIRuntimeFoundation notes](IOSLocalLLM/LocalAIRuntimeFoundation/README.md)
  — the closest existing boundary to a future standalone Swift package

Components are labeled **Extractable**, **Adaptable**, or **Integrated** so
developers and coding agents can distinguish small portable utilities from
services that require app-specific adapters or native inference frameworks.

## Project status

OnDevice LLM is usable but is a large, evolving application. Some
features require recent Apple hardware, optional model downloads, or native
frameworks that must be built locally. Contributions that improve first-run
setup, tests, accessibility, and documentation are especially welcome.

## Requirements

- macOS with Apple silicon
- Xcode 26 or newer
- iOS 18 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [CocoaPods](https://cocoapods.org/)
- CMake

An Apple Developer Program membership is not required for Simulator builds.
Running on a physical device uses your own signing identity and bundle
identifier.

## Build

Clone the Phone Coder fork with its native dependencies. In an existing
checkout, initialize the recorded submodules:

```bash
git submodule update --init --recursive
```

Install project tools if needed:

```bash
brew install xcodegen cocoapods cmake
```

Build the native inference frameworks:

```bash
./scripts/build_native_frameworks.sh
```

For the optional Apple-Silicon Mac Catalyst target, add
`--with-catalyst`. The tracked root scripts build only the required slices
from the pinned submodules; no untracked submodule edits are required.

Generate the Xcode project and install CocoaPods:

```bash
xcodegen generate
pod install
open PhoneCoder.xcworkspace
```

Select the `PhoneCoder` scheme and an iOS Simulator. For a physical device,
change the bundle identifiers and select your own development team in Xcode.
See [SETUP_INSTRUCTIONS.md](SETUP_INSTRUCTIONS.md) and
[fork configuration](Docs/FORK_CONFIGURATION.md) for every identifier,
capability, and optional model step.

Run the focused identity tests on a macOS host after generating the project,
installing pods, and building native dependencies:

```bash
xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:PhoneCoderTests/PhoneCoderAppIdentityTests
```

Run the full app suite by omitting `-only-testing`. Repository hygiene checks
use `./scripts/validate_open_source.sh`. XcodeGen, CocoaPods, and iOS Simulator
tests require macOS; Linux structural checks do not establish iOS build success.

## Releases

Upstream official releases are source-only. Starting with `v3.2.6`, each release
includes a reproducible source archive, SHA-256 checksum, and GitHub/Sigstore
provenance attestation. See
[release verification](Docs/RELEASE_VERIFICATION.md) for the exact download
and verification commands.

Install the Studio app from the App Store or see the
[LAS download and setup guide](https://ondevice.fun/iphone-local-api/) for the
separate server IPA. The [retired AltStore source](altstore/README.md) remains
empty for existing subscribers.

## Models and large files

No AI model weights, compiled Core ML models, generated XCFrameworks, or app
installers are distributed in this repository. They are intentionally ignored
because they are large and often have terms different from the OnDevice Local
AI Studio license.

OnDevice LLM downloads supported models only after a user chooses them. Always
review a model's license before downloading or redistributing it. In
particular, Apple FastVLM weights use a research-only license and are not part
of this open-source distribution.

## Privacy

Inference and user data are local by default. Network access is used for
explicit actions such as searching for or downloading models, optional web
search, and communication with a paired local bridge. Review
[PRIVACY_POLICY.md](PRIVACY_POLICY.md) and the app's privacy manifest before
shipping a modified build.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a change. Please use
GitHub Issues for reproducible bugs and focused feature proposals. Security
reports should follow [SECURITY.md](SECURITY.md).

## License

Original project code and documentation are available under the
[MIT License](LICENSE). Third-party code, data, models, and dependencies remain
under their respective terms; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Names and compatibility
references are explained in [TRADEMARKS.md](TRADEMARKS.md).

Project decisions and contribution roles are documented in
[GOVERNANCE.md](GOVERNANCE.md), [ROADMAP.md](ROADMAP.md), and
[MAINTAINERS.md](MAINTAINERS.md).
