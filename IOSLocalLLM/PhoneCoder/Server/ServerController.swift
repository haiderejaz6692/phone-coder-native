import Combine
import Foundation
import SwiftUI

enum PhoneCoderServerState: Equatable, Sendable {
    case stopped, starting, ready, serving, generating
    case recovering(attempt: Int, retryAt: Date)
    case pausedBackground, coolingDown, lowMemory
    case authenticationError, networkUnavailable, modelUnavailable
}

enum PhoneCoderListenerError: Error, Equatable, Sendable {
    case networkUnavailable, authentication
}

/// Task 6 owns the transport behind this facade. stop() must synchronously
/// close admission, invalidate pending start calls, and signal socket closure.
/// A late start completion must never reactivate a stopped listener. Transport
/// callbacks carry the session passed to start, including connection/failure
/// notifications. Credentials and request payloads never enter this interface.
@MainActor
protocol PhoneCoderServerListening: AnyObject {
    func start(sessionID: UUID) async throws
    func stop()
}

@MainActor
protocol PhoneCoderServingIntentStore: AnyObject {
    var servingRequested: Bool { get set }
}

@MainActor
final class PhoneCoderDefaultsServingIntent: PhoneCoderServingIntentStore {
    private let defaults: UserDefaults
    private let key = "com.haider.phonecoder.servingRequested"
    init(defaults: UserDefaults) { self.defaults = defaults }
    var servingRequested: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

@MainActor
protocol PhoneCoderServerClock: AnyObject {
    var now: Date { get }
    func sleep(seconds: TimeInterval) async throws
}

@MainActor
final class PhoneCoderContinuousServerClock: PhoneCoderServerClock {
    var now: Date { Date() }
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

@MainActor
protocol PhoneCoderInferenceLifecycleControlling: AnyObject {
    func state() async -> PhoneCoderRuntimeState
    /// Signal cancellation promptly; the returned task represents native drain.
    func suspend() -> Task<Void, Never>
    /// Capture the new foreground intent before returning its setup task.
    func resume(sessionID: UUID) -> Task<Bool, Never>
}

/// Adapts the two actor authorities without copying their request state. The
/// small setup chain orders session invalidation; it never waits for native
/// drain, so another lifecycle interruption can invalidate a waiting resume.
@MainActor
final class PhoneCoderInferenceLifecycle: PhoneCoderInferenceLifecycleControlling {
    let coordinator: PhoneCoderInferenceCoordinator
    let ledger: PhoneCoderRequestLedger
    private let signalNativeInterruption: @MainActor () -> Void
    private var epoch: UInt64 = 0
    private var setup: Task<Task<Void, Never>, Never>?

    init(coordinator: PhoneCoderInferenceCoordinator, ledger: PhoneCoderRequestLedger,
         signalNativeInterruption: @escaping @MainActor () -> Void = {}) {
        self.coordinator = coordinator
        self.ledger = ledger
        self.signalNativeInterruption = signalNativeInterruption
    }

    func state() async -> PhoneCoderRuntimeState { await coordinator.state() }

    func suspend() -> Task<Void, Never> {
        epoch &+= 1
        let priorSetup = setup
        let coordinator = coordinator
        let ledger = ledger
        let transition = Task {
            _ = await priorSetup?.value
            let drain = await coordinator.suspendForLifecycle()
            await ledger.cancelAll(reason: .serverStopped)
            // A suspended session cannot accept even a previously unseen ID.
            await ledger.setSessionID(UUID())
            // Close the coordinator queue first: stopping native generation
            // earlier could let its completion admit the next queued request.
            self.signalNativeInterruption()
            return drain
        }
        setup = transition
        return Task {
            let drain = await transition.value
            await drain.value
        }
    }

    func resume(sessionID: UUID) -> Task<Bool, Never> {
        // Supersede old session bookkeeping without suspending the coordinator
        // or invalidating a model switch. This epoch belongs only to the facade.
        epoch &+= 1
        let captured = epoch
        return Task {
            _ = await self.setup?.value
            guard captured == self.epoch else { return false }
            let resume = await self.coordinator.resumeAfterLifecycle()
            guard await resume.value, captured == self.epoch else { return false }
            // Join the same short setup chain as suspension. A later suspend
            // invalidates AFTER this write, even across actor reentrancy.
            let previous = self.setup
            let update = Task {
                _ = await previous?.value
                guard captured == self.epoch else { return Task {} }
                await self.ledger.setSessionID(sessionID)
                return Task {}
            }
            self.setup = update
            _ = await update.value
            return captured == self.epoch
        }
    }
}

/// Intent, lifecycle and displayed status have one owner. Listener callbacks
/// and async health reads are epoch/session guarded. Request terminality stays
/// in the ledger, and foreground return never recreates a generation request.
@MainActor
final class PhoneCoderServerController: ObservableObject {
    @Published private(set) var state: PhoneCoderServerState = .stopped
    @Published private(set) var servingRequested: Bool
    @Published private(set) var sessionID: UUID?
    @Published private(set) var runtimeState: PhoneCoderRuntimeState?

