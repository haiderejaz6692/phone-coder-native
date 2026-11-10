import Combine
import CryptoKit
import Foundation
import Network

struct PhoneCoderDeviceFacts: Sendable {
    var availableMemoryBytes: UInt64 = 0
    var thermal = "unknown"
}

actor PhoneCoderAPIServer {
    enum AdmissionCheckpoint: CaseIterable, Equatable, Sendable { case ledgerBegan, beforeEnqueue, enqueued }
    enum Event: Sendable {
        case connections(Int, sessionID: UUID)
        case failed(PhoneCoderListenerError, sessionID: UUID)
        case activity(sessionID: UUID)
    }
    nonisolated let gate = PhoneCoderTransportGate()
    private let coordinator: PhoneCoderInferenceCoordinator
    private let ledger: PhoneCoderRequestLedger
    private let pairings: PhoneCoderPairingStore
    private let exchange: PhoneCoderPairingExchange
    private let activity: PhoneCoderServerActivityStore
    private let limits: PhoneCoderHTTPLimits
    private let approval: @MainActor @Sendable (String) async -> Bool
    private let deviceFacts: @MainActor @Sendable () -> PhoneCoderDeviceFacts
    private let admissionCheckpoint: @Sendable (AdmissionCheckpoint) async -> Void
    private var listener: NWListener?
    private var sessionID: UUID?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var startTimeout: Task<Void, Never>?
    private var connections: [UUID: Task<Void, Never>] = [:]
    private struct Job {
        let sessionID: UUID
        let owner: UUID
        let fingerprint: SHA256.Digest
        let admission: Task<Void, Error>
        let cancellationSignal: PhoneCoderRequestCancellation
        var cancellation: PhoneCoderCancellationReason?
        var task: Task<Void, Never>?
        let deadline: Task<Void, Never>
    }
    private var jobs: [PhoneCoderRequestID: Job] = [:]
    private var onEvent: (@Sendable (Event) -> Void)?

    init(coordinator: PhoneCoderInferenceCoordinator, ledger: PhoneCoderRequestLedger,
         pairings: PhoneCoderPairingStore, exchange: PhoneCoderPairingExchange,
         activity: PhoneCoderServerActivityStore, limits: PhoneCoderHTTPLimits = .init(),
         approval: @escaping @MainActor @Sendable (String) async -> Bool,
         deviceFacts: @escaping @MainActor @Sendable () -> PhoneCoderDeviceFacts = { .init() },
         admissionCheckpoint: @escaping @Sendable (AdmissionCheckpoint) async -> Void = { _ in }) {
        self.coordinator = coordinator; self.ledger = ledger; self.pairings = pairings
        self.exchange = exchange; self.activity = activity; self.limits = limits
        self.approval = approval; self.deviceFacts = deviceFacts
        self.admissionCheckpoint = admissionCheckpoint
    }

    func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) { onEvent = handler }

    /// The MainActor adapter opens the synchronous gate before this actor hop.
    /// A stopped or superseded hop can therefore never reopen a listener.
    func start(port: UInt16, sessionID: UUID) async throws -> UInt16 {
        guard gate.isOpen(sessionID) else { throw PhoneCoderHTTPFailure.closed }
        if let oldSession = self.sessionID, oldSession != sessionID { stop(sessionID: oldSession) }
        guard listener == nil else { throw PhoneCoderHTTPFailure.closed }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        let value = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        guard gate.install(value, sessionID: sessionID) else { throw PhoneCoderHTTPFailure.closed }
        self.sessionID = sessionID; listener = value
        value.stateUpdateHandler = { [weak self] state in Task { await self?.listenerChanged(state, sessionID: sessionID) } }
        value.newConnectionHandler = { [weak self, gate, limits] connection in
            guard gate.admit(connection, sessionID: sessionID, limit: limits.connections) else { return }
            Task { await self?.accept(connection, sessionID: sessionID) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                startTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    await self?.startExpired(sessionID: sessionID)
                }
                value.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: { [gate] in gate.close(sessionID: sessionID) }
    }

    func stop(sessionID: UUID? = nil) {
        guard sessionID == nil || self.sessionID == sessionID else { return }
        let oldSession = self.sessionID
        gate.close(sessionID: oldSession)
        self.sessionID = nil
        listener?.cancel(); listener = nil
        startTimeout?.cancel(); startTimeout = nil
        ready?.resume(throwing: PhoneCoderHTTPFailure.closed); ready = nil
        let tasks = connections.values; connections.removeAll()
        tasks.forEach { $0.cancel() }
        // The lifecycle facade also cancels the ledger; both paths are
        // idempotent and never wait for native Metal retirement here.
        for (id, job) in jobs where oldSession == nil || job.sessionID == oldSession {
            job.cancellationSignal.cancel()
            jobs[id]?.cancellation = .serverStopped
            job.deadline.cancel()
            Task { [ledger, coordinator] in
                await coordinator.markOutputCommitted(requestID: id, sessionID: job.sessionID)
                _ = try? await ledger.cancelOwned(id: id, ownerClientID: job.owner, reason: .serverStopped)
                await coordinator.cancel(requestID: id, sessionID: job.sessionID)
            }
        }
    }

    private func listenerChanged(_ state: NWListener.State, sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        switch state {
        case .ready:
            guard gate.isOpen(sessionID), let port = listener?.port?.rawValue else { stop(sessionID: sessionID); return }
            startTimeout?.cancel(); startTimeout = nil
            ready?.resume(returning: port); ready = nil
        case .failed:
            let handler = onEvent
            stop(sessionID: sessionID)
            handler?(.failed(.networkUnavailable, sessionID: sessionID))
        case .cancelled: stop(sessionID: sessionID)
        default: break
        }
    }
    private func startExpired(sessionID: UUID) {
        guard self.sessionID == sessionID, ready != nil else { return }
        stop(sessionID: sessionID)
    }

    private func accept(_ connection: NWConnection, sessionID: UUID) {
        guard self.sessionID == sessionID, gate.isOpen(sessionID) else { gate.remove(connection); connection.cancel(); return }
        let id = UUID()
        connections[id] = Task { [weak self] in
            await self?.handle(connection, sessionID: sessionID)
            await self?.connectionEnded(id, connection: connection, sessionID: sessionID)
        }
        onEvent?(.connections(connections.count, sessionID: sessionID))
    }

    private func connectionEnded(_ id: UUID, connection: NWConnection, sessionID: UUID) {
        connections.removeValue(forKey: id)
        gate.remove(connection); connection.cancel()
        if self.sessionID == sessionID { onEvent?(.connections(connections.count, sessionID: sessionID)) }
    }

    private func handle(_ connection: NWConnection, sessionID: UUID) async {
        let socket = PhoneCoderHTTPSocket(connection, limits: limits)
        do {
            try await socket.ready()
            var bytes = Data()
            let headerDeadline = ContinuousClock.now.advanced(by: .seconds(limits.headerSeconds))
            var parsed: PhoneCoderHTTPHead?
            while parsed == nil {
                try requireSession(sessionID)
                let remaining = Self.seconds(until: headerDeadline)
                guard remaining > 0 else { throw PhoneCoderHTTPFailure.timeout }
                let part = try await socket.receive(maximum: min(1024, limits.headerBytes + 1 - bytes.count), seconds: remaining)
                guard !part.isEmpty else { throw PhoneCoderHTTPFailure.closed }
                bytes.append(part)
                parsed = try PhoneCoderHTTPHead.parse(bytes, limits: limits)
            }
            guard let head = parsed else { throw PhoneCoderHTTPFailure.closed }
            let isPairing = head.method == "POST" && head.path == "/pair/exchange"
            let client: PhoneCoderAuthContext?
            if isPairing {
                guard head.contentLength <= 4096 else { throw PhoneCoderHTTPFailure(413, "body_too_large", "Pairing body is too large.") }
                client = nil
            } else {
                guard let bearer = Self.bearer(head.headers["authorization"]),
                      let authenticated = await pairings.authenticate(bearer: bearer) else {
                    throw PhoneCoderHTTPFailure(401, "unauthorized", "A valid paired-client bearer is required.")
                }
                client = authenticated
            }
            try requireSession(sessionID)
            var body = Data(bytes.dropFirst(head.byteCount))
            guard body.count <= head.contentLength else { throw PhoneCoderHTTPFailure(400, "invalid_http", "Pipelining is not supported.") }
            let bodyDeadline = ContinuousClock.now.advanced(by: .seconds(limits.bodySeconds))
            while body.count < head.contentLength {
                let remaining = Self.seconds(until: bodyDeadline)
                guard remaining > 0 else { throw PhoneCoderHTTPFailure.timeout }
                let part = try await socket.receive(maximum: min(16_384, head.contentLength - body.count), seconds: remaining)
                guard !part.isEmpty else { throw PhoneCoderHTTPFailure.closed }
                body.append(part)
                try requireSession(sessionID)
            }
            if !isPairing {
                // A key rotated while the body uploaded must not start work.
                guard let bearer = Self.bearer(head.headers["authorization"]),
                      await pairings.authenticate(bearer: bearer)?.id == client?.id else {
                    throw PhoneCoderHTTPFailure(401, "unauthorized", "Client credential has been revoked.")
                }
            }
            // Observe peer close while waiting for ledger/model work. Losing
            // this socket cancels only its subscriber; the owner job survives.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    do { try await self.route(head, body: body, client: client, socket: socket, sessionID: sessionID) }
                    catch {
                        if !socket.responseStarted, self.gate.isOpen(sessionID), !Task.isCancelled {
                            let failure = PhoneCoderWireFailure.map(error)
                            try await socket.response(status: failure.status, body: PhoneCoderWireFailure.data(failure.error))
                        }
                    }
                }
                group.addTask {
                    _ = try await socket.receive(maximum: 1, seconds: self.limits.requestSeconds + 30)
                    throw PhoneCoderHTTPFailure.closed
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch {
            if !socket.responseStarted, gate.isOpen(sessionID) {
                let failure = PhoneCoderWireFailure.map(error)
                try? await socket.response(status: failure.status, body: PhoneCoderWireFailure.data(failure.error))
            }
        }
    }

    private func route(_ head: PhoneCoderHTTPHead, body: Data, client: PhoneCoderAuthContext?, socket: PhoneCoderHTTPSocket, sessionID: UUID) async throws {
        try requireSession(sessionID)
        if head.method == "POST", head.path == "/pair/exchange" {
            try await pair(head, body: body, socket: socket, sessionID: sessionID)
            return
        }
        guard let client else { throw PhoneCoderHTTPFailure(401, "unauthorized", "Client credential required.") }
        switch (head.method, head.path) {
        case ("GET", "/health"):
            let state = await coordinator.state()
            let facts = await deviceFacts()
            try requireSession(sessionID)
            let ready = state.availability == .available && state.modelSession != nil
            try await json(socket, ["api_version": "phone-coder-api/1", "app": "Phone Coder", "lifecycle": "foreground",
                "listening": true, "ready": ready, "model": state.modelSession?.modelID as Any? ?? NSNull(),
                "model_session_id": state.modelSession?.id.uuidString as Any? ?? NSNull(),
                "session_id": sessionID.uuidString, "queue": state.waitingCount,
                "generating": state.activeRequestID != nil, "memory_available_bytes": facts.availableMemoryBytes,
                "thermal": facts.thermal, "runtime_status": Self.availabilityCode(state.availability)])
        case ("GET", "/v1/models"):
            let state = await coordinator.state()
            let models = await coordinator.installedModels()
            let capabilities = try? await coordinator.capabilities()
            try requireSession(sessionID)
            let entries: [[String: Any]] = models.map { model in
                var row: [String: Any] = ["id": model.id, "object": "model", "created": 0,
                    "owned_by": "on-device", "display_name": model.displayName, "installed": true,
                    "loaded": model.id == state.modelSession?.modelID,
                    "callable": model.id == state.modelSession?.modelID && state.availability == .available]
                if model.id == state.modelSession?.modelID, let capabilities {
                    row["context_window"] = capabilities.limits.contextWindow
                    row["max_output_tokens"] = capabilities.limits.maximumOutputTokens
                    row["default_max_tokens"] = capabilities.limits.defaultOutputTokens
                    row["token_count_mode"] = capabilities.limits.tokenCountMode.rawValue
                }
                return row
            }
            try await json(socket, ["object": "list", "data": entries, "active_alias": "iphone-coder"])
        case ("POST", "/v1/chat/completions"), ("POST", "/v1/responses"):
            try requireJSON(head)
            try await generate(head, body: body, client: client, socket: socket, sessionID: sessionID)
        case ("DELETE", let path) where path.hasPrefix("/v1/requests/"):
            let id = try Self.requestID(head)
            guard path == "/v1/requests/" + id.rawValue else { throw PhoneCoderHTTPFailure(400, "invalid_request_id", "Header and path request IDs must match.") }
            let changed: Bool
            if let job = jobs[id], job.owner == client.id {
                // Save intent before any actor hop. The ledger may not yet be
                // exposed, or coordinator admission may still be in flight.
                let newlyCancelled = job.cancellation == nil
                job.cancellationSignal.cancel()
                jobs[id]?.cancellation = .client
                await coordinator.markOutputCommitted(requestID: id, sessionID: job.sessionID)
                changed = (try? await ledger.cancelOwned(id: id, ownerClientID: client.id, reason: .client)) ?? newlyCancelled
                Task { [coordinator] in await coordinator.cancel(requestID: id, sessionID: job.sessionID) }
            } else {
                // Missing IDs and another client's IDs share the same failure.
                changed = try await ledger.cancelOwned(id: id, ownerClientID: client.id, reason: .client)
            }
            try await json(socket, ["id": id.rawValue, "cancelled": changed])
        default: throw PhoneCoderHTTPFailure(404, "route_not_found", "Route is not supported.")
        }
    }

    private func generate(_ head: PhoneCoderHTTPHead, body: Data, client: PhoneCoderAuthContext, socket: PhoneCoderHTTPSocket, sessionID: UUID) async throws {
        let id = try Self.requestID(head)
        let fingerprint = SHA256.hash(data: Data((head.path + "\n").utf8) + body)
        let decoded: PhoneCoderDecodedRequest = head.path == "/v1/responses"
            ? .responses(try PhoneCoderResponsesRequest.decode(body)) : .chat(try PhoneCoderChatRequest.decode(body))
        let after: Int?
        if let value = head.headers["last-event-id"] {
            guard decoded.stream, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int(value) else {
                throw PhoneCoderHTTPFailure(400, "invalid_event_id", "Last-Event-ID must be a nonnegative streaming event ID.")
            }
            after = parsed
        } else { after = nil }
        let existing = try await ledger.existing(id: id, fingerprint: fingerprint, ownerClientID: client.id)
        var countMode = "runtime_or_conservative_on_stop"
        if !existing {
            guard after == nil || after == 0 else { throw PhoneCoderHTTPFailure(410, "replay_expired", "No retained request exists for reattachment.") }
            let health = await coordinator.state()
            if case .unavailable(let reason) = health.availability { throw reason }
            guard let model = health.modelSession, decoded.model == model.modelID || decoded.model == "iphone-coder" else {
                throw PhoneCoderHTTPFailure(404, "model_unavailable", "The requested model is not loaded.")
            }
            let capabilities = try await coordinator.capabilities()
            var generation = decoded.generation(id: id, sessionID: sessionID, modelSession: model, parser: capabilities.toolParser)
            let preflight = try await coordinator.preflight(generation)
            generation.maxTokens = preflight.outputTokens
            countMode = preflight.prompt.mode.rawValue
            try requireSession(sessionID)
            let admission: Task<Void, Error>
            if let job = jobs[id] {
                guard job.owner == client.id else { throw PhoneCoderHTTPFailure(404, "request_not_found", "Request is not available to this client.") }
                guard job.fingerprint == fingerprint else { throw PhoneCoderHTTPFailure(409, "request_conflict", "Request ID belongs to a different body.") }
                admission = job.admission
            } else {
                // Reserve ownership synchronously, before begin can publish a
                // record. Socket cancellation never cancels this owner task.
                let cancellationSignal = PhoneCoderRequestCancellation()
                generation.cancellationSignal = cancellationSignal
                let prepared = generation
                admission = Task { [self] in
                    try await admit(decoded, generation: prepared, preflight: preflight,
                        parser: capabilities.toolParser, client: client, fingerprint: fingerprint)
                }
                let seconds = limits.requestSeconds
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    await self?.expire(id, owner: client.id, sessionID: sessionID)
                }
                jobs[id] = Job(sessionID: sessionID, owner: client.id, fingerprint: fingerprint,
                    admission: admission, cancellationSignal: cancellationSignal, cancellation: nil, task: nil, deadline: deadline)
            }
            try await admission.value
        }

        let stream = try await ledger.attach(id: id, fingerprint: fingerprint, after: after, ownerClientID: client.id)
        try requireSession(sessionID)
        if decoded.stream {
            try await socket.beginStream(extra: ["X-Token-Count-Mode": countMode,
                "X-Phone-Coder-Usage-Mode": decoded.stops.isEmpty ? "runtime" : "runtime_or_conservative_on_stop"])
            for await event in stream {
                try Task.checkCancellation(); try requireSession(sessionID)
                try await socket.send(PhoneCoderAPIEncoder.sse(id: event.id, event: event.event))
            }
        } else {
            for await _ in stream { try Task.checkCancellation() }
            try requireSession(sessionID)
            if let data = try await ledger.responseBody(id: id, fingerprint: fingerprint, ownerClientID: client.id) {
                try await socket.response(status: 200, body: data, extra: ["X-Phone-Coder-Usage-Mode": decoded.stops.isEmpty ? "runtime" : "runtime_or_conservative_on_stop"])
            } else if let terminal = try await ledger.terminal(id: id, ownerClientID: client.id), let error = PhoneCoderWireFailure.terminal(terminal) {
                throw PhoneCoderWireFailure.map(error)
            } else { throw PhoneCoderHTTPFailure(410, "replay_expired", "Response payload is no longer retained.") }
        }
    }

    private func admit(_ decoded: PhoneCoderDecodedRequest, generation: PhoneCoderGenerationRequest,
                       preflight: PhoneCoderRuntimePreflight, parser: ModelToolParser,
                       client: PhoneCoderAuthContext, fingerprint: SHA256.Digest) async throws {
        let id = generation.id, session = generation.sessionID
        var ownsRecord = false
        do {
            try requireSession(session)
            let responses = decoded.isResponses
            let result = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session,
                deadline: .now.advanced(by: .seconds(limits.requestSeconds)), ownerClientID: client.id,
                terminalEvents: { terminal in
                    guard let error = PhoneCoderWireFailure.terminal(terminal) else { return [] }
                    return [responses ? .responseError(error) : .error(error), .done]
                })
            guard result == .owner else { jobEnded(id, sessionID: session); return }
            ownsRecord = true
            await admissionCheckpoint(.ledgerBegan)
            guard await admissionIsLive(id, owner: client.id, sessionID: session) else {
                jobEnded(id, sessionID: session); return
            }
            let pipeline = PhoneCoderResponsePipeline(request: decoded, generation: generation, preflight: preflight,
                parser: parser, client: client, ledger: ledger, coordinator: coordinator, activity: activity)
            await admissionCheckpoint(.beforeEnqueue)
            guard await admissionIsLive(id, owner: client.id, sessionID: session) else {
                jobEnded(id, sessionID: session); return
            }
            let pending = try await coordinator.enqueue(generation) { await pipeline.consume($0) }
            await admissionCheckpoint(.enqueued)
            // Install the drain/terminal owner even if cancellation won while
            // enqueue was suspended. Cancellation must never orphan its handle.
            jobs[id]?.task = Task { [weak self] in
                let outcome: Result<PhoneCoderGenerationResult, Error>
                do { outcome = .success(try await pending.value) } catch { outcome = .failure(error) }
                await pipeline.finish(outcome)
                await self?.jobEnded(id, sessionID: session)
            }
            if !(await admissionIsLive(id, owner: client.id, sessionID: session)) {
                Task { [coordinator] in await coordinator.cancel(requestID: id, sessionID: session) }
            }
            onEvent?(.activity(sessionID: session))
        } catch {
            if ownsRecord {
                await coordinator.markOutputCommitted(requestID: id, sessionID: session)
                try? await ledger.finish(id: id, terminal: .failed(PhoneCoderWireFailure.map(error).error), sessionID: session)
            }
            jobEnded(id, sessionID: session)
            throw error
        }
    }

    /// Check both authorities after suspension; cancellation intent survives
    /// even when DELETE reached the coordinator before this job was enqueued.
    private func admissionIsLive(_ id: PhoneCoderRequestID, owner: UUID, sessionID: UUID) async -> Bool {
        let terminal: PhoneCoderTerminalResult?
        do { terminal = try await ledger.terminal(id: id, ownerClientID: owner) }
        catch { return false }
        guard let job = jobs[id], job.owner == owner, job.sessionID == sessionID else { return false }
        let reason = job.cancellation ?? (self.sessionID == sessionID && gate.isOpen(sessionID) ? nil : .serverStopped)
        if let reason {
            await coordinator.markOutputCommitted(requestID: id, sessionID: sessionID)
            _ = try? await ledger.cancelOwned(id: id, ownerClientID: owner, reason: reason)
            return false
        }
        return terminal == nil
    }

    private func expire(_ id: PhoneCoderRequestID, owner: UUID, sessionID: UUID) async {
        guard jobs[id]?.sessionID == sessionID else { return }
        jobs[id]?.cancellationSignal.cancel()
        jobs[id]?.cancellation = .deadline
        await coordinator.markOutputCommitted(requestID: id, sessionID: sessionID)
        _ = try? await ledger.cancelOwned(id: id, ownerClientID: owner, reason: .deadline)
        Task { [coordinator] in await coordinator.cancel(requestID: id, sessionID: sessionID) }
    }
    private func jobEnded(_ id: PhoneCoderRequestID, sessionID: UUID) {
        guard jobs[id]?.sessionID == sessionID else { return }
        jobs.removeValue(forKey: id)?.deadline.cancel()
        onEvent?(.activity(sessionID: sessionID))
    }

    private func pair(_ head: PhoneCoderHTTPHead, body: Data, socket: PhoneCoderHTTPSocket, sessionID: UUID) async throws {
        try requireJSON(head)
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(object.keys) == ["token", "name"], let token = object["token"] as? String,
              token.utf8.count == 64, let name = object["name"] as? String, name.utf8.count <= 512 else {
            throw PhoneCoderHTTPFailure(400, "invalid_pairing", "Expected a one-time token and client name.")
        }
        let approve = approval, gate = gate
        guard let credential = try await exchange.redeem(token: token, name: name, approval: { name in
            guard gate.isOpen(sessionID), !Task.isCancelled else { return false }
            return await approve(name) && gate.isOpen(sessionID) && !Task.isCancelled
        }) else { throw PhoneCoderHTTPFailure(403, "pairing_denied", "The token expired, was used, or was not approved.") }
        try requireSession(sessionID)
        try await socket.response(status: 200, body: JSONEncoder().encode(credential))
    }

    private func requireSession(_ session: UUID) throws {
        guard sessionID == session, gate.isOpen(session), !Task.isCancelled else { throw PhoneCoderHTTPFailure.closed }
    }
    private func requireJSON(_ head: PhoneCoderHTTPHead) throws {
        guard head.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
            throw PhoneCoderHTTPFailure(415, "unsupported_media_type", "Content-Type must be application/json.")
        }
    }
    private func json(_ socket: PhoneCoderHTTPSocket, _ value: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= limits.bodyBytes else { throw PhoneCoderHTTPFailure(413, "output_limit", "Metadata response is too large.") }
        try await socket.response(status: 200, body: data)
    }
    private static func bearer(_ value: String?) -> String? {
        guard let value else { return nil }
        let parts = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2, parts[0].lowercased() == "bearer", parts[1].utf8.count == 64 else { return nil }
        return String(parts[1])
    }
    private static func requestID(_ head: PhoneCoderHTTPHead) throws -> PhoneCoderRequestID {
        guard let value = head.headers["x-phone-coder-request-id"], (1...128).contains(value.utf8.count),
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw PhoneCoderHTTPFailure(400, "invalid_request_id", "A bounded X-Phone-Coder-Request-ID is required.")
        }
        return .init(rawValue: value)
    }
    private static func seconds(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let value = ContinuousClock.now.duration(to: deadline).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    private static func availabilityCode(_ availability: PhoneCoderRuntimeAvailability) -> String {
        if case .unavailable(let reason) = availability { return PhoneCoderWireFailure.map(reason).error.code }
        return "available"
    }
}

