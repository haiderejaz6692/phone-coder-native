import Foundation

enum PhoneCoderWireFailure {
    static func map(_ error: Error) -> PhoneCoderHTTPFailure {
        if let error = error as? PhoneCoderHTTPFailure { return error }
        if let error = error as? LocalAPIStrictBudgetError {
            var value = PhoneCoderAPIError(code: error.code, message: "The requested prompt and output do not fit the selected model's effective limits.")
            value.details = ["prompt_tokens": error.promptTokens, "requested_output_tokens": error.outputTokens, "context_window": error.contextWindow]
            return PhoneCoderHTTPFailure(status: 400, error: value)
        }
        if let error = error as? PhoneCoderAPIError {
            let status: Int
            switch error.code {
            case "request_conflict": status = 409
            case "replay_expired": status = 410
            case "request_not_found": status = 404
            case "subscriber_limit", "queue_full": status = 429
            case "body_too_large": status = 413
            case "stale_session", "request_finished": status = 409
            case "runtime_failure", "invalid_tool_output": status = 502
            default: status = 400
            }
            return PhoneCoderHTTPFailure(status: status, error: error)
        }
        let code: String
        let status: Int
        switch error as? PhoneCoderRuntimeError {
        case .queueFull: code = "queue_full"; status = 429
        case .duplicateRequest: code = "request_conflict"; status = 409
        case .cancelled: code = "request_cancelled"; status = 409
        case .switchingModel: code = "model_switching"; status = 503
        case .lifecycleUnavailable: code = "background_interrupted"; status = 503
        case .modelUnavailable: code = "model_unavailable"; status = 503
        case .residencyUnavailable: code = "runtime_occupied"; status = 503
        case .memoryPressure: code = "memory_pressure"; status = 503
        case .thermal: code = "thermal_limit"; status = 503
        case .staleSession: code = "stale_session"; status = 409
        case .outputLimit: code = "output_limit"; status = 413
        case .runtimeFailure, nil: code = "runtime_failure"; status = 502
        }
        return .init(status, code, "The request ended: \(code).")
    }

    static func terminal(_ terminal: PhoneCoderTerminalResult) -> PhoneCoderAPIError? {
        switch terminal {
        case .completed: return nil
        case .failed(let error): return error
        case .cancelled(let reason):
            let code: String
            switch reason {
            case .client: code = "request_cancelled"
            case .deadline: code = "deadline_exceeded"
            case .outputLimit: code = "output_limit"
            case .sessionEnded: code = "session_ended"
            case .serverStopped: code = "background_interrupted"
            }
            return .init(code: code, message: "The request ended: \(code). Submit a new request ID to start new work.")
        }
    }

