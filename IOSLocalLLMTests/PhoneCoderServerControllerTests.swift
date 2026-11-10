import Combine
import CryptoKit
import SwiftUI
import XCTest
@testable import PhoneCoder

@MainActor
final class PhoneCoderServerControllerTests: XCTestCase {
    func testNewForegroundSessionInvalidatesOlderResumeWithoutCancellingModelLoad() async throws {
        let runtime = LifecycleTextRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        let ledger = PhoneCoderRequestLedger(sessionID: UUID())
        var nativeInterruptions = 0
        let lifecycle = PhoneCoderInferenceLifecycle(coordinator: coordinator, ledger: ledger,
            signalNativeInterruption: { nativeInterruptions += 1 })
        await runtime.holdLoad()
        let loading = Task { try await coordinator.switchModel(to: "selected-model") }
        await runtime.waitForLoads(1)
        let obsoleteSession = UUID()
        let listenerSession = UUID()
        // Both intents are captured synchronously before either setup task can
        // run, proving that obsolete bookkeeping cannot win a scheduler race.
        let obsoleteResume = lifecycle.resume(sessionID: obsoleteSession)
        let currentResume = lifecycle.resume(sessionID: listenerSession)
        let obsoleteResult = await obsoleteResume.value
        let currentResult = await currentResume.value
        XCTAssertFalse(obsoleteResult)
        XCTAssertTrue(currentResult)
        let fingerprint = SHA256.hash(data: Data("session-test".utf8))
        do {
            _ = try await ledger.begin(id: .init(rawValue: "obsolete"), fingerprint: fingerprint,
                sessionID: obsoleteSession, deadline: .now.advanced(by: .seconds(60)))
            XCTFail("An old resume must not replace the listener's current ledger session")
        } catch { XCTAssertEqual((error as? PhoneCoderAPIError)?.code, "stale_session") }
        let owner = try await ledger.begin(id: .init(rawValue: "current"), fingerprint: fingerprint,
            sessionID: listenerSession, deadline: .now.advanced(by: .seconds(60)))
        XCTAssertEqual(owner, .owner)
        XCTAssertEqual(nativeInterruptions, 0)
        await runtime.releaseLoad()
        let selected = try await loading.value
        XCTAssertEqual(selected.modelID, "selected-model")
        await lifecycle.suspend().value
    }

    func testStartAndRetryPreserveModelLoadAlreadyInProgress() async throws {
        let runtime = LifecycleTextRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        var nativeInterruptions = 0
        let lifecycle = PhoneCoderInferenceLifecycle(coordinator: coordinator, ledger: .init(sessionID: UUID()),
            signalNativeInterruption: { nativeInterruptions += 1 })
        let fixture = Fixture(inference: lifecycle)
        await fixture.controller.handle(scenePhase: .active).value
        await runtime.holdLoad()
        let loading = Task { try await coordinator.switchModel(to: "selected-model") }
        await runtime.waitForLoads(1)

        let startUnavailable = expectation(description: "Start reports loading model unavailable")
        var observation = fixture.controller.$state.sink {
            if $0 == .modelUnavailable { startUnavailable.fulfill() }
        }
        let start = fixture.controller.startServing()
        await fulfillment(of: [startUnavailable], timeout: 2)
        observation.cancel()
        let retryUnavailable = expectation(description: "Retry reports loading model unavailable")
        let retry = fixture.controller.retryNow()
        observation = fixture.controller.$state.sink {
            if $0 == .modelUnavailable { retryUnavailable.fulfill() }
        }
        await fulfillment(of: [retryUnavailable], timeout: 2)
        observation.cancel()

        let duringLoad = await coordinator.state()
        XCTAssertEqual(duringLoad.availability, .unavailable(.switchingModel))
        XCTAssertTrue(fixture.listener.starts.isEmpty)
        XCTAssertEqual(nativeInterruptions, 0, "Starting a listener must not signal native cancelLoad")
        await runtime.releaseLoad()
        let selected = try? await loading.value
        await start.value
        await retry.value
        XCTAssertEqual(selected?.modelID, "selected-model")
        await fixture.controller.retryNow().value
        XCTAssertEqual(fixture.controller.state, .ready)
        await fixture.controller.stopServing().value
    }

