import XCTest
import Combine
@testable import PhoneCoder

@MainActor
final class PhoneCoderViewModelTests: XCTestCase {
    func testEveryServerStateHasAccessibleStatusAndRecovery() {
        let states: [PhoneCoderServerState] = [.stopped, .starting, .ready, .serving, .generating,
            .recovering(attempt: 2, retryAt: .now), .pausedBackground, .coolingDown, .lowMemory,
            .authenticationError, .networkUnavailable, .modelUnavailable]
        for state in states {
            let presentation = PhoneCoderServerPresentation(state)
            XCTAssertFalse(presentation.title.isEmpty)
            XCTAssertFalse(presentation.detail.isEmpty)
            XCTAssertFalse(presentation.icon.isEmpty)
            XCTAssertFalse(presentation.action.title.isEmpty)
        }
        XCTAssertEqual(PhoneCoderServerPresentation(.stopped).action, .start)
        XCTAssertEqual(PhoneCoderServerPresentation(.serving).action, .stop)
        XCTAssertEqual(PhoneCoderServerPresentation(.networkUnavailable).action, .retry)
        XCTAssertNotEqual(PhoneCoderServerPresentation(.modelUnavailable).title, "Ready")
    }

    func testPortValidationDoesNotTruncateOrAcceptRemoteEndpoints() {
        for invalid in ["", "0", "1023", "65536", "99999999", "http://host:1234", "1.5", "-1234"] {
            XCTAssertNil(PhoneCoderSettingsModel.validPort(invalid))
        }
        XCTAssertEqual(PhoneCoderSettingsModel.validPort(" 11434 "), 11434)
        XCTAssertEqual(PhoneCoderSettingsModel.validPort("65535"), 65535)
    }

    func testDownloadActionsPreserveResumeAndInstalledState() {
        XCTAssertEqual(PhoneCoderModelAction.action(for: .idle), .download)
        XCTAssertEqual(PhoneCoderModelAction.action(for: .downloading), .pause)
        XCTAssertEqual(PhoneCoderModelAction.action(for: .enumerating), .pause)
        XCTAssertEqual(PhoneCoderModelAction.action(for: .paused), .resume)
        XCTAssertEqual(PhoneCoderModelAction.action(for: .ready), .installed)
        XCTAssertEqual(PhoneCoderModelAction.action(for: .failed("Offline")), .retry)
    }

    func testImageParametersRejectInvalidNumbersButDoNotClassifyPrompt() throws {
        XCTAssertThrowsError(try PhoneCoderImageParameters(prompt: " ", steps: "4", seed: ""))
        XCTAssertThrowsError(try PhoneCoderImageParameters(prompt: "landscape", steps: "0", seed: ""))
        XCTAssertThrowsError(try PhoneCoderImageParameters(prompt: "landscape", steps: "4", seed: "-1"))
        let parameters = try PhoneCoderImageParameters(prompt: "arbitrary user text", steps: "4", seed: "42")
        XCTAssertEqual(parameters.seed, 42)
        XCTAssertEqual(parameters.steps, 4)
        XCTAssertTrue(PhoneCoderImagePresentation(.generating(0.5), hasImage: false).canCancel)
        XCTAssertFalse(PhoneCoderImagePresentation(.loading, hasImage: false).canShare)
        XCTAssertTrue(PhoneCoderImagePresentation(.ready, hasImage: true).canShare)
    }

    func testChatStreamsLiteralToolTextAndHistoryOffNeverWrites() async throws {
        let runtime = ViewModelRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        _ = try await coordinator.switchModel(to: "model")
        let history = ViewModelHistory()
        let model = PhoneCoderChatModel(coordinator: coordinator, history: history)
        model.historyEnabled = false
        model.draft = "Write a function"
        await model.send().value
        XCTAssertEqual(model.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(model.messages.last?.content, "<tool_call>literal text</tool_call>")
        XCTAssertEqual(model.usage, "12 input · 8 output tokens")
        XCTAssertTrue(history.saved.isEmpty)
        XCTAssertFalse(model.isGenerating)
    }

    func testRetryHasNewIdentityAndReplacesFailedAssistantTurn() async throws {
        let runtime = ViewModelRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        _ = try await coordinator.switchModel(to: "model")
        let history = ViewModelHistory()
        let model = PhoneCoderChatModel(coordinator: coordinator, history: history)
        model.draft = "مرحبا"
        await model.send().value
        await model.retry().value
        let ids = await runtime.requestIDs
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages.first?.content, "مرحبا")
        XCTAssertEqual(history.saved.last?.count, 2)
        model.receive(.init(requestID: .init(rawValue: "stale"), sessionID: UUID(), modelSessionID: UUID(), text: "wrong"))
        XCTAssertFalse(model.messages.contains { $0.content.contains("wrong") })
    }