    static func data(_ error: PhoneCoderAPIError) -> Data {
        var value: [String: Any] = ["code": error.code, "message": error.message]
        if let details = error.details { value["details"] = details }
        return (try? JSONSerialization.data(withJSONObject: ["error": value], options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

extension PhoneCoderHTTPFailure {
    init(status: Int, error: PhoneCoderAPIError) { self.status = status; self.error = error }
}

enum PhoneCoderDecodedRequest: Sendable {
    case chat(PhoneCoderChatRequest)
    case responses(PhoneCoderResponsesRequest)
    var model: String { switch self { case .chat(let r): r.model; case .responses(let r): r.model } }
    var stream: Bool { switch self { case .chat(let r): r.stream; case .responses(let r): r.stream } }
    var includeUsage: Bool { switch self { case .chat(let r): r.streamIncludeUsage; case .responses(let r): r.streamIncludeUsage } }
    var stops: [String] { switch self { case .chat(let r): r.stop; case .responses(let r): r.stop } }
    var tools: [LocalAPIToolDefinition] { if case .responses(let r) = self, r.toolChoice != .none { return r.tools }; return [] }
    var toolChoice: LocalAPIToolChoice { if case .responses(let r) = self { return r.toolChoice }; return .none }
    var isResponses: Bool { if case .responses = self { return true }; return false }

    func generation(id: PhoneCoderRequestID, sessionID: UUID, modelSession: PhoneCoderModelSession, parser: ModelToolParser) -> PhoneCoderGenerationRequest {
        var request: PhoneCoderGenerationRequest
        switch self {
        case .chat(let r):
            request = .init(id: id, sessionID: sessionID, modelID: modelSession.modelID, messages: r.messages,
                            maxTokens: r.maxTokens, temperature: r.temperature, topP: r.topP)
        case .responses(let r):
            let prepared = LocalAPIToolCalling.messages(from: r.messages, tools: r.tools, choice: r.toolChoice,
                                                       parallelToolCalls: true, parser: parser)
            request = .init(id: id, sessionID: sessionID, modelID: modelSession.modelID, messages: prepared,
                            maxTokens: r.maxTokens, temperature: r.temperature, topP: r.topP)
        }
        request.strictAPI = true
        request.expectedModelSessionID = modelSession.id
        return request
    }

    func terminalEvents(_ terminal: PhoneCoderTerminalResult) -> [PhoneCoderStreamEvent] {
        guard let error = PhoneCoderWireFailure.terminal(terminal) else { return [] }
        return [isResponses ? .responseError(error) : .error(error), .done]
    }
}

/// Retain only a possible stop prefix between chunks. Strings are already
/// decoded by the runtime, so no transport byte slicing can corrupt Unicode.
struct PhoneCoderStopBuffer {
    let stops: [String]
    private var pending = ""
    private(set) var stopped = false
    mutating func consume(_ text: String) -> String {
        guard !stopped else { return "" }
        pending += text
        if let first = stops.compactMap({ pending.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let visible = String(pending[..<first.lowerBound])
            pending = ""; stopped = true
            return visible
        }
        var held = 0
        for stop in stops where stop.count > 1 {
            for length in 1..<stop.count where length <= pending.count {
                if pending.hasSuffix(String(stop.prefix(length))) { held = max(held, length) }
            }
        }
        let visible = String(pending.dropLast(held))
        pending = String(pending.suffix(held))
        return visible
    }
    mutating func finish() -> String { let value = pending; pending = ""; return value }
}

/// One bounded, memory-only result assembly per execution owner. The ledger
/// alone retains replay events and completed response bodies.
actor PhoneCoderResponsePipeline {
    private let request: PhoneCoderDecodedRequest
    private let generation: PhoneCoderGenerationRequest
    private let preflight: PhoneCoderRuntimePreflight
    private let parser: ModelToolParser
    private let client: PhoneCoderAuthContext
    private let ledger: PhoneCoderRequestLedger
    private let coordinator: PhoneCoderInferenceCoordinator
    private let activity: PhoneCoderServerActivityStore
    private let context: PhoneCoderCompletionContext
    private let startedAt = Date()
    private let maximumTextBytes = 262_144
    private var buffer: PhoneCoderStopBuffer
    private var text = ""
    private var started = false
    private var textStarted = false
    private var ended = false
    private var failure: PhoneCoderAPIError?

    init(request: PhoneCoderDecodedRequest, generation: PhoneCoderGenerationRequest,
         preflight: PhoneCoderRuntimePreflight, parser: ModelToolParser, client: PhoneCoderAuthContext,
         ledger: PhoneCoderRequestLedger, coordinator: PhoneCoderInferenceCoordinator,
         activity: PhoneCoderServerActivityStore) {
        self.request = request; self.generation = generation; self.preflight = preflight
        self.parser = parser; self.client = client; self.ledger = ledger
        self.coordinator = coordinator; self.activity = activity
        context = .init(id: generation.id.rawValue, model: request.model, created: Int(Date().timeIntervalSince1970))
        buffer = PhoneCoderStopBuffer(stops: request.stops)
    }

    func consume(_ event: PhoneCoderRuntimeEvent) async {
        guard !ended, failure == nil, event.requestID == generation.id,
              event.sessionID == generation.sessionID, !buffer.stopped else { return }
        do {
            let visible = buffer.consume(event.text)
            guard text.utf8.count + visible.utf8.count <= maximumTextBytes else { throw PhoneCoderRuntimeError.outputLimit }
            text += visible
            if request.stream {
                try await ensureStarted()
                if request.tools.isEmpty { try await emitText(visible) }
            }
            if buffer.stopped {
                // Do not await cancellation from a callback that the native
                // worker itself is awaiting. Completion remains ledger-owned.
                let id = generation.id, session = generation.sessionID, coordinator = coordinator
                Task { await coordinator.cancel(requestID: id, sessionID: session) }
            }
        } catch {
            failure = PhoneCoderWireFailure.map(error).error
            let id = generation.id, session = generation.sessionID, coordinator = coordinator
            Task { await coordinator.cancel(requestID: id, sessionID: session) }
        }
    }

    func finish(_ outcome: Result<PhoneCoderGenerationResult, Error>) async {
        guard !ended else { return }; ended = true
        var usage = PhoneCoderUsage(inputTokens: preflight.prompt.tokens, outputTokens: 0)
        var category: PhoneCoderActivityTerminal = .runtimeFailure
        do {
            if let failure { throw failure }
            let finish: PhoneCoderFinishReason
            switch outcome {
            case .success(let result):
                usage = .init(inputTokens: result.promptTokens, outputTokens: result.completionTokens)
                finish = buffer.stopped ? .stop : result.finishReason
            case .failure(let error):
                guard buffer.stopped, error as? PhoneCoderRuntimeError == .cancelled else { throw error }
                // A client-specified stop can preempt backend final metadata.
                // The transport labels this usage as a conservative bound.
                usage = .init(inputTokens: preflight.prompt.tokens, outputTokens: text.utf8.count)
                finish = .stop
            }
            let suffix = buffer.finish()
            guard text.utf8.count + suffix.utf8.count <= maximumTextBytes else { throw PhoneCoderRuntimeError.outputLimit }
            text += suffix
            if request.stream {
                try await ensureStarted()
                if request.tools.isEmpty { try await emitText(suffix) }
            }
            var output: [PhoneCoderResponseItem] = []
            var finalEvents: [PhoneCoderStreamEvent] = []
            if request.isResponses {
                if !request.tools.isEmpty {
                    let parsed = LocalAPIToolCalling.parseResult(text, tools: request.tools, parallelToolCalls: true,
                        validateSchemas: true, parser: parser, maximumCalls: 4, attemptRepair: false, strictPrivacy: true)
                    guard parsed.failure == nil, request.toolChoice != .required || !parsed.calls.isEmpty else {
                        throw PhoneCoderAPIError(code: "invalid_tool_output", message: "The model did not produce a valid declared function call.")
                    }
                    if !parsed.calls.isEmpty {
                        for (index, call) in parsed.calls.enumerated() {
                            let itemID = "fc_\(context.id)_\(index)"
                            let item = PhoneCoderResponseItem.function(id: itemID, callID: call.id, name: call.name, arguments: call.argumentsJSON)
                            output.append(item)
                            if request.stream {
                                finalEvents.append(.responseFunctionAdded(context, itemID: itemID, outputIndex: index, callID: call.id, name: call.name))
                                // One atomic terminal batch must fit the ledger's
                                // bounded subscriber/replay ring (256 events).
                                for fragment in LocalAPIServer.fragmented(call.argumentsJSON, chunkSize: 8192) {
                                    finalEvents.append(.responseFunctionArgumentsDelta(context, itemID: itemID, outputIndex: index, delta: fragment))
                                }
                                finalEvents.append(.responseFunctionArgumentsDone(context, itemID: itemID, outputIndex: index, arguments: call.argumentsJSON))
                                finalEvents.append(.responseItemDone(context, outputIndex: index, item: item))
                            }
                        }
                    }
                }
                if output.isEmpty {
                    let item = PhoneCoderResponseItem.message(id: messageID, text: text)
                    output = [item]
                    if request.stream {
                        if !request.tools.isEmpty { try await emitText(text) }
                        if !textStarted { try await emitText("", forceStart: true) }
                        finalEvents += [.responseTextDone(context, itemID: messageID, outputIndex: 0, contentIndex: 0, text: text),
                            .responseContentPartDone(context, itemID: messageID, outputIndex: 0, contentIndex: 0, text: text),
                            .responseItemDone(context, outputIndex: 0, item: item)]
                    }
                }
                if request.stream { finalEvents.append(.responseCompleted(context, usage: usage, output: output)) }
            } else if request.stream {
                finalEvents.append(.chatFinish(context, finish))
                if request.includeUsage { finalEvents.append(.chatUsage(context, usage)) }
            }
            finalEvents.append(.done)
            let body: Data? = request.stream ? nil : (request.isResponses
                ? try PhoneCoderAPIEncoder.responsesCompletion(context: context, output: output, usage: usage)
                : try PhoneCoderAPIEncoder.chatCompletion(context: context, text: text, finish: finish, usage: usage))
            await coordinator.markOutputCommitted(requestID: generation.id, sessionID: generation.sessionID)
            try await ledger.finish(id: generation.id, terminal: .completed, sessionID: generation.sessionID,
                                    finalEvents: finalEvents, responseBody: body)
            category = .completed
        } catch {
            let error = PhoneCoderWireFailure.map(error).error
            await coordinator.markOutputCommitted(requestID: generation.id, sessionID: generation.sessionID)
            try? await ledger.finish(id: generation.id, terminal: .failed(error), sessionID: generation.sessionID)
        }
        if let terminal = try? await ledger.terminal(id: generation.id, ownerClientID: client.id) {
            category = Self.category(terminal)
        }
        try? await activity.record(.init(clientID: client.id, clientName: client.name, modelID: generation.modelID,
            startedAt: startedAt, endedAt: Date(), inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens, terminal: category))
        text = ""
    }

    private var messageID: String { "msg_" + context.id }
    private func ensureStarted() async throws {
        guard !started else { return }; started = true
        if request.isResponses {
            try await emit(.responseCreated(context)); try await emit(.responseInProgress(context))
        } else { try await emit(.chatStart(context)) }
    }
    private func emitText(_ value: String, forceStart: Bool = false) async throws {
        guard !value.isEmpty || forceStart else { return }
        if request.isResponses {
            if !textStarted {
                textStarted = true
                try await emit(.responseMessageAdded(context, itemID: messageID, outputIndex: 0))
                try await emit(.responseContentPartAdded(context, itemID: messageID, outputIndex: 0, contentIndex: 0))
            }
            if !value.isEmpty { try await emit(.responseTextDelta(context, itemID: messageID, outputIndex: 0, contentIndex: 0, delta: value)) }
        } else if !value.isEmpty { try await emit(.chatText(context, value)) }
    }
    private func emit(_ event: PhoneCoderStreamEvent) async throws {
        await coordinator.markOutputCommitted(requestID: generation.id, sessionID: generation.sessionID)
        _ = try await ledger.append(id: generation.id, event: event, sessionID: generation.sessionID)
    }
    private static func category(_ terminal: PhoneCoderTerminalResult) -> PhoneCoderActivityTerminal {
        switch terminal {
        case .completed: return .completed
        case .cancelled(let reason):
            switch reason { case .client: return .cancelled; case .deadline: return .deadline; case .outputLimit: return .outputLimit; case .sessionEnded, .serverStopped: return .serverStopped }
        case .failed(let error):
            switch error.code { case "thermal_limit": return .thermal; case "memory_pressure": return .memoryPressure; case "model_unavailable": return .modelUnavailable; case "invalid_tool_output": return .invalidOutput; case "output_limit": return .outputLimit; default: return .runtimeFailure }
        }
    }
}
