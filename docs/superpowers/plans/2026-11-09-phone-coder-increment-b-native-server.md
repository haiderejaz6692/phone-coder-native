# Phone Coder Increment B Native Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iPhone a reliable, authenticated, foreground-only text-model server with pairing, replay-safe streaming, explicit lifecycle behavior, and native Server/Models/Chat screens.

**Architecture:** Extract the useful codecs and Network.framework patterns from upstream `LocalAPIServer.swift` behind Phone Coder-owned interfaces. A request-ledger actor owns IDs, body fingerprints, event sequence numbers, bounded replay, cancellation, and terminal states; an inference coordinator is the only caller of heavy runtimes. A main-actor server controller separates owner serving intent from listener/model/connectivity state.

**Tech Stack:** Swift concurrency, SwiftUI, Network.framework, CryptoKit, Security/Keychain, MLX Swift, llama.cpp, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-09-phone-coder-native-design.md`

## Global Constraints

- `/v1/chat/completions` implements only the approved text subset; unsupported fields fail explicitly.
- `/v1/responses` implements the versioned `phone-coder-api/1` subset for function tools.
- Every request uses `X-Phone-Coder-Request-ID`; identical POST + `Last-Event-ID` reattaches, never starts duplicate inference.
- Tailscale-carried HTTP plus bearer auth is the only v1 remote path. Advertise tailnet addresses; reject cellular and generic public exposure.
- Backgrounding cancels and terminates current work. Foregrounding may restore serving intent but never resumes the interrupted generation.
- Only one heavy runtime owns the generation lease. Memory, thermal, lifecycle, model-file validation, and residency controls remain in the path.
- API prompts/responses and replay buffers are memory-only. Seven-day activity stores metadata only.

## Review Focus

- Same request ID with different body: Task 2 must return `409 request_conflict` without touching active inference.
- Disconnect after emitted tokens: Task 2 replays committed events; it never rebuilds or retries inference.
- Background race with final token: Task 5 produces one terminal outcome and rejects stale callbacks.
- Pairing/key rotation race: Task 3 invalidates the old credential before publishing the new one.
- Model unload during advertised readiness: Tasks 4 and 6 derive health from the coordinator, not a stale UI flag.

---

## File Structure

- Create `IOSLocalLLM/PhoneCoder/Server/APIContracts.swift` — request/response/error value types and strict decoding.
- Create `IOSLocalLLM/PhoneCoder/Server/APIEncoding.swift` — OpenAI/Responses JSON and SSE encoding.
- Create `IOSLocalLLM/PhoneCoder/Server/RequestLedger.swift` — idempotency, replay, cancellation, terminal states.
- Create `IOSLocalLLM/PhoneCoder/Server/PhoneCoderAPIServer.swift` — Network.framework listener and routing.
- Create `IOSLocalLLM/PhoneCoder/Server/ServerController.swift` — main-actor state/intent/lifecycle owner.
- Create `IOSLocalLLM/PhoneCoder/Server/ServerActivityStore.swift` — redacted seven-day metadata.
- Create `IOSLocalLLM/PhoneCoder/Pairing/PairingStore.swift` — named Keychain-backed client credentials.
- Create `IOSLocalLLM/PhoneCoder/Pairing/PairingExchange.swift` — one-time exchange and approval state.
- Create `IOSLocalLLM/PhoneCoder/Runtime/PhoneCoderTextRuntime.swift` — runtime protocol/value types.
- Create `IOSLocalLLM/PhoneCoder/Runtime/InferenceCoordinator.swift` — lease/session/cancel/unload owner.
- Create `IOSLocalLLM/PhoneCoder/Runtime/OnDeviceTextRuntimeAdapter.swift` — adapter over `CodingAssistantService` and residency/safety policy.
- Create `IOSLocalLLM/PhoneCoder/Views/ServerView.swift`, `ModelsView.swift`, `ChatView.swift`, `PairingSheet.swift`.
- Modify `IOSLocalLLM/PhoneCoder/App/PhoneCoderRootView.swift`, `IOSLocalLLM/IOSLocalLLMApp.swift`, `project.yml`.
- Add focused tests under `IOSLocalLLMTests/PhoneCoder*Tests.swift`.

### Task 1: Extract strict API contracts and encoders

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Server/APIContracts.swift`
- Create: `IOSLocalLLM/PhoneCoder/Server/APIEncoding.swift`
- Create: `IOSLocalLLMTests/PhoneCoderAPIContractTests.swift`
- Reference: `IOSLocalLLM/Services/Bridge/LocalAPIServer.swift`

