import Foundation

/// One signal per admission, with no registry or retained payload. The lock
/// gives cancellation a synchronous happens-before edge across actor hops.
final class PhoneCoderRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { if isCancelled { throw PhoneCoderRuntimeError.cancelled } }
}

struct PhoneCoderModelDescriptor: Equatable, Sendable {
    let id: String
    let displayName: String
}

struct PhoneCoderModelSession: Equatable, Sendable {
    let id: UUID
    let modelID: String
}

/// A text-only runtime request, after wire/tool prompt adaptation. The server
/// owns stop-sequence filtering and tool decoding; native options stay values.
struct PhoneCoderGenerationRequest: Sendable {
    let id: PhoneCoderRequestID
    /// Captured ledger/session identity, never read from mutable global state.
    let sessionID: UUID
    let modelID: String
    let messages: [ChatMessage]
    var maxTokens: Int? = nil
    var temperature: Double? = nil
    var topP: Double? = nil
    var strictAPI = false
    var expectedModelSessionID: UUID? = nil
    var cancellationSignal: PhoneCoderRequestCancellation? = nil
}

struct PhoneCoderRuntimeCapabilities: Sendable {
    let limits: LocalAPIRuntimeLimits
    let toolParser: ModelToolParser
}

struct PhoneCoderRuntimePreflight: Sendable {
    let prompt: LocalAPITokenCount
    let limits: LocalAPIRuntimeLimits
    let outputTokens: Int
}

struct PhoneCoderRuntimeEvent: Equatable, Sendable {
    let requestID: PhoneCoderRequestID
    let sessionID: UUID
    let modelSessionID: UUID
    let text: String
}

struct PhoneCoderGenerationResult: Equatable, Sendable {
    let requestID: PhoneCoderRequestID
    let sessionID: UUID
    let modelSessionID: UUID
    let promptTokens: Int
    let completionTokens: Int
    let finishReason: PhoneCoderFinishReason
}

enum PhoneCoderRuntimeError: Error, Equatable, Sendable {
    case queueFull, duplicateRequest, cancelled, switchingModel, lifecycleUnavailable
    case modelUnavailable, residencyUnavailable, memoryPressure, thermal
    case runtimeFailure, staleSession, outputLimit
}

enum PhoneCoderRuntimeAvailability: Equatable, Sendable {
    case available
    case unavailable(PhoneCoderRuntimeError)
}

struct PhoneCoderRuntimeState: Equatable, Sendable {
    let availability: PhoneCoderRuntimeAvailability
    let modelSession: PhoneCoderModelSession?
    let activeRequestID: PhoneCoderRequestID?
    let waitingCount: Int
    let switchingModel: Bool
}

/// Integrated runtimes must keep admission, native serialization, cancellation,
/// and unload in their upstream owner. Returning from generate/cancel/unload
/// means its native work has drained. Callbacks are ordered and awaited before
/// generate returns; every event and result carries the captured identities.
protocol PhoneCoderTextRuntime: Sendable {
    func installedModels() async -> [PhoneCoderModelDescriptor]
    func liveAvailability() async -> PhoneCoderRuntimeAvailability
    func load(modelID: String) async throws -> PhoneCoderModelSession
    func generate(_ request: PhoneCoderGenerationRequest, session: PhoneCoderModelSession,
                  onEvent: @escaping @Sendable (PhoneCoderRuntimeEvent) async -> Void) async throws -> PhoneCoderGenerationResult
    func cancel(requestID: PhoneCoderRequestID) async
    func unload() async
    func capabilities(session: PhoneCoderModelSession) async throws -> PhoneCoderRuntimeCapabilities
    func preflight(_ request: PhoneCoderGenerationRequest, session: PhoneCoderModelSession) async throws -> PhoneCoderRuntimePreflight
}

extension PhoneCoderTextRuntime {
    func capabilities(session: PhoneCoderModelSession) async throws -> PhoneCoderRuntimeCapabilities { throw PhoneCoderRuntimeError.modelUnavailable }
    func preflight(_ request: PhoneCoderGenerationRequest, session: PhoneCoderModelSession) async throws -> PhoneCoderRuntimePreflight { throw PhoneCoderRuntimeError.modelUnavailable }
}