    func testModelSwitchDuringListenerStartIsPreservedAndHealthRecovers() async throws {
        let runtime = LifecycleTextRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        _ = try await coordinator.switchModel(to: "initial-model")
        var nativeInterruptions = 0
        let lifecycle = PhoneCoderInferenceLifecycle(coordinator: coordinator, ledger: .init(sessionID: UUID()),
            signalNativeInterruption: { nativeInterruptions += 1 })
        let fixture = Fixture(inference: lifecycle)
        await fixture.controller.handle(scenePhase: .active).value
        fixture.listener.holdStart = true
        let start = fixture.controller.startServing()
        await fixture.listener.waitForStart()
        await runtime.holdLoad()
        let loading = Task { try await coordinator.switchModel(to: "new-model") }
        await runtime.waitForLoads(2)
        let unavailable = expectation(description: "Listener starts with model unavailable")
        let observation = fixture.controller.$state.sink {
            if $0 == .modelUnavailable { unavailable.fulfill() }
        }
        fixture.listener.releaseStart()
        await fulfillment(of: [unavailable], timeout: 2)
        observation.cancel()
        let duringLoad = await coordinator.state()
        XCTAssertEqual(duringLoad.availability, .unavailable(.switchingModel))
        XCTAssertTrue(fixture.listener.admitting, "Health must remain reachable during the load")
        XCTAssertEqual(nativeInterruptions, 0)
        await runtime.releaseLoad()
        let selected = try? await loading.value
        await start.value
        XCTAssertEqual(selected?.modelID, "new-model")
        await fixture.controller.refreshHealth()
        XCTAssertEqual(fixture.controller.state, .ready)
        XCTAssertEqual(fixture.controller.runtimeState?.modelSession?.modelID, "new-model")
        await fixture.controller.stopServing().value
    }

    func testServingIntentSurvivesDefaultsReconstructionAndStopClearsIt() async throws {
        let suite = "PhoneCoderServerControllerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Fixture(intent: PhoneCoderDefaultsServingIntent(defaults: defaults))
        await original.controller.startServing().value
        let restored = Fixture(intent: PhoneCoderDefaultsServingIntent(defaults: defaults))
        XCTAssertTrue(restored.controller.servingRequested)
        XCTAssertTrue(restored.listener.starts.isEmpty)
        await restored.controller.handle(scenePhase: .active).value
        XCTAssertEqual(restored.controller.state, .ready)
        await restored.controller.stopServing().value
        let stopped = Fixture(intent: PhoneCoderDefaultsServingIntent(defaults: defaults))
        await stopped.controller.handle(scenePhase: .active).value
        XCTAssertFalse(stopped.controller.servingRequested)
        XCTAssertTrue(stopped.listener.starts.isEmpty)
    }

    func testStartRequiresForegroundAndPersistsOnlyIntent() async {
        let fixture = Fixture()
        await fixture.controller.startServing().value
        XCTAssertEqual(fixture.controller.state, .pausedBackground)
        XCTAssertTrue(fixture.intent.servingRequested)
        XCTAssertTrue(fixture.listener.starts.isEmpty)
        XCTAssertFalse(fixture.idle.disabled)
        await fixture.controller.handle(scenePhase: .active).value
        XCTAssertEqual(fixture.controller.state, .ready)
        XCTAssertTrue(fixture.idle.disabled)
        XCTAssertEqual(fixture.listener.starts.count, 1)
        let restored = Fixture(intent: fixture.intent)
        XCTAssertTrue(restored.controller.servingRequested)
        XCTAssertEqual(restored.controller.state, .stopped)
        XCTAssertTrue(restored.listener.starts.isEmpty)
        await fixture.controller.stopServing().value
    }

