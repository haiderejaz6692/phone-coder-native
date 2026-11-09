# Third-party notices

The top-level MIT license covers original iOS Local LLM code and documentation. It
does not replace the licenses of the components below.

## Phone Coder fork provenance

Phone Coder adapts iOS Local LLM from
<https://github.com/Mesutcydev/ios-local-llm.git>, pinned at
`cc4e2d3f25dfe77e9ef9e629ee6ddc7e3134ac88`; see [UPSTREAM_BASELINE](UPSTREAM_BASELINE).
The upstream notice remains unchanged in [LICENSE](LICENSE):

> Copyright (c) 2026 Mesut and iOS Local LLM contributors

The complete MIT permission and warranty notice in that file continues to
apply to the inherited code and documentation. Phone Coder's original
modifications are provided under the same MIT license.

Adapted upstream files in the identity bootstrap:

- `project.yml` — Phone Coder project, product, module, scheme, test target,
  display name, bundle identifiers, and build-flavor condition.
- `Podfile` — renamed project and target integration.
- `IOSLocalLLM/Services/Bridge/LocalAPIServer.swift` — Phone Coder local API
  credential namespace selected by build flavor.
- `IOSLocalLLM/Services/Web/KeychainStore.swift` — Phone Coder web-tool
  credential namespace selected by build flavor.
- `IOSLocalLLM/Services/HFTokenStore.swift` — shared foreground/background
  Hugging Face credential namespace selected by build flavor.
- `IOSLocalLLMTests/LocalAPIServerTests.swift`,
  `IOSLocalLLMTests/DeviceTierAdvisorTests.swift`,
  `IOSLocalLLMTests/LASAppIdentityTests.swift`,
  `IOSLocalLLMTests/Int64FormattedBytesTests.swift`, and
  `IOSLocalLLMTests/URLSafetyValidatorTests.swift` — renamed app-module imports.
- `README.md` and `THIRD_PARTY_NOTICES.md` — fork identity, build instructions,
  and attribution.

New files `IOSLocalLLM/PhoneCoder/App/PhoneCoderBuildManifest.swift` and
`IOSLocalLLMTests/PhoneCoderAppIdentityTests.swift` record and verify this fork's
identity. Runtime inference and policy behavior are unchanged by this step;
the policy flavor is declared metadata, pending the later image-policy audit.
The separately identified Core AI reference target keeps its upstream
credential namespaces.

## Source included in this repository

| Component | Location | License |
| --- | --- | --- |
| FastVLM sample implementation | `IOSLocalLLM/Services/FastVLM.swift` | [Apple Sample Code License](LICENSES/Apple-Sample-Code-License.txt) |
| MLX Stable Diffusion implementation | `IOSLocalLLM/Vendor/StableDiffusion/` | [MIT](IOSLocalLLM/Vendor/StableDiffusion/LICENSE) |
| CMU Pronouncing Dictionary | `IOSLocalLLM/Resources/Voice/cmudict.txt` | [CMUdict license](IOSLocalLLM/Resources/Voice/LICENSE) |
| thinking-orbs adaptations | `Packages/VoiceAgentOrb/` | [MIT](ThirdParty/thinking-orbs/LICENSE) |

The MIT license for iOS Local LLM applies only to the original changes and
integration around these components.

## Git submodules

| Component | Upstream | License |
| --- | --- | --- |
| llama.cpp | <https://github.com/ggml-org/llama.cpp> | MIT |
| whisper.cpp | <https://github.com/ggerganov/whisper.cpp> | MIT |

Each submodule retains its upstream notices and license.

## Direct package dependencies

iOS Local LLM resolves these dependencies through Swift Package Manager or
CocoaPods. Their source and license files are not copied into this repository.

| Dependency | Source | License |
| --- | --- | --- |
| MLX Swift (PrismML fork) | <https://github.com/PrismML-Eng/mlx-swift> | MIT |
| MLX Swift LM | <https://github.com/ml-explore/mlx-swift-lm> | MIT |
| swift-transformers-mlx | <https://github.com/DePasqualeOrg/swift-transformers-mlx> | MIT |
| ONNX Runtime | <https://github.com/microsoft/onnxruntime> | MIT |

Transitive packages are recorded in `Package.resolved` and retain their own
licenses in their source distributions. The source-distribution inventory is
also recorded in [SBOM.spdx.json](SBOM.spdx.json).

## Models and generated artifacts not included

Downloaded language, vision, speech, and image-generation models are separate
works. Their license is shown in the model catalog or at the download source.
Do not assume that a model is open source merely because its loader is.

The following are deliberately excluded from Git:

- Apple FastVLM weights and derived Core ML artifacts (Apple Machine Learning
  Research Model License; research use only)
- SmolVLM GGUF weights
- KittenTTS, Kokoro, and Silero compiled model artifacts
- Generated llama.cpp and whisper.cpp XCFrameworks
- CocoaPods, Ruby bundles, archives, installers, and signing material

Anyone redistributing a build is responsible for reviewing and satisfying the
licenses of every model and binary they add.
