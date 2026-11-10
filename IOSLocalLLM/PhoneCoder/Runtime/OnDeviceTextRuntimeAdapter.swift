import Foundation

/// A boundary over the integrated service, not another loader. Construction
/// allocates no model; reconstruction reuses the upstream singleton only after
/// the coordinator has awaited its cancellation/unload barrier.
@MainActor
final class OnDeviceTextRuntimeAdapter: PhoneCoderTextRuntime {
    private let service = CodingAssistantService.shared
    private var session: PhoneCoderModelSession?
    private var upstreamSessionID: UUID?
    private var activeRequestID: PhoneCoderRequestID?

    func installedModels() async -> [PhoneCoderModelDescriptor] {
        let catalogIDs = ModelDownloadCenter.shared.models.filter { $0.supportsCategory(.assistant) }
            .map { LocalModelRegistry.assistantSelectionID(for: $0) }
        let ids = Set(AssistantModelCatalog.presets.map(\.id) + catalogIDs)
        return ids.sorted().compactMap { id in
            guard let model = installedTextModel(id) else { return nil }
            return PhoneCoderModelDescriptor(id: model.id, displayName: model.displayName)
        }
    }

    func liveAvailability() async -> PhoneCoderRuntimeAvailability {
        if let refusal = safetyRefusal { return .unavailable(refusal) }
        guard ModelResidency.shared.textRuntimeAvailable,
              await MLXGenerationGate.shared.foregrounded else { return .unavailable(.residencyUnavailable) }
        // A safety/lifecycle unload or selection change invalidates readiness
        // even when the coordinator still holds the old session value.
        if let session, (!service.hasUsableLocalRuntime || service.activeSelectionID != session.modelID
                         || upstreamSessionID != service.runtimeSessionID) {
            return .unavailable(.modelUnavailable)
        }
        return .available
    }

    func load(modelID: String) async throws -> PhoneCoderModelSession {
        if let refusal = safetyRefusal { throw refusal }
        guard ModelResidency.shared.textRuntimeAvailable else { throw PhoneCoderRuntimeError.residencyUnavailable }
        guard let model = installedTextModel(modelID) else { throw PhoneCoderRuntimeError.modelUnavailable }
        switch service.state {
        case .loading, .generating: throw PhoneCoderRuntimeError.residencyUnavailable
        default: break
        }
        // Explicit selection, no preference write, alternate-model fallback,
        // remote execution, or implicit model download.
        await service.switchTo(model, persistAsDefault: false, requireLocalFiles: true)
        if let refusal = service.admissionRefusal {
            throw refusal == .thermal ? PhoneCoderRuntimeError.thermal : .memoryPressure
        }
        if let refusal = safetyRefusal { throw refusal }
        guard service.activeExecutionLocation == .localDownloaded,
              service.activeModel.id == modelID, service.state == .ready, service.hasUsableLocalRuntime else {
            throw PhoneCoderRuntimeError.runtimeFailure
        }
        let loaded = PhoneCoderModelSession(id: UUID(), modelID: modelID)
        session = loaded
        upstreamSessionID = service.runtimeSessionID
        return loaded
    }

    func generate(_ request: PhoneCoderGenerationRequest, session: PhoneCoderModelSession,
                  onEvent: @escaping @Sendable (PhoneCoderRuntimeEvent) async -> Void) async throws -> PhoneCoderGenerationResult {
        guard self.session == session, request.modelID == session.modelID else { throw PhoneCoderRuntimeError.staleSession }
        guard activeRequestID == nil else { throw PhoneCoderRuntimeError.runtimeFailure }
        guard request.messages.allSatisfy({ $0.imageThumbnailData == nil && $0.imageThumbnails.isEmpty }) else {
            throw PhoneCoderRuntimeError.modelUnavailable
        }
        if case .unavailable(let refusal) = await liveAvailability() { throw refusal }
        guard service.state == .ready, service.activeExecutionLocation == .localDownloaded else {
            throw PhoneCoderRuntimeError.modelUnavailable
        }
        activeRequestID = request.id
        defer { activeRequestID = nil }
        let (stream, continuation) = AsyncThrowingStream<NativeEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let emit: @Sendable (NativeEvent) -> Void = { event in
            if case .dropped = continuation.yield(event) {
                continuation.finish(throwing: PhoneCoderRuntimeError.runtimeFailure)
            }
        }
        // Callbacks synchronously enqueue into one stream. Creating a Task per
        // token would reorder tokens and allow completion to overtake output.
        service.generate(messages: request.messages, maxTokensOverride: request.maxTokens,
                         temperatureOverride: request.temperature, topPOverride: request.topP,
                         onToken: { emit(.text($0)) },
                         onGenerationResult: { emit(.result($0)) },
                         onComplete: { _ in continuation.finish() })
        var result: AssistantGenerationResult?
        do {
            for try await event in stream {
                if let refusal = safetyRefusal { throw refusal }
                // Safety/image/lifecycle teardown may originate outside this
                // adapter. Its synchronous epoch invalidation precedes cleanup.
                guard upstreamSessionID == service.runtimeSessionID,
                      service.hasUsableLocalRuntime,
                      ModelResidency.shared.textRuntimeAvailable else {
                    throw PhoneCoderRuntimeError.staleSession
                }
                switch event {
                case .text(let text):
                    await onEvent(.init(requestID: request.id, sessionID: request.sessionID,
                                        modelSessionID: session.id, text: text))
                case .result(let value): result = value
                }
            }
        } catch {
            await service.cancelAndDrainInference()
            throw error
        }
        await service.drainGeneration()
        if let refusal = safetyRefusal { throw refusal }
        guard upstreamSessionID == service.runtimeSessionID else { throw PhoneCoderRuntimeError.staleSession }
        guard let result else { throw PhoneCoderRuntimeError.runtimeFailure }
        guard result.stopReason != .cancelled else { throw PhoneCoderRuntimeError.cancelled }
        return PhoneCoderGenerationResult(requestID: request.id, sessionID: request.sessionID,
                                          modelSessionID: session.id, promptTokens: result.promptTokenCount,
                                          completionTokens: result.completionTokenCount,
                                          finishReason: result.stopReason == .length ? .length : .stop)
    }

    func cancel(requestID: PhoneCoderRequestID) async {
        guard activeRequestID == requestID else { return }
        await service.cancelAndDrainInference()
    }

    func unload() async {
        session = nil
        upstreamSessionID = nil
        await service.cancelAndDrainInference()
        await service.unloadAndWaitForCleanup()
    }

    private var safetyRefusal: PhoneCoderRuntimeError? {
        if DeviceSafetyMonitor.shared.thermalState == .critical { return .thermal }
        switch DeviceSafetyMonitor.shared.stopReason {
        case .thermal: return .thermal
        case .memoryPressure: return .memoryPressure
        case nil: return nil
        }
    }

    private func installedTextModel(_ id: String) -> AssistantModel? {
        guard let model = AssistantModelCatalog.selection(forStoredID: id),
              !model.supportsVision, !DualRoleModelPolicy.isTextAndVision(repoID: model.repoID),
              let directory = CodingAssistantService.preStagedDirectory(for: model),
              LocalModelFileValidator.ggufProjector(in: directory) == nil else { return nil }
        return model
    }

    private enum NativeEvent: Sendable {
        case text(String)
        case result(AssistantGenerationResult)
    }
}