**Interfaces:**
- Produces: `PhoneCoderRequestID`, `PhoneCoderChatRequest.decode(_:)`, `PhoneCoderResponsesRequest.decode(_:)`, `PhoneCoderAPIError`, `PhoneCoderStreamEvent`, `PhoneCoderAPIEncoder`.
- Consumes: `ChatMessage`, `LocalAPIToolDefinition`, and reasoning/tool parser behavior adapted from upstream.

- [ ] **Step 1: Write failing contract tests**

Cover valid text messages, max-token precedence, temperature/top-p/stop bounds, tool definitions/tool choice, `stream_options.include_usage`, unknown-field rejection, remote image rejection, malformed JSON, body-size limit, stable error codes, and UTF-8 SSE encoding. Add review-focus cases for empty messages, non-user final messages, duplicate tool names, and split Unicode.

- [ ] **Step 2: Run and confirm RED**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderAPIContractTests`.

Expected: FAIL because Phone Coder contracts do not exist.

- [ ] **Step 3: Implement value types and strict decoding**

Define:

```swift
struct PhoneCoderRequestID: RawRepresentable, Hashable, Codable, Sendable
struct PhoneCoderChatRequest: Equatable, Sendable {
    static func decode(_ data: Data) throws -> Self
}
struct PhoneCoderResponsesRequest: Equatable, Sendable {
    static func decode(_ data: Data) throws -> Self
}
enum PhoneCoderStreamEvent: Equatable, Sendable
enum PhoneCoderAPIEncoder {
    static func sse(id: Int, event: PhoneCoderStreamEvent) throws -> Data
}
```

Adapt the smallest coherent upstream codecs; do not import HTTP listener or singleton state.

- [ ] **Step 4: Run focused and upstream compatibility tests**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderAPIContractTests -only-testing:PhoneCoderTests/LocalAPIServerTests`.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add IOSLocalLLM/PhoneCoder/Server/APIContracts.swift \
  IOSLocalLLM/PhoneCoder/Server/APIEncoding.swift \
  IOSLocalLLMTests/PhoneCoderAPIContractTests.swift
git commit -s -m "feat: add strict Phone Coder API contracts"
```

### Task 2: Implement the replay-safe request ledger

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Server/RequestLedger.swift`
- Create: `IOSLocalLLMTests/PhoneCoderRequestLedgerTests.swift`

**Interfaces:**
- Consumes: `PhoneCoderRequestID`, `PhoneCoderStreamEvent` from Task 1.
- Produces: `actor PhoneCoderRequestLedger` with `begin`, `append`, `finish`, `attach`, `cancel`, `expire`, and `cancelAll`.

- [ ] **Step 1: Write failing ledger tests**

Test first begin, same-ID/same-fingerprint attach, same-ID/different-body conflict, strictly increasing event IDs, replay after an event ID, completed-response replay, `410 replay_expired`, idempotent cancellation, deadline expiry, output limit, bounded record count, and stale session rejection. Prove two simultaneous same-ID begins return one execution owner.

- [ ] **Step 2: Run and confirm RED**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderRequestLedgerTests`; expect missing type failures.

- [ ] **Step 3: Implement the actor**

Define:

```swift
actor PhoneCoderRequestLedger {
    func begin(id: PhoneCoderRequestID, fingerprint: SHA256.Digest,
               sessionID: UUID, deadline: ContinuousClock.Instant) throws -> BeginResult
    func append(id: PhoneCoderRequestID, event: PhoneCoderStreamEvent) throws -> SequencedEvent
    func finish(id: PhoneCoderRequestID, terminal: PhoneCoderTerminalResult) throws
    func attach(id: PhoneCoderRequestID, fingerprint: SHA256.Digest,
                after eventID: Int?) throws -> AsyncStream<SequencedEvent>
    func cancel(id: PhoneCoderRequestID, reason: PhoneCoderCancellationReason) -> Bool
    func cancelAll(reason: PhoneCoderCancellationReason)
}
```

Use a bounded in-memory ring per request and a global completed-record cap. Never persist event payloads.

- [ ] **Step 4: Run tests including concurrency stress**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -enableThreadSanitizer YES -only-testing:PhoneCoderTests/PhoneCoderRequestLedgerTests`.