    func testDisablingHistoryPreventsLaterBackfillOfPrivateConversation() async throws {
        let runtime = ViewModelRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        _ = try await coordinator.switchModel(to: "model")
        let history = ViewModelHistory()
        let model = PhoneCoderChatModel(coordinator: coordinator, history: history)
        model.historyEnabled = false
        model.draft = "Private"
        await model.send().value
        model.historyEnabled = true
        model.draft = "Still private"
        await model.send().value
        XCTAssertTrue(history.saved.isEmpty)
        model.newConversation()
        model.draft = "New saved chat"
        await model.send().value
        XCTAssertEqual(history.saved.count, 1)
    }

    func testStopInvalidatesStreamAndUnloadDrainsTheSharedRuntime() async throws {
        let runtime = ViewModelRuntime(holdGeneration: true)
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        _ = try await coordinator.switchModel(to: "model")
        let model = PhoneCoderChatModel(coordinator: coordinator, history: ViewModelHistory())
        model.draft = "Wait"
        let task = model.send()
        await runtime.waitForRequest()
        model.stop()
        await task.value
        XCTAssertFalse(model.isGenerating)
        XCTAssertTrue(model.messages.last?.wasInterrupted ?? false)
        try await coordinator.unloadModel()
        let state = await coordinator.state()
        XCTAssertNil(state.modelSession)
        XCTAssertNil(state.activeRequestID)
        XCTAssertEqual(state.waitingCount, 0)
        let cancelled = await runtime.cancelledIDs
        XCTAssertEqual(cancelled.count, 1)
        let barrier = await coordinator.suspendForLifecycle()
        await barrier.value
        do { try await coordinator.unloadModel(); XCTFail("Unload must reject while suspended") }
        catch { XCTAssertEqual(error as? PhoneCoderRuntimeError, .lifecycleUnavailable) }
    }

    func testModelsLoadSwitchAndUnloadReflectTheSameCoordinator() async {
        let runtime = ViewModelRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        let model = PhoneCoderModelsModel(coordinator: coordinator)
        await model.refresh()
        XCTAssertEqual(model.installed.map(\.id), ["model"])
        XCTAssertNil(model.loadedID)
        await model.load("model")
        XCTAssertEqual(model.loadedID, "model")
        await model.load("replacement")
        XCTAssertEqual(model.loadedID, "replacement")
        await model.unload()
        XCTAssertNil(model.loadedID)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
    }

    func testOversizedChatInputIsRecoverableWithoutStartingRuntime() async {
        let runtime = ViewModelRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        let model = PhoneCoderChatModel(coordinator: coordinator, history: ViewModelHistory())
        model.draft = String(repeating: "x", count: 1_048_577)
        await model.send().value
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertFalse(model.isGenerating)
        XCTAssertEqual(model.draft.utf8.count, 1_048_577)
        let ids = await runtime.requestIDs
        XCTAssertTrue(ids.isEmpty)
    }