    private let listener: any PhoneCoderServerListening
    private let inference: any PhoneCoderInferenceLifecycleControlling
    private let intent: any PhoneCoderServingIntentStore
    private let clock: any PhoneCoderServerClock
    private let setIdleTimerDisabled: @MainActor (Bool) -> Void
    private var phase: ScenePhase = .inactive
    private var epoch: UInt64 = 0
    private var connectionCount = 0
    private var listening = false
    private var transition: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private let retryDelays: [TimeInterval] = [1, 2, 4]

    init(listener: any PhoneCoderServerListening,
         inference: any PhoneCoderInferenceLifecycleControlling,
         intent: any PhoneCoderServingIntentStore,
         clock: any PhoneCoderServerClock,
         setIdleTimerDisabled: @escaping @MainActor (Bool) -> Void) {
        self.listener = listener
        self.inference = inference
        self.intent = intent
        self.clock = clock
        self.setIdleTimerDisabled = setIdleTimerDisabled
        servingRequested = intent.servingRequested
    }

    @discardableResult
    func startServing() -> Task<Void, Never> {
        setIntent(true)
        guard phase == .active else { return suspend(state: .pausedBackground) }
        if listening || state == .starting { return transition ?? Task {} }
        return beginStart(attempt: 0)
    }

    @discardableResult
    func stopServing() -> Task<Void, Never> {
        setIntent(false)
        return suspend(state: .stopped)
    }

    @discardableResult
    func handle(scenePhase: ScenePhase) -> Task<Void, Never> {
        guard phase != scenePhase else { return transition ?? Task {} }
        phase = scenePhase
        switch scenePhase {
        case .active:
            guard servingRequested else { return resumeForegroundInference(after: transition) }
            return beginStart(attempt: 0)
        case .inactive, .background:
            return suspend(state: servingRequested ? .pausedBackground : .stopped)
        @unknown default:
            return suspend(state: servingRequested ? .pausedBackground : .stopped)
        }
    }

    @discardableResult
    func retryNow() -> Task<Void, Never> {
        guard servingRequested else { return Task {} }
        guard phase == .active else { return suspend(state: .pausedBackground) }
        return beginStart(attempt: 0)
    }

    func updateConnectionCount(_ count: Int, sessionID: UUID) {
        guard self.sessionID == sessionID, listening, phase == .active, servingRequested else { return }
        connectionCount = max(0, count)
        publishActiveState()
    }

    /// Called on runtime/safety changes and by the API before publishing health.
    /// The API must still query coordinator health at generation admission.
    func refreshHealth() async {
        guard listening, phase == .active, servingRequested else { return }
        let captured = epoch
        let health = await inference.state()
        guard captured == epoch, listening, phase == .active, servingRequested else { return }
        runtimeState = health
        switch health.availability {
        case .unavailable(.thermal): await suspend(state: .coolingDown).value
        case .unavailable(.memoryPressure): await suspend(state: .lowMemory).value
        default:
            // Do not cancel a model switch because its model is temporarily
            // unavailable. The running API can still answer health/errors.
            publishActiveState()
        }
    }

    @discardableResult
    /// Authentication here means the listener's own credential store failed.
    /// A client's invalid bearer is an HTTP 401, not a server lifecycle event.
    func listenerFailed(_ error: PhoneCoderListenerError, sessionID: UUID) -> Task<Void, Never> {
        guard self.sessionID == sessionID, phase == .active, servingRequested else { return Task {} }
        return recover(error, attempt: 0)
    }

