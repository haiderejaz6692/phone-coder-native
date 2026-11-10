import Foundation

/// A boundary over the integrated service, not another loader. Construction
/// allocates no model; reconstruction reuses the upstream singleton only after
/// the coordinator has awaited its cancellation/unload barrier.
@MainActor
final class OnDeviceTextRuntimeAdapter: PhoneCoderTextRuntime {
    private let service = CodingAssistantService.shared
    private let residency: ModelResidency

    init(residency: ModelResidency = .shared) { self.residency = residency }
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
        let foregrounded = await MLXGenerationGate.shared.foregrounded
        let usable = session.map {
            service.hasUsableLocalRuntime && service.activeSelectionID == $0.modelID
                && upstreamSessionID == service.runtimeSessionID
        } ?? true
        return PhoneCoderRuntimeMapping.availability(thermal: DeviceSafetyMonitor.shared.thermalState,
            stopReason: DeviceSafetyMonitor.shared.stopReason,
            textResidencyAvailable: residency.textRuntimeAvailable,
            foregrounded: foregrounded, sessionIsUsable: usable)
    }

    func load(modelID: String) async throws -> PhoneCoderModelSession {
        if let refusal = safetyRefusal { throw refusal }
        guard residency.textRuntimeAvailable else { throw PhoneCoderRuntimeError.residencyUnavailable }
        guard let model = installedTextModel(modelID) else { throw PhoneCoderRuntimeError.modelUnavailable }
        switch service.state {
        case .loading, .generating: throw PhoneCoderRuntimeError.residencyUnavailable
        default: break
        }
        // Explicit selection, no preference write, alternate-model fallback,
        // remote execution, or implicit model download.
        await service.switchTo(model, persistAsDefault: false, requireLocalFiles: true)
        if let refusal = service.admissionRefusal {
            switch refusal {
            case .thermal: throw PhoneCoderRuntimeError.thermal
            case .memory: throw PhoneCoderRuntimeError.memoryPressure
            case .residency: throw PhoneCoderRuntimeError.residencyUnavailable
            }
        }
        if let refusal = safetyRefusal { throw refusal }
        guard residency.textRuntimeAvailable else { throw PhoneCoderRuntimeError.residencyUnavailable }
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
        try request.cancellationSignal?.check()
        guard self.session == session, request.modelID == session.modelID else { throw PhoneCoderRuntimeError.staleSession }
        guard activeRequestID == nil else { throw PhoneCoderRuntimeError.residencyUnavailable }
        guard request.messages.allSatisfy({ $0.imageThumbnailData == nil && $0.imageThumbnails.isEmpty }) else {
            throw PhoneCoderRuntimeError.modelUnavailable
        }
        if case .unavailable(let refusal) = await liveAvailability() { throw refusal }
        guard service.state == .ready, service.activeExecutionLocation == .localDownloaded else {
            throw PhoneCoderRuntimeError.modelUnavailable
        }
        if request.strictAPI { _ = try await preflight(request, session: session) }
        activeRequestID = request.id
        defer { activeRequestID = nil }
        let (stream, continuation) = AsyncThrowingStream<NativeEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let emit: @Sendable (NativeEvent) -> Void = { event in
            if case .dropped = continuation.yield(event) {
                continuation.finish(throwing: PhoneCoderRuntimeError.outputLimit)
            }
        }
        // Callbacks synchronously enqueue into one stream. Creating a Task per
        // token would reorder tokens and allow completion to overtake output.
        // No MainActor suspension separates this check from native admission.
        try request.cancellationSignal?.check()
        service.generate(messages: request.messages, maxTokensOverride: request.maxTokens,
                         temperatureOverride: request.temperature, topPOverride: request.topP,
                         strictLocalAPI: request.strictAPI,
                         onToken: { emit(.text($0)) },
                         onTerminal: { emit(.terminal($0)) },
                         onComplete: { _ in continuation.finish() })
        var terminal: AssistantGenerationOutcome?
        do {
            for try await event in stream {
                // Terminal categories survive teardown; only text callbacks
                // require a still-resident runtime before reaching consumers.
                if case .terminal(let outcome) = event {
                    terminal = outcome
                    continue
                }
                if let refusal = safetyRefusal { throw refusal }
                // Safety/image/lifecycle teardown may originate outside this
                // adapter. Its synchronous epoch invalidation precedes cleanup.
                guard upstreamSessionID == service.runtimeSessionID,
                      service.hasUsableLocalRuntime,
                      residency.textRuntimeAvailable else {
                    throw PhoneCoderRuntimeError.staleSession
                }
                switch event {
                case .text(let text):
                    await onEvent(.init(requestID: request.id, sessionID: request.sessionID,
                                        modelSessionID: session.id, text: text))
                case .terminal: break
                }
            }
        } catch {
            await service.cancelAndDrainInference()
            throw error
        }
        await service.drainGeneration()
        let result = try PhoneCoderRuntimeMapping.result(from: terminal ?? .unavailable)
        if let refusal = safetyRefusal { throw refusal }
        guard upstreamSessionID == service.runtimeSessionID else { throw PhoneCoderRuntimeError.staleSession }
        return PhoneCoderGenerationResult(requestID: request.id, sessionID: request.sessionID,
                                          modelSessionID: session.id, promptTokens: result.promptTokenCount,
                                          completionTokens: result.completionTokenCount,
                                          finishReason: result.stopReason == .length ? .length : .stop)
    }

    func cancel(requestID: PhoneCoderRequestID) async {
        guard activeRequestID == requestID else { return }
        await service.cancelAndDrainInference()
    }

    func capabilities(session: PhoneCoderModelSession) async throws -> PhoneCoderRuntimeCapabilities {
        guard self.session == session, upstreamSessionID == service.runtimeSessionID,
              service.hasUsableLocalRuntime else { throw PhoneCoderRuntimeError.staleSession }
        return .init(limits: service.localAPIStrictRuntimeLimits,
                     toolParser: ModelCapabilityProfile.resolve(for: service.activeModel).toolParser)
    }

    func preflight(_ request: PhoneCoderGenerationRequest, session: PhoneCoderModelSession) async throws -> PhoneCoderRuntimePreflight {
        let capabilities = try await capabilities(session: session)
        if case .unavailable(let error) = await liveAvailability() { throw error }
        let prompt = service.localAPIStrictPromptBound(messages: request.messages)
        let output = try LocalAPIStrictInput.outputTokens(requested: request.maxTokens, promptTokens: prompt.tokens, limits: capabilities.limits)
        return .init(prompt: prompt, limits: capabilities.limits, outputTokens: output)
    }

    func unload() async {
        session = nil
        upstreamSessionID = nil
        await service.cancelAndDrainInference()
        await service.unloadAndWaitForCleanup()
    }

    private var safetyRefusal: PhoneCoderRuntimeError? {
        PhoneCoderRuntimeMapping.safetyRefusal(thermal: DeviceSafetyMonitor.shared.thermalState,
                                              stopReason: DeviceSafetyMonitor.shared.stopReason)
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
        case terminal(AssistantGenerationOutcome)
    }
}