Expected: PASS, no races.

- [ ] **Step 5: Commit**

```bash
git add IOSLocalLLM/PhoneCoder/Server/RequestLedger.swift \
  IOSLocalLLMTests/PhoneCoderRequestLedgerTests.swift
git commit -s -m "feat: add replay-safe request ledger"
```

### Task 3: Add named pairings and one-time exchange

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Pairing/PairingStore.swift`
- Create: `IOSLocalLLM/PhoneCoder/Pairing/PairingExchange.swift`
- Create: `IOSLocalLLMTests/PhoneCoderPairingTests.swift`
- Modify: `IOSLocalLLM/Services/Web/KeychainStore.swift`

**Interfaces:**
- Produces: `PhoneCoderPairingStore`, `PhoneCoderPairingExchange`, `PhoneCoderClientCredential`, `PhoneCoderAuthContext`.
- Consumes: Keychain adapter only; no UI state.

- [ ] **Step 1: Write failing security tests**

Test cryptographic key length, named clients, one-time token expiry/use-once behavior, on-phone approval requirement, constant-time bearer comparison, revoke-one/revoke-all, rotation invalidating old key before new publication, Keychain persistence, and QR payload excluding the long-lived key.

- [ ] **Step 2: Run and confirm RED**

Run `PhoneCoderPairingTests`; expect missing types.

- [ ] **Step 3: Implement stores and exchange state machine**

Expose:

```swift
actor PhoneCoderPairingStore {
    func create(name: String) throws -> PhoneCoderClientCredential
    func authenticate(bearer: String) -> PhoneCoderAuthContext?
    func revoke(id: UUID) throws
    func rotate(id: UUID) throws -> PhoneCoderClientCredential
}
```

One-time exchange tokens live in memory for five minutes and require an approval closure invoked on the main actor.

- [ ] **Step 4: Run tests and Keychain wipe regression**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderPairingTests -only-testing:PhoneCoderTests/WipeKeychainTests`.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add IOSLocalLLM/PhoneCoder/Pairing IOSLocalLLMTests/PhoneCoderPairingTests.swift \
  IOSLocalLLM/Services/Web/KeychainStore.swift
git commit -s -m "feat: add secure Phone Coder pairing"
```

### Task 4: Put text inference behind one coordinator

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Runtime/PhoneCoderTextRuntime.swift`
- Create: `IOSLocalLLM/PhoneCoder/Runtime/InferenceCoordinator.swift`
- Create: `IOSLocalLLM/PhoneCoder/Runtime/OnDeviceTextRuntimeAdapter.swift`
- Create: `IOSLocalLLMTests/PhoneCoderInferenceCoordinatorTests.swift`
- Modify: `IOSLocalLLM/Services/CodingAssistantService.swift`
- Modify: `IOSLocalLLM/Services/ModelResidency.swift`

**Interfaces:**
- Consumes: decoded generation requests and request IDs.
- Produces: `PhoneCoderTextRuntime`, `PhoneCoderInferenceCoordinator`, `PhoneCoderRuntimeState`, session IDs, model descriptors.

- [ ] **Step 1: Write failing coordinator tests with a fake runtime**

Test one active lease, FIFO queue limit four, cancel queued/active, model switch draining old work, stale callback rejection by session ID, memory/thermal refusal propagation, runtime reconstruction once before output, no retry after committed output, and health becoming unavailable while image/heavy runtime owns residency.

- [ ] **Step 2: Run and confirm RED**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderInferenceCoordinatorTests`; expect missing types.

- [ ] **Step 3: Define the runtime protocol and coordinator**

```swift
protocol PhoneCoderTextRuntime: Sendable {
    func installedModels() async -> [PhoneCoderModelDescriptor]
    func load(modelID: String) async throws -> PhoneCoderModelSession
    func generate(_ request: PhoneCoderGenerationRequest,
                  session: PhoneCoderModelSession,
                  onEvent: @Sendable (PhoneCoderRuntimeEvent) async -> Void) async throws -> PhoneCoderGenerationResult
    func cancel(requestID: PhoneCoderRequestID) async
    func unload() async
}
```

Adapt `CodingAssistantService` through `OnDeviceTextRuntimeAdapter`; keep all load/generation/unload paths inside upstream admission, `MLXGenerationGate`, `ModelResidency`, `MemoryAdvisor`, and `DeviceSafetyMonitor`.

- [ ] **Step 4: Run coordinator and upstream safety tests**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderInferenceCoordinatorTests -only-testing:PhoneCoderTests/DeviceTierAdvisorTests -only-testing:PhoneCoderTests/HighRiskServiceTests`.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add IOSLocalLLM/PhoneCoder/Runtime IOSLocalLLMTests/PhoneCoderInferenceCoordinatorTests.swift \
  IOSLocalLLM/Services/CodingAssistantService.swift IOSLocalLLM/Services/ModelResidency.swift