    func testStartingReadyServingGeneratingAndManualStop() async {
        let fixture = Fixture()
        await fixture.controller.handle(scenePhase: .active).value
        fixture.listener.holdStart = true
        let start = fixture.controller.startServing()
        XCTAssertEqual(fixture.controller.state, .starting)
        await fixture.listener.waitForStart()
        XCTAssertTrue(fixture.idle.disabled)
        fixture.listener.releaseStart()
        await start.value
        XCTAssertEqual(fixture.controller.state, .ready)
        let session = fixture.controller.sessionID!
        fixture.controller.updateConnectionCount(1, sessionID: session)
        XCTAssertEqual(fixture.controller.state, .serving)
        fixture.inference.snapshot = Fixture.health(active: .init(rawValue: "request"))
        await fixture.controller.refreshHealth()
        XCTAssertEqual(fixture.controller.state, .generating)
        await fixture.controller.stopServing().value
        XCTAssertEqual(fixture.controller.state, .stopped)
        XCTAssertFalse(fixture.controller.servingRequested)
        XCTAssertFalse(fixture.intent.servingRequested)
        XCTAssertFalse(fixture.idle.disabled)
        XCTAssertFalse(fixture.listener.admitting)
        await fixture.controller.handle(scenePhase: .background).value
        await fixture.controller.handle(scenePhase: .active).value
        XCTAssertEqual(fixture.listener.starts.count, 1)
    }

    func testInactiveClosesAdmissionSynchronouslyAndStaleStartCannotPublishReady() async {
        let fixture = Fixture()
        await fixture.controller.handle(scenePhase: .active).value
        fixture.listener.holdStart = true
        let start = fixture.controller.startServing()
        await fixture.listener.waitForStart()
        let interrupted = fixture.controller.sessionID!
        let pause = fixture.controller.handle(scenePhase: .inactive)
        XCTAssertFalse(fixture.listener.admitting)
        XCTAssertFalse(fixture.idle.disabled)
        XCTAssertEqual(fixture.controller.state, .pausedBackground)
        XCTAssertTrue(fixture.intent.servingRequested)
        fixture.listener.releaseStart()
        await start.value
        await pause.value
        XCTAssertEqual(fixture.controller.state, .pausedBackground)
        fixture.controller.updateConnectionCount(1, sessionID: interrupted)
        XCTAssertEqual(fixture.controller.state, .pausedBackground)
        fixture.listener.holdStart = false
        await fixture.controller.handle(scenePhase: .active).value
        XCTAssertEqual(fixture.controller.state, .ready)
        XCTAssertNotEqual(fixture.controller.sessionID, interrupted)
        await fixture.controller.stopServing().value
    }

    func testSafetyStatesStopServingWithoutClearingIntentAndRetryReadsLiveHealth() async {
        for (refusal, state) in [(PhoneCoderRuntimeError.thermal, PhoneCoderServerState.coolingDown),
                                 (.memoryPressure, .lowMemory)] {
            let fixture = Fixture()
            await fixture.controller.handle(scenePhase: .active).value
            await fixture.controller.startServing().value
            fixture.inference.snapshot = Fixture.health(availability: .unavailable(refusal))
            await fixture.controller.refreshHealth()
            XCTAssertEqual(fixture.controller.state, state)
            XCTAssertTrue(fixture.controller.servingRequested)
            XCTAssertFalse(fixture.listener.admitting)
            XCTAssertFalse(fixture.idle.disabled)
            XCTAssertTrue(fixture.clock.delays.isEmpty)
            fixture.inference.snapshot = Fixture.health()
            await fixture.controller.retryNow().value
            XCTAssertEqual(fixture.controller.state, .ready)
            await fixture.controller.stopServing().value
        }
    }

