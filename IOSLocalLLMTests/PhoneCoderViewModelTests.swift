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
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var generationWaiter: CheckedContinuation<Void, Never>?
    init(holdGeneration: Bool = false) { self.holdGeneration = holdGeneration }
    func waitForRequest() async {
        if !requestIDs.isEmpty { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }
    func installedModels() -> [PhoneCoderModelDescriptor] { [.init(id: "model", displayName: "Model")] }
    func liveAvailability() -> PhoneCoderRuntimeAvailability { .available }
    func load(modelID: String) -> PhoneCoderModelSession { .init(id: UUID(), modelID: modelID) }
    func cancel(requestID: PhoneCoderRequestID) {
        cancelledIDs.insert(requestID)
        generationWaiter?.resume(); generationWaiter = nil
    }
    func unload() {}
    func generate(_ request: PhoneCoderGenerationRequest, session: PhoneCoderModelSession,
                  onEvent: @escaping @Sendable (PhoneCoderRuntimeEvent) async -> Void) async throws -> PhoneCoderGenerationResult {
        requestIDs.append(request.id)
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

private final class ViewModelPairingStorage: PhoneCoderPairingStorage {
    var value: String?
    var failRead = false
    func read() throws -> String? {
        if failRead { throw CocoaError(.fileReadUnknown) }
        return value
    }
    func write(_ value: String) throws { self.value = value }
}
