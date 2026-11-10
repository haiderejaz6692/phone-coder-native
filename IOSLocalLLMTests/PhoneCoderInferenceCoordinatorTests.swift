import XCTest
import CryptoKit
@testable import PhoneCoder

final class PhoneCoderInferenceCoordinatorTests: XCTestCase {
    // Removing the active lease or changing FIFO admission must break this test.
    func testOneLeaseFIFOAndFourWaitingLimit() async throws {
        let runtime = ControlledTextRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        let first = try await coordinator.enqueue(request("0")) { _ in }
        await runtime.waitForStarts(1)
        var pending: [Task<PhoneCoderGenerationResult, Error>] = []
        for id in 1...4 { pending.append(try await coordinator.enqueue(request("\(id)")) { _ in }) }
        do {
            _ = try await coordinator.enqueue(request("overflow")) { _ in }
            XCTFail("A fifth waiter must be rejected")
        } catch { XCTAssertEqual(error as? PhoneCoderRuntimeError, .queueFull) }
        let starts = await runtime.startedIDs
        XCTAssertEqual(starts, ["0"])
        await runtime.succeed()
        _ = try await first.value
        for index in 0..<4 {
            await runtime.waitForStarts(index + 2)
            let order = await runtime.startedIDs
            XCTAssertEqual(order, (0...(index + 1)).map(String.init))
            await runtime.succeed()
            _ = try await pending[index].value
        }
    }

    func testQueuedAndActiveCancellationDrainBeforeNextLease() async throws {
        let runtime = ControlledTextRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        let active = try await coordinator.enqueue(request("active")) { _ in }
        await runtime.waitForStarts(1)
        let queued = try await coordinator.enqueue(request("queued")) { _ in }
        let next = try await coordinator.enqueue(request("next")) { _ in }
        await coordinator.cancel(requestID: request("queued").id, sessionID: sessionID)
        await assertError(queued, .cancelled)
        await runtime.holdCancellation()
        let activeID = request("active").id
        let capturedSession = sessionID
        let cancellation = Task { await coordinator.cancel(requestID: activeID, sessionID: capturedSession) }
        await runtime.waitForCancellation()
        let whileDraining = await runtime.startedIDs
        XCTAssertEqual(whileDraining, ["active"])
        await runtime.releaseCancellation()
        await cancellation.value
        await assertError(active, .cancelled)
        await runtime.waitForStarts(2)
        let order = await runtime.startedIDs
        XCTAssertEqual(order, ["active", "next"])
        await runtime.succeed()
        _ = try await next.value
    }

    func testSwitchCancelsOldQueueAndRejectsLateCallbacks() async throws {
        let runtime = ControlledTextRuntime()
        let sink = EventCollector()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        let active = try await coordinator.enqueue(request("old")) { await sink.append($0) }
        await runtime.waitForStarts(1)
        let queued = try await coordinator.enqueue(request("queued")) { await sink.append($0) }
        let oldSession = await runtime.lastSession
        await runtime.holdCancellation()
        let switching = Task { try await coordinator.switchModel(to: "other") }
        await runtime.waitForCancellation()
        let whileDraining = await runtime.operations
        XCTAssertEqual(whileDraining, ["load:model", "start:old", "cancel:old"])
        do {
            _ = try await coordinator.enqueue(request("during-switch")) { _ in }
            XCTFail("Admission must close while old native work drains")
        } catch { XCTAssertEqual(error as? PhoneCoderRuntimeError, .switchingModel) }
        await runtime.releaseCancellation()
        let newSession = try await switching.value
        await assertError(active, .cancelled)
        await assertError(queued, .cancelled)
        XCTAssertNotEqual(oldSession?.id, newSession.id)
        await runtime.emitFromStart(0, text: "stale")
        let events = await sink.events
        XCTAssertTrue(events.isEmpty)
        let operations = await runtime.operations
        XCTAssertEqual(operations, ["load:model", "start:old", "cancel:old", "unload", "load:other"])
    }