    func testUnavailableModelIsNeverAdvertisedReady() async {
        let fixture = Fixture()
        fixture.inference.snapshot = .init(availability: .unavailable(.modelUnavailable),
            modelSession: nil, activeRequestID: nil, waitingCount: 0, switchingModel: false)
        await fixture.controller.handle(scenePhase: .active).value
        await fixture.controller.startServing().value
        XCTAssertEqual(fixture.controller.state, .modelUnavailable)
        XCTAssertTrue(fixture.listener.starts.isEmpty)
        XCTAssertFalse(fixture.idle.disabled)
        await fixture.controller.stopServing().value
    }

    func testModelTransitionKeepsHealthEndpointButNeverAdvertisesReady() async {
        let fixture = Fixture()
        await fixture.controller.handle(scenePhase: .active).value
        await fixture.controller.startServing().value
        let session = fixture.controller.sessionID!
        fixture.inference.snapshot = Fixture.health(availability: .unavailable(.switchingModel))
        await fixture.controller.refreshHealth()
        XCTAssertEqual(fixture.controller.state, .modelUnavailable)
        XCTAssertTrue(fixture.listener.admitting)
        fixture.controller.updateConnectionCount(1, sessionID: session)
        XCTAssertEqual(fixture.controller.state, .modelUnavailable)
        fixture.inference.snapshot = Fixture.health()
        await fixture.controller.refreshHealth()
        XCTAssertEqual(fixture.controller.state, .serving)
        XCTAssertEqual(fixture.controller.sessionID, session)
        await fixture.controller.stopServing().value
    }

    func testNetworkRetryIsBoundedAndImmediateRetryCancelsOldTimer() async {
        let fixture = Fixture()
        fixture.listener.failure = .networkUnavailable
        await fixture.controller.handle(scenePhase: .active).value
        await fixture.controller.startServing().value
        await fixture.clock.waitForSleeps(1)
        XCTAssertEqual(fixture.controller.state, .recovering(attempt: 1, retryAt: fixture.clock.now.addingTimeInterval(1)))
        XCTAssertFalse(fixture.idle.disabled)
        let exhausted = expectation(description: "bounded retries exhausted")
        let observation = fixture.controller.$state.sink { if $0 == .networkUnavailable { exhausted.fulfill() } }
        for count in 1...3 {
            fixture.clock.releaseNext()
            if count < 3 { await fixture.clock.waitForSleeps(count + 1) }
        }
        await fulfillment(of: [exhausted], timeout: 2)
        observation.cancel()
        XCTAssertEqual(fixture.controller.state, .networkUnavailable)
        XCTAssertEqual(fixture.clock.delays, [1, 2, 4])
        XCTAssertEqual(fixture.listener.starts.count, 4)
        fixture.listener.failure = nil
        await fixture.controller.retryNow().value
        XCTAssertEqual(fixture.controller.state, .ready)
        let session = fixture.controller.sessionID!
        let recovery = fixture.controller.listenerFailed(.networkUnavailable, sessionID: session)
        await fixture.clock.waitForSleeps(4)
        await fixture.controller.retryNow().value
        let starts = fixture.listener.starts.count
        fixture.clock.releaseNext()
        await recovery.value
        XCTAssertEqual(fixture.listener.starts.count, starts)
        XCTAssertEqual(fixture.controller.state, .ready)
        await fixture.controller.stopServing().value
    }

    func testAuthenticationFailureDoesNotLoopOrResumeOnSceneChange() async {
        let fixture = Fixture()
        fixture.listener.failure = .authentication
        await fixture.controller.handle(scenePhase: .active).value
        await fixture.controller.startServing().value
        XCTAssertEqual(fixture.controller.state, .authenticationError)
        XCTAssertFalse(fixture.controller.servingRequested)
        XCTAssertFalse(fixture.idle.disabled)
        XCTAssertTrue(fixture.clock.delays.isEmpty)
        await fixture.controller.handle(scenePhase: .inactive).value
        await fixture.controller.handle(scenePhase: .active).value
        XCTAssertEqual(fixture.listener.starts.count, 1)
    }