    private func beginStart(attempt: Int) -> Task<Void, Never> {
        epoch &+= 1
        let captured = epoch
        transition?.cancel()
        retry?.cancel()
        retry = nil
        listener.stop()
        // Foreground listener/session preparation is not a global runtime
        // interruption. In particular, an owner-selected model may be loading.
        listening = false
        connectionCount = 0
        runtimeState = nil
        let session = UUID()
        sessionID = session
        state = .starting
        setIdleTimerDisabled(true)
        let task = Task { [weak self] in
            guard let self, self.isCurrent(captured) else { return }
            guard await self.inference.resume(sessionID: session).value, self.isCurrent(captured) else { return }
            let health = await self.inference.state()
            guard self.isCurrent(captured) else { return }
            self.runtimeState = health
            if let refusal = self.stateForRefusal(health) {
                if refusal == .coolingDown || refusal == .lowMemory {
                    await self.suspend(state: refusal).value
                } else {
                    // Keep a pending model switch alive. The owner can retry
                    // serving once it completes; no listener was started yet.
                    self.sessionID = nil
                    self.state = refusal
                    self.setIdleTimerDisabled(false)
                }
                return
            }
            do {
                try await self.listener.start(sessionID: session)
                guard self.isCurrent(captured) else { return }
                // Model residency may change while the listener starts.
                let currentHealth = await self.inference.state()
                guard self.isCurrent(captured) else { return }
                self.runtimeState = currentHealth
                if let refusal = self.stateForRefusal(currentHealth),
                   refusal == .coolingDown || refusal == .lowMemory {
                    await self.suspend(state: refusal).value
                    return
                }
                // A switch may have begun while listener.start suspended.
                // Keep health reachable and let publishActiveState report the
                // unavailable model until a live health refresh sees recovery.
                self.listening = true
                self.publishActiveState()
            } catch {
                guard self.isCurrent(captured) else { return }
                _ = self.recover(error as? PhoneCoderListenerError ?? .networkUnavailable, attempt: attempt)
            }
        }
        transition = task
        return task
    }

    private func isCurrent(_ captured: UInt64) -> Bool {
        captured == epoch && phase == .active && servingRequested && !Task.isCancelled
    }

    /// Server Stop/failure cancels shared work, but must not disable local Chat
    /// or model selection for the rest of an active scene. Runtime admission
    /// still owns thermal/memory refusals. No listener or request is restarted.
    private func resumeForegroundInference(after drain: Task<Void, Never>?) -> Task<Void, Never> {
        epoch &+= 1
        let captured = epoch
        let task = Task { [weak self] in
            await drain?.value
            guard let self, captured == self.epoch, self.phase == .active,
                  !self.listening, !Task.isCancelled else { return }
            _ = await self.inference.resume(sessionID: UUID()).value
        }
        transition = task
        return task
    }

    private func suspend(state nextState: PhoneCoderServerState) -> Task<Void, Never> {
        epoch &+= 1
        transition?.cancel()
        retry?.cancel()
        retry = nil
        listener.stop()
        listening = false
        connectionCount = 0
        sessionID = nil
        state = nextState
        setIdleTimerDisabled(false)
        let drain = inference.suspend()
        transition = drain
        return phase == .active ? resumeForegroundInference(after: drain) : drain
    }

    private func recover(_ error: PhoneCoderListenerError, attempt: Int) -> Task<Void, Never> {
        if error == .authentication {
            setIntent(false)
            return suspend(state: .authenticationError)
        }
        guard attempt < retryDelays.count else { return suspend(state: .networkUnavailable) }
        let delay = retryDelays[attempt]
        _ = suspend(state: .recovering(attempt: attempt + 1, retryAt: clock.now.addingTimeInterval(delay)))
        let captured = epoch
        let task = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(seconds: delay) }
            catch { return }
            guard self.isCurrent(captured) else { return }
            let start = self.beginStart(attempt: attempt + 1)
            await start.value
        }
        retry = task
        return task
    }

    private func setIntent(_ requested: Bool) {
        servingRequested = requested
        intent.servingRequested = requested
    }

    private func stateForRefusal(_ health: PhoneCoderRuntimeState) -> PhoneCoderServerState? {
        switch health.availability {
        case .unavailable(.thermal): return .coolingDown
        case .unavailable(.memoryPressure): return .lowMemory
        case .unavailable: return .modelUnavailable
        case .available: return health.modelSession == nil ? .modelUnavailable : nil
        }
    }

    private func publishActiveState() {
        guard listening, phase == .active, servingRequested else { return }
        if let health = runtimeState, let refusal = stateForRefusal(health) { state = refusal }
        else if runtimeState?.activeRequestID != nil { state = .generating }
        else { state = connectionCount > 0 ? .serving : .ready }
    }
}