    func testClientSummariesPreserveLongRTLNamesAndSurfaceReadFailures() async throws {
        let storage = ViewModelPairingStorage()
        let store = PhoneCoderPairingStore(storage: storage)
        let name = String(repeating: "ج", count: 80)
        let credential = try await store.create(name: name)
        let clients = try await store.clients()
        XCTAssertEqual(clients, [.init(id: credential.id, name: name)])
        storage.failRead = true
        do { _ = try await store.clients(); XCTFail("Read failure must surface, not masquerade as no clients") } catch {}
        storage.failRead = false
        try await store.revoke(id: credential.id)
        let remaining = try await store.clients()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDismissedPairingPayloadCannotIssueCredential() async throws {
        let store = PhoneCoderPairingStore(storage: ViewModelPairingStorage())
        let exchange = PhoneCoderPairingExchange(store: store)
        let payload = try await exchange.issue(server: "http://100.64.0.1:11434", apiVersion: "phone-coder-api/1", tailnetIdentity: "100.64.0.1")
        await exchange.invalidate(token: payload.token)
        let credential = try await exchange.redeem(token: payload.token, name: "Laptop") { _ in
            XCTFail("Invalidated token must never reach approval"); return true
        }
        XCTAssertNil(credential)
    }

    func testApprovalHasOnlyOnePendingDecisionAndDenialResolvesIt() async {
        let approval = PhoneCoderPairingApproval()
        let shown = expectation(description: "Owner sees named client")
        let subscription = approval.$pending.compactMap { $0 }.prefix(1).sink { request in
            XCTAssertEqual(request.name, "Laptop")
            shown.fulfill()
        }
        let first = Task { await approval.request(name: "Laptop") }
        await fulfillment(of: [shown], timeout: 2)
        let second = await approval.request(name: "Other laptop")
        XCTAssertFalse(second)
        if let pending = approval.pending { approval.resolve(id: pending.id, approved: false) }
        let result = await first.value
        XCTAssertFalse(result)
        XCTAssertNil(approval.pending)
        withExtendedLifetime(subscription) {}
    }

    func testAuthenticationRecoveryRoutesStartAndRestoresServingIntent() async throws {
        let fixture = RecoveryFixture()
        await fixture.controller.handle(scenePhase: .active).value
        _ = try await fixture.coordinator.switchModel(to: "model")
        fixture.listener.failure = .authentication
        await PhoneCoderServerPresentation(.stopped).action.perform(controller: fixture.controller, openModels: {}).value
        XCTAssertEqual(fixture.controller.state, .authenticationError)
        XCTAssertFalse(fixture.controller.servingRequested)
        XCTAssertTrue(PhoneCoderServerPresentation(fixture.controller.state).detail.contains("credential store"))
        fixture.listener.failure = nil
        await PhoneCoderServerPresentation(fixture.controller.state).action.perform(controller: fixture.controller, openModels: {}).value
        XCTAssertTrue(fixture.controller.servingRequested)
        XCTAssertEqual(fixture.controller.state, .ready)
        XCTAssertEqual(fixture.listener.starts, 2)
        await PhoneCoderServerAction.stop.perform(controller: fixture.controller, openModels: {}).value
        XCTAssertEqual(fixture.controller.state, .stopped)
    }

    func testMissingModelRecoveryLoadsAndStartsOnlyCurrentServingIntent() async {
        let fixture = RecoveryFixture()
        await fixture.controller.handle(scenePhase: .active).value
        await PhoneCoderServerAction.start.perform(controller: fixture.controller, openModels: {}).value
        XCTAssertEqual(fixture.controller.state, .modelUnavailable)
        XCTAssertEqual(fixture.listener.starts, 0)
        var openedModels = false
        await PhoneCoderServerPresentation(fixture.controller.state).action.perform(controller: fixture.controller, openModels: { openedModels = true }).value
        XCTAssertTrue(openedModels)
        let models = PhoneCoderModelsModel(coordinator: fixture.coordinator,
            onModelLoaded: { await fixture.controller.modelDidLoad() })
        await models.load("model")
        XCTAssertEqual(fixture.controller.state, .ready)
        XCTAssertEqual(fixture.listener.starts, 1)
        await fixture.controller.stopServing().value
        await models.load("replacement")
        XCTAssertFalse(fixture.controller.servingRequested)
        XCTAssertEqual(fixture.listener.starts, 1, "A successful load cannot undo a newer Stop intent")
        await fixture.controller.handle(scenePhase: .background).value
        await fixture.controller.startServing().value
        await fixture.controller.modelDidLoad()
        XCTAssertEqual(fixture.listener.starts, 1, "A load callback cannot start background serving")
    }

    func testLowMemoryRecoveryRoutesExplicitRetryAfterRemediation() async throws {
        let fixture = RecoveryFixture()
        await fixture.controller.handle(scenePhase: .active).value
        _ = try await fixture.coordinator.switchModel(to: "model")
        await fixture.runtime.setAvailability(.unavailable(.memoryPressure))
        await PhoneCoderServerAction.start.perform(controller: fixture.controller, openModels: {}).value
        XCTAssertEqual(fixture.controller.state, .lowMemory)
        XCTAssertTrue(fixture.controller.servingRequested)
        XCTAssertEqual(fixture.listener.starts, 0)
        let presentation = PhoneCoderServerPresentation(fixture.controller.state)
        XCTAssertEqual(presentation.action, .retry)
        XCTAssertTrue(presentation.offersModels)
        await fixture.runtime.setAvailability(.available)
        await presentation.action.perform(controller: fixture.controller, openModels: {}).value
        XCTAssertEqual(fixture.controller.state, .ready)
        XCTAssertEqual(fixture.listener.starts, 1)
        await fixture.controller.stopServing().value
    }

    func testStrictContextFailureBlocksUnchangedRetryAndCanShortenLastInput() async throws {
        let runtime = ViewModelRuntime(contextWindow: 80)
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        _ = try await coordinator.switchModel(to: "model")
        let model = PhoneCoderChatModel(coordinator: coordinator, history: ViewModelHistory())
        model.draft = "seed"
        await model.send().value
        let priorTokens = model.messages.reduce(0) { $0 + $1.content.utf8.count }
        model.draft = String(repeating: "x", count: 60)
        await model.send().value
        XCTAssertEqual(model.budgetError?.promptTokens, priorTokens + 60)
        XCTAssertEqual(model.budgetError?.outputTokens, 8)
        XCTAssertEqual(model.budgetError?.contextWindow, 80)
        XCTAssertTrue(model.error?.contains("\(priorTokens + 60) prompt tokens") ?? false)
        XCTAssertTrue(model.error?.contains("8 output tokens") ?? false)
        XCTAssertTrue(model.error?.contains("80-token context") ?? false)
        XCTAssertFalse(model.canRetry)
        await model.retry().value
        let attempts = await runtime.requestIDs.count
        XCTAssertEqual(attempts, 2, "Identical overflow must not be submitted again")
        model.shortenLastInput()
        XCTAssertEqual(model.draft, String(repeating: "x", count: 60))
        XCTAssertEqual(model.messages.count, 2, "Edit preserves earlier conversation turns")
        model.draft = "x"
        await model.send().value
        XCTAssertNil(model.budgetError)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.messages.last?.role, .assistant)
    }