    func testCapturedIdentitiesGateConsumerAndLedger() async throws {
        let runtime = ControlledTextRuntime()
        let ledger = PhoneCoderRequestLedger(sessionID: sessionID)
        let req = request("same")
        _ = try await ledger.begin(id: req.id, fingerprint: SHA256.hash(data: Data()), sessionID: sessionID,
                                   deadline: ContinuousClock.now.advanced(by: .seconds(60)))
        let sink = EventCollector()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        let handle = try await coordinator.enqueue(req) { event in
            await sink.append(event)
            _ = try? await ledger.append(id: event.requestID, event: .chatText(.init(id: "test", model: "model", created: 0), event.text), sessionID: event.sessionID)
        }
        await runtime.waitForStarts(1)
        await runtime.emitFromStart(0, text: "wrong", modelSessionID: UUID())
        await runtime.emitFromStart(0, text: "wrong", sessionID: UUID())
        await runtime.emitFromStart(0, text: "valid")
        await runtime.succeed()
        _ = try await handle.value
        let events = await sink.events
        XCTAssertEqual(events.map(\.text), ["valid"])
        XCTAssertEqual(events.first?.requestID, req.id)
        XCTAssertEqual(events.first?.sessionID, sessionID)
        try await ledger.finish(id: req.id, terminal: .completed, sessionID: sessionID)
        let replay = try await ledger.attach(id: req.id, fingerprint: SHA256.hash(data: Data()), after: nil)
        var recorded: [PhoneCoderRequestLedger.SequencedEvent] = []
        for await event in replay { recorded.append(event) }
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.event, .chatText(.init(id: "test", model: "model", created: 0), "valid"))
    }

    func testStaleTerminalResultCannotCompleteCurrentRequest() async throws {
        let runtime = ControlledTextRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: {
            XCTFail("A stale completion must not be retried")
            return runtime
        })
        let handle = try await coordinator.enqueue(request("terminal")) { _ in }
        await runtime.waitForStarts(1)
        await runtime.succeed(modelSessionID: UUID())
        await assertError(handle, .staleSession)
    }

    func testSafetyRefusalsKeepCategoriesAndNeverReconstruct() async throws {
        for refusal in [PhoneCoderRuntimeError.memoryPressure, .thermal] {
            let runtime = ControlledTextRuntime()
            await runtime.setAvailability(.unavailable(refusal))
            let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: {
                XCTFail("Safety refusals must not reconstruct")
                return runtime
            })
            let handle = try await coordinator.enqueue(request("refused")) { _ in }
            await assertError(handle, refusal)
            let state = await coordinator.state()
            XCTAssertEqual(state.availability, .unavailable(refusal))
        }
    }

    func testLoadAdmissionErrorsAreNotRetriedOrRelabelled() async throws {
        for refusal in [PhoneCoderRuntimeError.memoryPressure, .thermal] {
            let runtime = ControlledTextRuntime()
            await runtime.setLoadError(refusal)
            let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: {
                XCTFail("Load admission must not be retried")
                return runtime
            })
            let handle = try await coordinator.enqueue(request("load-refused")) { _ in }
            await assertError(handle, refusal)
            let starts = await runtime.startedIDs
            XCTAssertTrue(starts.isEmpty)
        }
    }

    func testReconstructsOnlyOnceBeforeOutputWithNewSession() async throws {
        let first = ControlledTextRuntime()
        let second = ControlledTextRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: first, reconstruct: { second })
        let sink = EventCollector()
        let handle = try await coordinator.enqueue(request("retry")) { await sink.append($0) }
        await first.waitForStarts(1)
        await first.fail(.runtimeFailure)
        await second.waitForStarts(1)
        await first.emitFromStart(0, text: "late")
        await second.fail(.runtimeFailure)
        await assertError(handle, .runtimeFailure)
        let events = await sink.events
        XCTAssertTrue(events.isEmpty)
        let old = await first.lastSession
        let new = await second.lastSession
        XCTAssertNotEqual(old?.id, new?.id)
        let operations = await first.operations
        XCTAssertEqual(operations.last, "unload")
    }

    func testServerPrologueCommitAlsoForbidsRetry() async throws {
        let runtime = ControlledTextRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: {
            XCTFail("A server prologue already committed to the ledger")
            return runtime
        })
        let handle = try await coordinator.enqueue(request("prologue")) { _ in }
        await coordinator.markOutputCommitted(requestID: request("prologue").id, sessionID: sessionID)
        await runtime.waitForStarts(1)
        await runtime.fail(.runtimeFailure)
        await assertError(handle, .runtimeFailure)
    }

    func testCommitWhileReconstructionIsSuspendedPreventsRetry() async throws {
        let runtime = ControlledTextRuntime()
        let replacement = ControlledTextRuntime()
        let gate = ReconstructionGate()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: {
            await gate.enter()
            return replacement
        })
        let handle = try await coordinator.enqueue(request("reentrant")) { _ in }
        await runtime.waitForStarts(1)
        await runtime.fail(.runtimeFailure)
        await gate.waitForEntry()
        await coordinator.markOutputCommitted(requestID: request("reentrant").id, sessionID: sessionID)
        await gate.release()
        await assertError(handle, .runtimeFailure)
        let starts = await replacement.startedIDs
        XCTAssertTrue(starts.isEmpty)
    }

    func testNeverRetriesAfterFirstCommittedEvent() async throws {
        let runtime = ControlledTextRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: {
            XCTFail("Output has already committed")
            return runtime
        })
        let sink = EventCollector()
        let handle = try await coordinator.enqueue(request("partial")) { await sink.append($0) }
        await runtime.waitForStarts(1)
        await runtime.emitFromStart(0, text: "partial")
        await runtime.fail(.runtimeFailure)
        await assertError(handle, .runtimeFailure)
        let events = await sink.events
        XCTAssertEqual(events.map(\.text), ["partial"])
    }

    func testHealthReadsLiveHeavyResidencyAndSafety() async throws {
        let runtime = ControlledTextRuntime()
        let coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        _ = try await coordinator.switchModel(to: "model")
        let ready = await coordinator.state()
        XCTAssertEqual(ready.availability, .available)
        await runtime.setAvailability(.unavailable(.residencyUnavailable))
        let unavailable = await coordinator.state()
        XCTAssertEqual(unavailable.availability, .unavailable(.residencyUnavailable))
        await runtime.setAvailability(.unavailable(.thermal))
        let hot = await coordinator.state()
        XCTAssertEqual(hot.availability, .unavailable(.thermal))
    }

    private let sessionID = UUID()
    private func request(_ id: String) -> PhoneCoderGenerationRequest {
        PhoneCoderGenerationRequest(id: .init(rawValue: id), sessionID: sessionID, modelID: "model",
                                   messages: [ChatMessage(role: .user, content: "hello")])
    }
    private func assertError(_ task: Task<PhoneCoderGenerationResult, Error>, _ expected: PhoneCoderRuntimeError,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? PhoneCoderRuntimeError, expected, file: file, line: line) }
    }
}