git commit -s -m "feat: coordinate Phone Coder inference"
```

### Task 5: Implement foreground-only serving lifecycle

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Server/ServerController.swift`
- Create: `IOSLocalLLMTests/PhoneCoderServerControllerTests.swift`
- Modify: `IOSLocalLLM/IOSLocalLLMApp.swift`
- Modify: `IOSLocalLLM/Services/LifecycleController.swift`

**Interfaces:**
- Consumes: request ledger and inference coordinator.
- Produces: `PhoneCoderServerController`, `PhoneCoderServerState`, persisted `servingRequested` intent.

- [ ] **Step 1: Write failing state-machine tests**

Exercise Stopped → Starting → Ready → Serving/Generating/Recovering; manual Stop clearing intent; inactive/background cancelling ledger and coordinator; foreground restoring only intent; critical thermal/low-memory states; listener failure backoff; authentication failure no-loop; and the final-token/background race producing one terminal result.

- [ ] **Step 2: Run and confirm RED**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderServerControllerTests`; expect missing state types.

- [ ] **Step 3: Implement state and lifecycle ownership**

Define `@MainActor final class PhoneCoderServerController: ObservableObject` with `startServing()`, `stopServing()`, `handle(scenePhase:)`, `retryNow()`, and read-only published state. Use an injected clock/listener/inference facade for deterministic tests. Disable the idle timer only while foreground serving intent is active.

- [ ] **Step 4: Run tests with lifecycle integration**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderServerControllerTests` and assert the background test records no resumed request ID.

- [ ] **Step 5: Commit**

```bash
git add IOSLocalLLM/PhoneCoder/Server/ServerController.swift \
  IOSLocalLLMTests/PhoneCoderServerControllerTests.swift \
  IOSLocalLLM/IOSLocalLLMApp.swift IOSLocalLLM/Services/LifecycleController.swift
git commit -s -m "feat: enforce foreground-only serving"
```

### Task 6: Build the authenticated Network.framework API server

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Server/PhoneCoderAPIServer.swift`
- Create: `IOSLocalLLM/PhoneCoder/Server/ServerActivityStore.swift`
- Create: `IOSLocalLLMTests/PhoneCoderAPIServerTests.swift`
- Reference/modify: `IOSLocalLLM/Services/Bridge/LocalAPIServer.swift`

**Interfaces:**
- Consumes: Tasks 1–5 contracts, auth, ledger, coordinator, controller.
- Produces: `actor PhoneCoderAPIServer` with `start(port:)`, `stop()`, and route handling for health/models/chat/responses/cancel/pair exchange.

- [ ] **Step 1: Write failing real-socket integration tests**

Use loopback `NWConnection` clients to test auth, models, strict validation, streaming, usage, cancellation, same-ID reattach, different-body conflict, completed replay, disconnect cancellation, queue full, model unavailable, health state, pairing exchange, key rotation, body/header/time limits, and redacted activity. Assert advertised interfaces include Tailscale ranges and exclude cellular/public addresses.

- [ ] **Step 2: Run and confirm RED**

Run `PhoneCoderAPIServerTests`; expect missing server.

- [ ] **Step 3: Implement transport and routes**

Adapt upstream request parsing, connection monitoring, and SSE writes into the Phone Coder server. Keep HTTP parsing bounded; authenticate before decoding large bodies; set `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, and close idle connections. Activity receives only client ID, model ID, timestamps, token counts, duration, and terminal category.

- [ ] **Step 4: Run server plus legacy API tests**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderAPIServerTests -only-testing:PhoneCoderTests/LocalAPIServerTests`.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add IOSLocalLLM/PhoneCoder/Server/PhoneCoderAPIServer.swift \
  IOSLocalLLM/PhoneCoder/Server/ServerActivityStore.swift \
  IOSLocalLLMTests/PhoneCoderAPIServerTests.swift \
  IOSLocalLLM/Services/Bridge/LocalAPIServer.swift
git commit -s -m "feat: serve authenticated Phone Coder API"
```