    func testAccumulatedHistoryOverflowNeedsNewConversationToRestoreSendability() async throws {
        let runtime = ViewModelRuntime(contextWindow: 80)
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        _ = try await coordinator.switchModel(to: "model")
        let model = PhoneCoderChatModel(coordinator: coordinator, history: ViewModelHistory())
        model.draft = String(repeating: "a", count: 30)
        await model.send().value
        model.draft = "b"
        await model.send().value
        XCTAssertNotNil(model.budgetError)
        model.draft = "Extra text cannot repair an already full transcript"
        await model.send().value
        let countBeforeReset = await runtime.requestIDs.count
        XCTAssertEqual(countBeforeReset, 2)
        model.newConversation()
        XCTAssertNil(model.budgetError)
        model.draft = "new"
        await model.send().value
        XCTAssertNil(model.error)
        XCTAssertEqual(model.messages.count, 2)
        let requests = await runtime.requestIDs.count
        XCTAssertEqual(requests, 3)
    }

    func testPortCannotChangeWhileListenerIsActive() async throws {
        let runtime = ViewModelRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        let pairings = PhoneCoderPairingStore(storage: ViewModelPairingStorage())
        let server = PhoneCoderAPIServer(coordinator: coordinator,
            ledger: PhoneCoderRequestLedger(sessionID: UUID()), pairings: pairings,
            exchange: PhoneCoderPairingExchange(store: pairings),
            activity: PhoneCoderServerActivityStore(url: nil), approval: { _ in false })
        // Ephemeral port is used only by this transport fixture.
        let listener = PhoneCoderNetworkListener(server: server, port: 0)
        XCTAssertThrowsError(try listener.setPort(1023))
        try await listener.start(sessionID: UUID())
        XCTAssertThrowsError(try listener.setPort(11435))
        listener.stop()
        try listener.setPort(11435)
        XCTAssertEqual(listener.port, 11435)
    }