/// Production mapping seam: tests supply actual upstream outcome/state types,
/// not preclassified Phone Coder errors or fabricated health flags.
enum PhoneCoderRuntimeMapping {
    static func result(from outcome: AssistantGenerationOutcome) throws -> AssistantGenerationResult {
        switch outcome {
        case .completed(let result):
            guard result.stopReason != .cancelled else { throw PhoneCoderRuntimeError.cancelled }
            return result
        case .cancelled: throw PhoneCoderRuntimeError.cancelled
        case .memoryPressure: throw PhoneCoderRuntimeError.memoryPressure
        case .thermal: throw PhoneCoderRuntimeError.thermal
        case .unavailable: throw PhoneCoderRuntimeError.modelUnavailable
        case .failed: throw PhoneCoderRuntimeError.runtimeFailure
        case .rejected(let error): throw error
        }
    }

    static func safetyRefusal(thermal: ProcessInfo.ThermalState,
                              stopReason: DeviceSafetyMonitor.StopReason?) -> PhoneCoderRuntimeError? {
        if thermal == .critical { return .thermal }
        switch stopReason {
        case .thermal: return .thermal
        case .memoryPressure: return .memoryPressure
        case nil: return nil
        }
    }

    static func availability(thermal: ProcessInfo.ThermalState, stopReason: DeviceSafetyMonitor.StopReason?,
                             textResidencyAvailable: Bool, foregrounded: Bool,
                             sessionIsUsable: Bool) -> PhoneCoderRuntimeAvailability {
        if let refusal = safetyRefusal(thermal: thermal, stopReason: stopReason) { return .unavailable(refusal) }
        guard textResidencyAvailable, foregrounded else { return .unavailable(.residencyUnavailable) }
        guard sessionIsUsable else { return .unavailable(.modelUnavailable) }
        return .available
    }
}
