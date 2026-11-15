import Foundation

/// Sole Phone Coder text-runtime owner. Callers enqueue already-adapted text
/// requests and consume value events; they never touch a native model service.
actor PhoneCoderInferenceCoordinator {
    @MainActor static let shared = PhoneCoderInferenceCoordinator(
        runtime: OnDeviceTextRuntimeAdapter(),
        reconstruct: { await OnDeviceTextRuntimeAdapter() }
    )

    private struct Work: Sendable {
        let lease = UUID()
        var outputCommitted = false
        let request: PhoneCoderGenerationRequest
        let onEvent: @Sendable (PhoneCoderRuntimeEvent) async -> Void
        let resolve: @Sendable (Result<PhoneCoderGenerationResult, Error>) -> Void
    }
    private var runtime: any PhoneCoderTextRuntime
    private let reconstruct: @Sendable () async -> any PhoneCoderTextRuntime
    private var modelSession: PhoneCoderModelSession?
    private var queue: [Work] = []
    private var active: Work?
    private var worker: Task<Void, Never>?
    private var cancellation: Task<Void, Never>?
    private var cancelled = false
    private var committedOutput = false
    private var switching = false
    private var lifecycleSuspended = false
    private var lifecycleEpoch: UInt64 = 0
    private var lifecycleDrain: Task<Void, Never>?
    private var switchWaiters: [CheckedContinuation<Void, Never>] = []

    init(runtime: any PhoneCoderTextRuntime,
         reconstruct: @escaping @Sendable () async -> any PhoneCoderTextRuntime) {
        self.runtime = runtime
        self.reconstruct = reconstruct
    }

    func installedModels() async -> [PhoneCoderModelDescriptor] { await runtime.installedModels() }

    func capabilities() async throws -> PhoneCoderRuntimeCapabilities {
        guard !lifecycleSuspended, !switching, let session = modelSession else { throw PhoneCoderRuntimeError.modelUnavailable }
        let value = try await runtime.capabilities(session: session)
        guard modelSession == session, !switching, !lifecycleSuspended else { throw PhoneCoderRuntimeError.staleSession }
        return value
    }

    func preflight(_ request: PhoneCoderGenerationRequest) async throws -> PhoneCoderRuntimePreflight {
        guard !lifecycleSuspended else { throw PhoneCoderRuntimeError.lifecycleUnavailable }
        guard !switching else { throw PhoneCoderRuntimeError.switchingModel }
        guard let session = modelSession, session.modelID == request.modelID,
              request.expectedModelSessionID == session.id else { throw PhoneCoderRuntimeError.staleSession }
        let result = try await runtime.preflight(request, session: session)
        guard modelSession == session, !switching, !lifecycleSuspended else { throw PhoneCoderRuntimeError.staleSession }
        return result
    }

    func state() async -> PhoneCoderRuntimeState {
        var availability = await runtime.liveAvailability()
        if lifecycleSuspended { availability = .unavailable(.lifecycleUnavailable) }
        else if switching { availability = .unavailable(.switchingModel) }
        else if modelSession == nil, availability == .available { availability = .unavailable(.modelUnavailable) }
        return PhoneCoderRuntimeState(availability: availability,
                                     modelSession: modelSession, activeRequestID: active?.request.id,
                                     waitingCount: queue.count, switchingModel: switching)
    }

    /// Admission is synchronous on this actor, so FIFO does not depend on
    /// scheduling Tasks created by callers. Cancellation uses both identities.
    /// `onEvent` is awaited by the generation worker for ordered backpressure.
    /// It must not await cancel/unload/switch/lifecycle work that drains this
    /// same worker; signal such work from a separate task and return instead.
    func enqueue(_ request: PhoneCoderGenerationRequest,
                 onEvent: @escaping @Sendable (PhoneCoderRuntimeEvent) async -> Void) throws -> Task<PhoneCoderGenerationResult, Error> {
        try request.cancellationSignal?.check()
        guard !lifecycleSuspended else { throw PhoneCoderRuntimeError.lifecycleUnavailable }
        guard !switching else { throw PhoneCoderRuntimeError.switchingModel }
        if request.strictAPI {
            guard modelSession?.id == request.expectedModelSessionID, modelSession?.modelID == request.modelID else { throw PhoneCoderRuntimeError.staleSession }
        }
        guard !([active].compactMap { $0 } + queue).contains(where: {
            $0.request.id == request.id && $0.request.sessionID == request.sessionID
        }) else { throw PhoneCoderRuntimeError.duplicateRequest }
        guard active == nil || queue.count < 4 else { throw PhoneCoderRuntimeError.queueFull }
        // A synchronous promise makes admission visible before this method
        // returns, rather than deferring queue insertion to a scheduled Task.
        let (stream, continuation) = AsyncThrowingStream<PhoneCoderGenerationResult, Error>.makeStream()
        let result = Task {
            try await withTaskCancellationHandler {
                for try await value in stream { return value }
                throw PhoneCoderRuntimeError.cancelled
            } onCancel: {
                Task { await self.cancel(requestID: request.id, sessionID: request.sessionID) }
            }
        }
        admit(request, onEvent: onEvent, resolve: { outcome in
            switch outcome {
            case .success(let value): continuation.yield(value); continuation.finish()
            case .failure(let error): continuation.finish(throwing: error)
            }
        })
        return result
    }

    private func admit(_ request: PhoneCoderGenerationRequest,
                       onEvent: @escaping @Sendable (PhoneCoderRuntimeEvent) async -> Void,
                       resolve: @escaping @Sendable (Result<PhoneCoderGenerationResult, Error>) -> Void) {
        let work = Work(request: request, onEvent: onEvent, resolve: resolve)
        if active == nil { start(work) }
        else { queue.append(work) }
    }

    private func start(_ work: Work) {
        active = work
        cancelled = false
        committedOutput = work.outputCommitted
        worker = Task { await self.run(work) }
    }

    /// The transport must call this before committing a non-runtime event
    /// (for example response.created) so reconstruction cannot replay it.
    func markOutputCommitted(requestID: PhoneCoderRequestID, sessionID: UUID) {
        if active?.request.id == requestID, active?.request.sessionID == sessionID {
            committedOutput = true
        } else if let index = queue.firstIndex(where: {
            $0.request.id == requestID && $0.request.sessionID == sessionID
        }) {
            queue[index].outputCommitted = true
        }
    }

    func cancel(requestID: PhoneCoderRequestID, sessionID: UUID) async {
        if let index = queue.firstIndex(where: { $0.request.id == requestID && $0.request.sessionID == sessionID }) {
            queue.remove(at: index).resolve(.failure(PhoneCoderRuntimeError.cancelled))
            return
        }
        guard active?.request.id == requestID, active?.request.sessionID == sessionID else { return }
        cancelled = true // invalidate callbacks before crossing the runtime boundary
        if cancellation == nil {
            let owner = runtime
            cancellation = Task { await owner.cancel(requestID: requestID) }
        }
        await cancellation?.value
    }

    /// Closes admission and invalidates callbacks before any suspension point.
    /// The returned barrier may outlive the iOS foreground transition: callers
    /// must not hold a background assertion while awaiting native Metal work.
    @discardableResult
    func suspendForLifecycle() -> Task<Void, Never> {
        lifecycleEpoch &+= 1
        lifecycleSuspended = true
        cancelled = true
        let pending = queue
        queue.removeAll()
        pending.forEach { $0.resolve(.failure(PhoneCoderRuntimeError.cancelled)) }
        if let request = active?.request, cancellation == nil {
            let owner = runtime
            cancellation = Task { await owner.cancel(requestID: request.id) }
        }
        let retiringWorker = worker
        let retiringCancellation = cancellation
        let previousDrain = lifecycleDrain
        let drain = Task {
            await previousDrain?.value
            await retiringCancellation?.value
            await retiringWorker?.value
            await self.waitForModelSwitch()
        }
        lifecycleDrain = drain
        return drain
    }

    /// Captures the suspension epoch synchronously. A newer suspension defeats
    /// this resume even when native cancellation takes seconds to retire.
    func resumeAfterLifecycle() -> Task<Bool, Never> {
        let epoch = lifecycleEpoch
        let drain = lifecycleDrain
        return Task {
            await drain?.value
            return self.finishLifecycleResume(epoch: epoch)
        }
    }

    private func finishLifecycleResume(epoch: UInt64) -> Bool {
        guard epoch == lifecycleEpoch else { return false }
        lifecycleSuspended = false
        lifecycleDrain = nil
        return true
    }

    private func waitForModelSwitch() async {
        guard switching else { return }
        await withCheckedContinuation { switchWaiters.append($0) }
    }

    /// Reject admission immediately, invalidate callbacks, drain old work, then
    /// unload/load. Concurrent switches cannot interleave heavy allocations.
    func switchModel(to modelID: String) async throws -> PhoneCoderModelSession {
        guard !lifecycleSuspended else { throw PhoneCoderRuntimeError.lifecycleUnavailable }
        guard !switching else { throw PhoneCoderRuntimeError.switchingModel }
        let epoch = lifecycleEpoch
        switching = true
        defer {
            switching = false
            let waiters = switchWaiters
            switchWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        modelSession = nil
        let pending = queue
        queue.removeAll()
        pending.forEach { $0.resolve(.failure(PhoneCoderRuntimeError.cancelled)) }
        let draining = worker
        if let request = active?.request {
            await cancel(requestID: request.id, sessionID: request.sessionID)
        }
        await draining?.value
        guard epoch == lifecycleEpoch, !lifecycleSuspended else { throw PhoneCoderRuntimeError.lifecycleUnavailable }
        await runtime.unload()
        guard epoch == lifecycleEpoch, !lifecycleSuspended else { throw PhoneCoderRuntimeError.lifecycleUnavailable }
        try await checkAvailability()
        guard epoch == lifecycleEpoch, !lifecycleSuspended else { throw PhoneCoderRuntimeError.lifecycleUnavailable }
        let session = try await runtime.load(modelID: modelID)
        guard epoch == lifecycleEpoch, !lifecycleSuspended else { throw PhoneCoderRuntimeError.lifecycleUnavailable }
        guard session.modelID == modelID else { throw PhoneCoderRuntimeError.staleSession }
        modelSession = session
        return session
    }

    func unloadModel() async throws {
        guard !lifecycleSuspended else { throw PhoneCoderRuntimeError.lifecycleUnavailable }
        guard !switching else { throw PhoneCoderRuntimeError.switchingModel }
        switching = true
        defer {
            switching = false
            let waiters = switchWaiters
            switchWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        modelSession = nil
        let pending = queue
        queue.removeAll()
        pending.forEach { $0.resolve(.failure(PhoneCoderRuntimeError.cancelled)) }
        let draining = worker
        if let request = active?.request {
            await cancel(requestID: request.id, sessionID: request.sessionID)
        }
        await draining?.value
        await runtime.unload()
    }

    private func checkAvailability() async throws {
        if case .unavailable(let error) = await runtime.liveAvailability() { throw error }
    }

    private func checkLease(_ lease: UUID) throws {
        guard active?.lease == lease, !cancelled, !switching else { throw PhoneCoderRuntimeError.cancelled }
        try active?.request.cancellationSignal?.check()
    }

    private func run(_ work: Work) async {
        let outcome: Result<PhoneCoderGenerationResult, Error>
        do { outcome = .success(try await generate(work)) }
        catch { outcome = .failure(cancelled || work.request.cancellationSignal?.isCancelled == true ? PhoneCoderRuntimeError.cancelled : error) }
        // Native cancellation can itself suspend after generate has returned.
        // Keep the lease until that path has drained too.
        await cancellation?.value
        cancellation = nil
        work.resolve(cancelled || work.request.cancellationSignal?.isCancelled == true ? .failure(PhoneCoderRuntimeError.cancelled) : outcome)
        active = nil
        worker = nil
        if !switching, !lifecycleSuspended, !queue.isEmpty { start(queue.removeFirst()) }
    }

    private func generate(_ work: Work) async throws -> PhoneCoderGenerationResult {
        for attempt in 0...1 {
            do {
                try checkLease(work.lease)
                if attempt == 0, work.request.strictAPI,
                   modelSession?.id != work.request.expectedModelSessionID { throw PhoneCoderRuntimeError.staleSession }
                if attempt > 0, committedOutput { throw PhoneCoderRuntimeError.runtimeFailure }
                try await checkAvailability()
                try checkLease(work.lease)
                if modelSession?.modelID != work.request.modelID {
                    if modelSession != nil {
                        modelSession = nil
                        await runtime.unload()
                        try checkLease(work.lease)
                    }
                    let loaded = try await runtime.load(modelID: work.request.modelID)
                    try checkLease(work.lease)
                    guard loaded.modelID == work.request.modelID else { throw PhoneCoderRuntimeError.staleSession }
                    modelSession = loaded
                }
                if attempt > 0, committedOutput { throw PhoneCoderRuntimeError.runtimeFailure }
                guard let session = modelSession else { throw PhoneCoderRuntimeError.modelUnavailable }
                let result = try await runtime.generate(work.request, session: session) { event in
                    await self.deliver(event, lease: work.lease)
                }
                try checkLease(work.lease)
                guard result.modelSessionID == modelSession?.id,
                      result.requestID == work.request.id, result.sessionID == work.request.sessionID else {
                    throw PhoneCoderRuntimeError.staleSession
                }
                return result
            } catch {
                // Only runtime faults qualify. Admission, cancellation, stale
                // identity, and any committed output permanently forbid retry.
                guard error as? PhoneCoderRuntimeError == .runtimeFailure,
                      attempt == 0, !committedOutput, !cancelled, !switching,
                      work.request.cancellationSignal?.isCancelled != true else { throw error }
                modelSession = nil
                await runtime.unload()
                try checkLease(work.lease)
                guard !committedOutput else { throw error }
                runtime = await reconstruct()
                try checkLease(work.lease)
                guard !committedOutput else { throw error }
            }
        }
        throw PhoneCoderRuntimeError.runtimeFailure
    }

    private func deliver(_ event: PhoneCoderRuntimeEvent, lease: UUID) async {
        guard let work = active, work.lease == lease, !cancelled, !switching,
              work.request.cancellationSignal?.isCancelled != true,
              event.modelSessionID == modelSession?.id,
              event.requestID == work.request.id, event.sessionID == work.request.sessionID else { return }
        // Conservatively committed BEFORE awaiting a consumer/ledger. Even a
        // consumer that fails must never cause already-observed text to retry.
        committedOutput = true
        await work.onEvent(event)
    }
}