### Task 7: Connect Models, Chat, Server, and pairing UI

**Files:**
- Create: `IOSLocalLLM/PhoneCoder/Views/ServerView.swift`
- Create: `IOSLocalLLM/PhoneCoder/Views/ModelsView.swift`
- Create: `IOSLocalLLM/PhoneCoder/Views/ChatView.swift`
- Create: `IOSLocalLLM/PhoneCoder/Views/PairingSheet.swift`
- Modify: `IOSLocalLLM/PhoneCoder/App/PhoneCoderRootView.swift`
- Create: `IOSLocalLLMTests/PhoneCoderViewModelTests.swift`

**Interfaces:**
- Consumes: server controller, pairings, coordinator/model descriptors, conversation store.
- Produces: user-visible native flows from the approved wireframes.

- [ ] **Step 1: Write failing view-model/state tests**

Assert every server state maps to one primary action and layer-specific explanation; unavailable models cannot show Ready; pairing approval/revoke/rotate states are explicit; Chat history-off mode does not persist; and Dynamic Type labels remain nonempty. Test long model/client names and RTL ordering at the view-model level.

- [ ] **Step 2: Run and confirm RED**

Run `PhoneCoderViewModelTests`; expect missing view models/views.

- [ ] **Step 3: Implement the four screens**

Use native SwiftUI controls, semantic colors, 44-point minimum targets, VoiceOver labels/values, Reduce Motion alternatives, and no model-output execution in Chat. Server is the default center tab and shows model, Tailscale address, client, queue, last request, current activity, pairing, key rotation, and diagnostics entry.

- [ ] **Step 4: Run unit/UI snapshot and accessibility checks**

Run `xcodebuild test -workspace PhoneCoder.xcworkspace -scheme PhoneCoder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PhoneCoderTests/PhoneCoderViewModelTests`, then run the UI fixture launch matrix documented in the test file for portrait/landscape/light/dark/RTL. Simulator screenshots do not substitute for runtime qualification.

- [ ] **Step 5: Commit**

```bash
git add IOSLocalLLM/PhoneCoder/Views IOSLocalLLM/PhoneCoder/App/PhoneCoderRootView.swift \
  IOSLocalLLMTests/PhoneCoderViewModelTests.swift
git commit -s -m "feat: add native Phone Coder server experience"
```

### Task 8: Qualify the native server on the iPhone 17 Pro Max

**Files:**
- Create: `docs/qualification/native-server-iphone17promax.md`
- Create: `scripts/qualification/native_server_probe.py`
- Create: `scripts/qualification/tests/test_native_server_probe.py`

**Interfaces:**
- Consumes: IPA from Increment A and API from Tasks 1–7.
- Produces: repeatable probe and signed qualification evidence.

- [ ] **Step 1: Write probe tests against a fake server**

Test twenty sequential prompts, one cancellation, one disconnect/reattach, background interruption, foreground new request, unauthorized request, key rotation, queue pressure, and Unicode streaming without duplication.

- [ ] **Step 2: Run and confirm RED**

Run `python3 -m unittest scripts/qualification/tests/test_native_server_probe.py -v`; expect missing probe module.

- [ ] **Step 3: Implement the probe**

Accept base URL/key through arguments or protected environment variables; never log prompts or keys; emit JSON summary with counts, durations, status/error categories, model/session IDs redacted, and duplicate/missing sequence detection.

- [ ] **Step 4: Run on the physical phone over Tailscale**

Load one small compatibility model, then the target 3B–8B coding model. Execute the full probe while the app remains foregrounded, background once as directed, return, and rerun. Record iOS build, model/revision/quantization, app SHA, available memory, thermal transitions, and failures.

- [ ] **Step 5: Commit probe and report**

```bash
git add scripts/qualification docs/qualification/native-server-iphone17promax.md
git commit -s -m "test: qualify native iPhone model server"
```

## Increment B Completion Check

Run all Phone Coder Swift tests, relevant upstream API/safety/lifecycle tests, repository validation, the IPA workflow, and the physical native-server probe. Increment B is complete only when the phone serves repeated model responses without Safari in the inference path and every interruption has one explicit terminal result.