@MainActor
final class PhoneCoderNetworkListener: PhoneCoderServerListening {
    let server: PhoneCoderAPIServer
    weak var controller: PhoneCoderServerController?
    private let port: UInt16
    private let cancelApproval: @MainActor () -> Void
    private var sessionID: UUID?
    init(server: PhoneCoderAPIServer, port: UInt16 = 11434, cancelApproval: @escaping @MainActor () -> Void = {}) {
        self.server = server; self.port = port; self.cancelApproval = cancelApproval
    }
    func start(sessionID: UUID) async throws {
        self.sessionID = sessionID
        server.gate.open(sessionID: sessionID)
        await server.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event {
                case .connections(let count, let session): self.controller?.updateConnectionCount(count, sessionID: session)
                case .failed(let error, let session): self.controller?.listenerFailed(error, sessionID: session)
                case .activity: await self.controller?.refreshHealth()
                }
            }
        }
        guard self.sessionID == sessionID, server.gate.isOpen(sessionID) else { throw PhoneCoderListenerError.networkUnavailable }
        _ = try await server.start(port: port, sessionID: sessionID)
        guard self.sessionID == sessionID, server.gate.isOpen(sessionID) else { throw PhoneCoderListenerError.networkUnavailable }
    }
    func stop() {
        let previous = sessionID
        sessionID = nil
        server.gate.close(sessionID: previous)
        cancelApproval()
        if let previous { Task { await server.stop(sessionID: previous) } }
    }
}

/// Task 7 presents this one pending owner decision. Expiry, disconnect and
/// foreground loss reject it; no background approval can issue a credential.
@MainActor
final class PhoneCoderPairingApproval: ObservableObject {
    struct Request: Identifiable { let id: UUID; let name: String }
    @Published private(set) var pending: Request?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?
    func request(name: String) async -> Bool {
        guard pending == nil, !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation; pending = .init(id: id, name: name)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    self?.resolve(id: id, approved: false)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.resolve(id: id, approved: false) } }
    }
    func resolve(id: UUID, approved: Bool) {
        guard pending?.id == id else { return }
        let continuation = continuation
        self.continuation = nil; pending = nil
        timeout?.cancel(); timeout = nil
        continuation?.resume(returning: approved)
    }
    func cancel() { if let id = pending?.id { resolve(id: id, approved: false) } }
}