    func testBackgroundAndFinalCompletionHaveOneLedgerOutcomeAndNoRequestResume() async throws {
        for completionWins in [true, false] {
            let runtime = LifecycleTextRuntime()
            let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
            _ = try await coordinator.switchModel(to: "model")
            let ledger = PhoneCoderRequestLedger(sessionID: UUID())
            let lifecycle = PhoneCoderInferenceLifecycle(coordinator: coordinator, ledger: ledger)
            let fixture = Fixture(inference: lifecycle)
            await fixture.controller.handle(scenePhase: .active).value
            await fixture.controller.startServing().value
            let session = fixture.controller.sessionID!
            let requestID = PhoneCoderRequestID(rawValue: "old")
            let fingerprint = SHA256.hash(data: Data("body".utf8))
            _ = try await ledger.begin(id: requestID, fingerprint: fingerprint, sessionID: session,
                                       deadline: .now.advanced(by: .seconds(60)))
            let request = PhoneCoderGenerationRequest(id: requestID, sessionID: session, modelID: "model",
                messages: [ChatMessage(role: .user, content: "hello")])
            let generation = try await coordinator.enqueue(request) { event in
                _ = try? await ledger.append(id: event.requestID, event: .done, sessionID: event.sessionID)
            }
            await runtime.waitForStart()
            if completionWins {
                await runtime.succeed()
                _ = try await generation.value
                try await ledger.finish(id: requestID, terminal: .completed, sessionID: session)
            }
            let pause = fixture.controller.handle(scenePhase: .background)
            XCTAssertEqual(fixture.controller.state, .pausedBackground)
            XCTAssertFalse(fixture.listener.admitting)
            await pause.value
            if !completionWins {
                do { _ = try await generation.value; XCTFail("Background must cancel generation") }
                catch { XCTAssertEqual(error as? PhoneCoderRuntimeError, .cancelled) }
            }
            await runtime.emitLate()
            let terminal = try await ledger.terminal(id: requestID)
            XCTAssertEqual(terminal, completionWins ? .completed : .cancelled(.serverStopped))
            do {
                try await ledger.finish(id: requestID, terminal: .completed, sessionID: session)
                XCTFail("A late final result must not overwrite the terminal result")
            } catch { XCTAssertNotNil(error as? PhoneCoderAPIError) }
            let replay = try await ledger.attach(id: requestID, fingerprint: fingerprint, after: nil)
            var events: [PhoneCoderRequestLedger.SequencedEvent] = []
            for await event in replay { events.append(event) }
            XCTAssertTrue(events.isEmpty, "The late callback must not commit output")
            await fixture.controller.handle(scenePhase: .active).value
            XCTAssertEqual(fixture.controller.state, .ready)
            XCTAssertNotEqual(fixture.controller.sessionID, session)
            let starts = await runtime.startedIDs
            XCTAssertEqual(starts, ["old"], "Foregrounding restores intent, not generation")
            await fixture.controller.stopServing().value
        }
    }

    func testManualStopAndModelUnavailableLeaveForegroundModelAdmissionUsable() async throws {
        let runtime = LifecycleTextRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        let ledger = PhoneCoderRequestLedger(sessionID: UUID())
        let lifecycle = PhoneCoderInferenceLifecycle(coordinator: coordinator, ledger: ledger)
        let fixture = Fixture(inference: lifecycle)
        await fixture.controller.handle(scenePhase: .active).value
        await fixture.controller.startServing().value
        XCTAssertEqual(fixture.controller.state, .modelUnavailable)
        // A failed Start must not trap Models behind a server-only suspension.
        let loaded = try await coordinator.switchModel(to: "model")
        XCTAssertEqual(loaded.modelID, "model")
        await fixture.controller.startServing().value
        XCTAssertEqual(fixture.controller.state, .ready)
        await fixture.controller.stopServing().value
        let request = PhoneCoderGenerationRequest(id: .init(rawValue: "local-chat"), sessionID: UUID(), modelID: "model",
            messages: [ChatMessage(role: .user, content: "hello")])
        let generation = try await coordinator.enqueue(request) { _ in }
        await runtime.waitForStart()
        XCTAssertFalse(fixture.listener.admitting)
        XCTAssertFalse(fixture.controller.servingRequested)
        await runtime.succeed()
        _ = try await generation.value
        await fixture.controller.handle(scenePhase: .inactive).value
        do {
            _ = try await coordinator.enqueue(request) { _ in }
            XCTFail("Inactive must still close local inference admission")
        } catch { XCTAssertEqual(error as? PhoneCoderRuntimeError, .lifecycleUnavailable) }
    }