    // Device fixture matrix (requires Xcode, not executable on Linux): launch
    // all five native tabs in light/dark, accessibility XXXL, Arabic RTL,
    // landscape, Reduce Motion and VoiceOver. Exercise 80-character client
    // names and 200-character model names; no fixed row height or truncation.
}

@MainActor
private final class ViewModelHistory: PhoneCoderChatHistory {
    var saved: [[ChatMessage]] = []
    func save(id: UUID, messages: [ChatMessage], modelID: String) { saved.append(messages) }
}

private actor ViewModelRuntime: PhoneCoderTextRuntime {
    var requestIDs: [PhoneCoderRequestID] = []
    var cancelledIDs: Set<PhoneCoderRequestID> = []
    private let holdGeneration: Bool
    private let contextWindow: Int?
    private var availability: PhoneCoderRuntimeAvailability = .available
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var generationWaiter: CheckedContinuation<Void, Never>?
    init(holdGeneration: Bool = false, contextWindow: Int? = nil) {
        self.holdGeneration = holdGeneration; self.contextWindow = contextWindow
    }
    func setAvailability(_ value: PhoneCoderRuntimeAvailability) { availability = value }
    func waitForRequest() async {
        if !requestIDs.isEmpty { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }
    func installedModels() -> [PhoneCoderModelDescriptor] { [.init(id: "model", displayName: "Model")] }
    func liveAvailability() -> PhoneCoderRuntimeAvailability { availability }
    func load(modelID: String) -> PhoneCoderModelSession { .init(id: UUID(), modelID: modelID) }
    func cancel(requestID: PhoneCoderRequestID) {
        cancelledIDs.insert(requestID)
        generationWaiter?.resume(); generationWaiter = nil
    }
    func unload() {}
    func generate(_ request: PhoneCoderGenerationRequest, session: PhoneCoderModelSession,
                  onEvent: @escaping @Sendable (PhoneCoderRuntimeEvent) async -> Void) async throws -> PhoneCoderGenerationResult {
        requestIDs.append(request.id)
        if request.strictAPI, let contextWindow {
            _ = try LocalAPIStrictInput.outputTokens(requested: 8,
                promptTokens: request.messages.reduce(0) { $0 + $1.content.utf8.count },
                limits: .init(contextWindow: contextWindow, maximumOutputTokens: 8, defaultOutputTokens: 8,
                              limitSource: .runtime, tokenCountMode: .exact))
        }
        await onEvent(.init(requestID: request.id, sessionID: request.sessionID, modelSessionID: session.id,
                            text: "<tool_call>literal text</tool_call>"))
        let waiters = requestWaiters; requestWaiters = []
        waiters.forEach { $0.resume() }
        if holdGeneration, !cancelledIDs.contains(request.id) {
            await withCheckedContinuation { generationWaiter = $0 }
        }
        return .init(requestID: request.id, sessionID: request.sessionID, modelSessionID: session.id,
                     promptTokens: 12, completionTokens: 8, finishReason: .stop)
    }
}

@MainActor
private final class RecoveryFixture {
    let runtime: ViewModelRuntime
    let coordinator: PhoneCoderInferenceCoordinator
    let listener: RecoveryListener
    let controller: PhoneCoderServerController
    init() {
        let runtime = ViewModelRuntime()
        self.runtime = runtime
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        self.coordinator = coordinator
        let listener = RecoveryListener()
        self.listener = listener
        controller = PhoneCoderServerController(listener: listener,
            inference: PhoneCoderInferenceLifecycle(coordinator: coordinator, ledger: .init(sessionID: UUID())),
            intent: RecoveryIntent(), clock: PhoneCoderContinuousServerClock(), setIdleTimerDisabled: { _ in })
    }
}

@MainActor
private final class RecoveryListener: PhoneCoderServerListening {
    var starts = 0
    var failure: PhoneCoderListenerError?
    func start(sessionID: UUID) async throws {
        starts += 1
        if let failure { throw failure }
    }
    func stop() {}
}

@MainActor
private final class RecoveryIntent: PhoneCoderServingIntentStore {
    var servingRequested = false
}

private final class ViewModelPairingStorage: PhoneCoderPairingStorage {
    var value: String?
    var failRead = false
    func read() throws -> String? {
        if failRead { throw CocoaError(.fileReadUnknown) }
        return value
    }
    func write(_ value: String) throws { self.value = value }
}