private actor EventCollector {
    var events: [PhoneCoderRuntimeEvent] = []
    func append(_ event: PhoneCoderRuntimeEvent) { events.append(event) }
}

/// Native generation is the expensive external boundary. Every suspension here
/// is controlled by the test; no timers, sleeps, polling, or scheduler guesses.
private actor ControlledTextRuntime: PhoneCoderTextRuntime {
    struct Start {
        let request: PhoneCoderGenerationRequest
        let session: PhoneCoderModelSession
        let callback: @Sendable (PhoneCoderRuntimeEvent) async -> Void
    }
    var starts: [Start] = []
    var startedIDs: [String] { starts.map { $0.request.id.rawValue } }
    var operations: [String] = []
    var lastSession: PhoneCoderModelSession?
    private var availability: PhoneCoderRuntimeAvailability = .available
    private var loadError: PhoneCoderRuntimeError?
    func setLoadError(_ error: PhoneCoderRuntimeError) { loadError = error }
    private var completion: CheckedContinuation<PhoneCoderGenerationResult, Error>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var holdsCancellation = false
    private var cancellationStarted = false
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private var cancellationRelease: CheckedContinuation<Void, Never>?
    func holdCancellation() { holdsCancellation = true }
    func waitForCancellation() async {
        if cancellationStarted { return }
        await withCheckedContinuation { cancellationWaiter = $0 }
    }
    func releaseCancellation() {
        cancellationRelease?.resume()
        cancellationRelease = nil
    }
    func installedModels() async -> [PhoneCoderModelDescriptor] { [] }
    func liveAvailability() async -> PhoneCoderRuntimeAvailability { availability }
    func setAvailability(_ value: PhoneCoderRuntimeAvailability) { availability = value }
    func load(modelID: String) async throws -> PhoneCoderModelSession {
        operations.append("load:\(modelID)")
        if let loadError { throw loadError }
        let session = PhoneCoderModelSession(id: UUID(), modelID: modelID)
        lastSession = session
        return session
    }
    func generate(_ request: PhoneCoderGenerationRequest, session: PhoneCoderModelSession,
                  onEvent: @escaping @Sendable (PhoneCoderRuntimeEvent) async -> Void) async throws -> PhoneCoderGenerationResult {
        operations.append("start:\(request.id.rawValue)")
        starts.append(Start(request: request, session: session, callback: onEvent))
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            let ready = waiters.filter { $0.0 <= starts.count }
            waiters.removeAll { $0.0 <= starts.count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForStarts(_ count: Int) async {
        if starts.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func emitFromStart(_ index: Int, text: String, modelSessionID: UUID? = nil, sessionID: UUID? = nil) async {
        let start = starts[index]
        await start.callback(.init(requestID: start.request.id, sessionID: sessionID ?? start.request.sessionID,
                                   modelSessionID: modelSessionID ?? start.session.id, text: text))
    }
    func succeed(modelSessionID: UUID? = nil) {
        let start = starts.last!
        let pending = completion
        completion = nil
        pending?.resume(returning: .init(requestID: start.request.id, sessionID: start.request.sessionID,
                                        modelSessionID: modelSessionID ?? start.session.id, promptTokens: 1, completionTokens: 1,
                                        finishReason: .stop))
    }
    func fail(_ error: PhoneCoderRuntimeError) {
        let pending = completion
        completion = nil
        pending?.resume(throwing: error)
    }
    func cancel(requestID: PhoneCoderRequestID) async {
        operations.append("cancel:\(requestID.rawValue)")
        fail(.cancelled)
        cancellationStarted = true
        if holdsCancellation {
            await withCheckedContinuation { continuation in
                cancellationRelease = continuation
                cancellationWaiter?.resume()
                cancellationWaiter = nil
            }
        } else {
            cancellationWaiter?.resume()
            cancellationWaiter = nil
        }
    }
    func unload() async { operations.append("unload") }
}

private actor ReconstructionGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?
    func enter() async {
        await withCheckedContinuation { continuation in
            entered = true
            resume = continuation
            entry?.resume()
            entry = nil
        }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }
    func release() { resume?.resume(); resume = nil }
}