    func testStartTaskThatHasNotRunCannotReopenAfterBackground() async throws {
        let runtime = LifecycleTextRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        _ = try await coordinator.switchModel(to: "model")
        let lifecycle = PhoneCoderInferenceLifecycle(coordinator: coordinator, ledger: .init(sessionID: UUID()))
        let fixture = Fixture(inference: lifecycle)
        await fixture.controller.handle(scenePhase: .active).value
        // Both intents run on MainActor before the unstructured start task can
        // enter its body. Checking only after resume would reopen in background.
        let start = fixture.controller.startServing()
        let background = fixture.controller.handle(scenePhase: .background)
        await start.value
        await background.value
        let health = await coordinator.state()
        XCTAssertEqual(health.availability, .unavailable(.lifecycleUnavailable))
        XCTAssertEqual(fixture.controller.state, .pausedBackground)
        XCTAssertTrue(fixture.listener.starts.isEmpty)
    }

    @MainActor
    private final class Fixture {
        let intent: any PhoneCoderServingIntentStore
        let listener = ControlledServerListener()
        let inference = ControlledInferenceLifecycle()
        let clock = ControlledServerClock()
        let idle = IdleTimerRecorder()
        let controller: PhoneCoderServerController

        init(intent: (any PhoneCoderServingIntentStore)? = nil, inference: (any PhoneCoderInferenceLifecycleControlling)? = nil) {
            let intent = intent ?? MemoryServingIntent()
            self.intent = intent
            controller = PhoneCoderServerController(listener: listener, inference: inference ?? self.inference,
                intent: intent, clock: clock, setIdleTimerDisabled: { [idle] in idle.disabled = $0 })
        }

        static func health(availability: PhoneCoderRuntimeAvailability = .available,
                           active: PhoneCoderRequestID? = nil) -> PhoneCoderRuntimeState {
            .init(availability: availability, modelSession: .init(id: UUID(), modelID: "model"),
                  activeRequestID: active, waitingCount: 0, switchingModel: false)
        }
    }
}

@MainActor
private final class MemoryServingIntent: PhoneCoderServingIntentStore {
    var servingRequested = false
}

@MainActor
private final class IdleTimerRecorder { var disabled = false }

@MainActor
private final class ControlledServerListener: PhoneCoderServerListening {
    var starts: [UUID] = []
    var admitting = false
    var failure: PhoneCoderListenerError?
    var holdStart = false
    private var release: CheckedContinuation<Void, Never>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var epoch = 0
    func start(sessionID: UUID) async throws {
        let captured = epoch
        starts.append(sessionID)
        let ready = waiters.filter { $0.0 <= starts.count }
        waiters.removeAll { $0.0 <= starts.count }
        if holdStart {
            await withCheckedContinuation { continuation in
                release = continuation
                ready.forEach { $0.1.resume() }
            }
        } else { ready.forEach { $0.1.resume() } }
        if let failure { throw failure }
        guard captured == epoch else { throw CancellationError() }
        admitting = true
    }
    func stop() { epoch += 1; admitting = false }
    func waitForStart() async { await waitForStarts(1) }
    func waitForStarts(_ count: Int) async {
        if starts.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func releaseStart() { release?.resume(); release = nil }
}

@MainActor
private final class ControlledInferenceLifecycle: PhoneCoderInferenceLifecycleControlling {
    var snapshot = PhoneCoderRuntimeState(availability: .available,
        modelSession: .init(id: UUID(), modelID: "model"), activeRequestID: nil, waitingCount: 0, switchingModel: false)
    func state() async -> PhoneCoderRuntimeState { snapshot }
    func suspend() -> Task<Void, Never> { Task {} }
    func resume(sessionID: UUID) -> Task<Bool, Never> { Task { true } }
}

@MainActor
private final class ControlledServerClock: PhoneCoderServerClock {
    let now = Date(timeIntervalSince1970: 1_000)
    var delays: [TimeInterval] = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func sleep(seconds: TimeInterval) async throws {
        delays.append(seconds)
        await withCheckedContinuation { continuation in
            pending.append(continuation)
            let ready = waiters.filter { $0.0 <= delays.count }
            waiters.removeAll { $0.0 <= delays.count }
            ready.forEach { $0.1.resume() }
        }
        try Task.checkCancellation()
    }
    func waitForSleeps(_ count: Int) async {
        if delays.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func releaseNext() { if !pending.isEmpty { pending.removeFirst().resume() } }
}

private actor LifecycleTextRuntime: PhoneCoderTextRuntime {
    var startedIDs: [String] = []
    private var request: PhoneCoderGenerationRequest?
    private var session: PhoneCoderModelSession?
    private var callback: (@Sendable (PhoneCoderRuntimeEvent) async -> Void)?
    private var completion: CheckedContinuation<PhoneCoderGenerationResult, Error>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var heldLoad: CheckedContinuation<Void, Never>?
    private var holdsLoad = false
    private var loadCount = 0
    private var loadWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func installedModels() async -> [PhoneCoderModelDescriptor] { [.init(id: "model", displayName: "Model")] }
    func liveAvailability() async -> PhoneCoderRuntimeAvailability { .available }
    func holdLoad() { holdsLoad = true }
    func releaseLoad() { holdsLoad = false; heldLoad?.resume(); heldLoad = nil }
    func waitForLoads(_ count: Int) async {
        if loadCount >= count { return }
        await withCheckedContinuation { loadWaiters.append((count, $0)) }
    }
    func load(modelID: String) async throws -> PhoneCoderModelSession {
        loadCount += 1
        let ready = loadWaiters.filter { $0.0 <= loadCount }
        loadWaiters.removeAll { $0.0 <= loadCount }
        if holdsLoad {
            await withCheckedContinuation {
                heldLoad = $0
                ready.forEach { $0.1.resume() }
            }
        } else { ready.forEach { $0.1.resume() } }
        return .init(id: UUID(), modelID: modelID)
    }
    func generate(_ request: PhoneCoderGenerationRequest, session: PhoneCoderModelSession,
                  onEvent: @escaping @Sendable (PhoneCoderRuntimeEvent) async -> Void) async throws -> PhoneCoderGenerationResult {
        self.request = request
        self.session = session
        callback = onEvent
        startedIDs.append(request.id.rawValue)
        return try await withCheckedThrowingContinuation {
            completion = $0
            startWaiter?.resume()
            startWaiter = nil
        }
    }
    func waitForStart() async {
        if !startedIDs.isEmpty { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func succeed() {
        guard let request, let session else { return }
        completion?.resume(returning: .init(requestID: request.id, sessionID: request.sessionID,
            modelSessionID: session.id, promptTokens: 1, completionTokens: 1, finishReason: .stop))
        completion = nil
    }
    func emitLate() async {
        guard let request, let session else { return }
        await callback?(.init(requestID: request.id, sessionID: request.sessionID, modelSessionID: session.id, text: "late"))
    }
    func cancel(requestID: PhoneCoderRequestID) async {
        completion?.resume(throwing: PhoneCoderRuntimeError.cancelled)
        completion = nil
    }
    func unload() async {}
}
