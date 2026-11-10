import Combine
import CryptoKit
import Foundation
import Network
import XCTest
@testable import PhoneCoder

@MainActor
final class PhoneCoderAPIServerTests: XCTestCase {
    func testAuthenticationPrecedesBodyAndRotationRevokesPreviousCredential() async throws {
        let fixture = try await APIServerFixture.make()
        defer { fixture.close() }
        let unauthorized = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", bearer: "wrong", extra: ["Content-Length": "900000"], body: nil)
        XCTAssertTrue(unauthorized.hasPrefix("HTTP/1.1 401"))
        let health = try await fixture.exchange(path: "/health")
        XCTAssertTrue(health.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(health.contains("Cache-Control: no-store"))
        XCTAssertTrue(health.contains("X-Content-Type-Options: nosniff"))
        XCTAssertTrue(health.contains("phone-coder-api/1"))
        let rotated = try await fixture.store.rotate(id: fixture.client.id)
        let revoked = try await fixture.exchange(path: "/v1/models")
        XCTAssertTrue(revoked.hasPrefix("HTTP/1.1 401"))
        let accepted = try await fixture.exchange(path: "/v1/models", bearer: rotated.bearer)
        XCTAssertTrue(accepted.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(accepted.contains("\"max_output_tokens\":512"))
        try await fixture.store.revoke(id: rotated.id)
        let removed = try await fixture.exchange(path: "/health", bearer: rotated.bearer)
        XCTAssertTrue(removed.hasPrefix("HTTP/1.1 401"))
    }

    func testChatJSONStreamingUsageUnicodeReplayAndConflictUseOneInference() async throws {
        let fixture = try await APIServerFixture.make()
        defer { fixture.close() }
        let id = UUID().uuidString
        let body = Data(#"{"model":"test-model","messages":[{"role":"user","content":"hello🙂"}],"stream":true,"stream_options":{"include_usage":true},"max_tokens":32}"#.utf8)
        let first = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: id, body: body, fragmentBytes: 1)
        XCTAssertTrue(first.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(first.contains("🙂"))
        XCTAssertTrue(first.contains("\"completion_tokens\":3"))
        XCTAssertTrue(first.contains("data: [DONE]"))
        let eventIDs = first.components(separatedBy: "\n").filter { $0.hasPrefix("id: ") }.compactMap { Int($0.dropFirst(4)) }
        XCTAssertEqual(eventIDs, Array(1...eventIDs.count))
        let replay = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: id, extra: ["Last-Event-ID": "1"], body: body)
        XCTAssertFalse(replay.contains("id: 1\n"))
        XCTAssertTrue(replay.contains("data: [DONE]"))
        let conflict = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: id, body: Data(#"{"model":"test-model","messages":[{"role":"user","content":"different"}]}"#.utf8))
        XCTAssertTrue(conflict.hasPrefix("HTTP/1.1 409"))
        let starts = await fixture.runtime.startedCount
        XCTAssertEqual(starts, 1)

        let plainID = UUID().uuidString
        let plain = Data(#"{"model":"test-model","messages":[{"role":"user","content":"text"}]}"#.utf8)
        let json = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: plainID, body: plain)
        let jsonReplay = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: plainID, body: plain)
        XCTAssertEqual(json, jsonReplay)
        XCTAssertTrue(json.contains("chat.completion"))
        XCTAssertTrue(json.contains("\"prompt_tokens\":7"))
    }

    func testStrictValidationContextAndCrossClientCancellationFailExplicitly() async throws {
        let fixture = try await APIServerFixture.make(held: true)
        defer { fixture.close() }
        let invalid = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: UUID().uuidString,
            body: Data(#"{"model":"test-model","messages":[{"role":"user","content":"x"}],"unknown":true}"#.utf8))
        XCTAssertTrue(invalid.hasPrefix("HTTP/1.1 400"))
        let tooMany = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: UUID().uuidString,
            body: Data(#"{"model":"test-model","messages":[{"role":"user","content":"x"}],"max_tokens":513}"#.utf8))
        XCTAssertTrue(tooMany.contains("output_tokens_exceeded"))
        let id = UUID().uuidString
        let response = Task { try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: id,
            body: Data(#"{"model":"test-model","messages":[{"role":"user","content":"x"}],"stream":true}"#.utf8)) }
        await fixture.runtime.waitUntilStarted()
        let other = try await fixture.store.create(name: "Other")
        let denied = try await fixture.exchange(method: "DELETE", path: "/v1/requests/\(id)", id: id, bearer: other.bearer)
        XCTAssertTrue(denied.hasPrefix("HTTP/1.1 404"))
        let cancelled = try await fixture.exchange(method: "DELETE", path: "/v1/requests/\(id)", id: id)
        XCTAssertTrue(cancelled.hasPrefix("HTTP/1.1 200"))
        let again = try await fixture.exchange(method: "DELETE", path: "/v1/requests/\(id)", id: id)
        XCTAssertTrue(again.hasPrefix("HTTP/1.1 200"))
        let output = try await response.value
        XCTAssertTrue(output.contains("request_cancelled"))
        XCTAssertFalse(output.contains("\"finish_reason\":\"stop\""))
    }

    func testDisconnectReattachesWithoutStartingAnotherGeneration() async throws {
        let fixture = try await APIServerFixture.make(held: true)
        defer { fixture.close() }
        let id = UUID().uuidString
        let body = Data(#"{"model":"test-model","messages":[{"role":"user","content":"hello"}],"stream":true}"#.utf8)
        let socket = APIWireClient(port: fixture.port)
        try await socket.send(fixture.request(method: "POST", path: "/v1/chat/completions", id: id, body: body))
        let prefix = try await socket.read(until: "🙂")
        XCTAssertTrue(prefix.contains("🙂"))
        socket.close()
        let resumed = Task { try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: id, extra: ["Last-Event-ID": "1"], body: body) }
        await fixture.runtime.release()
        let output = try await resumed.value
        XCTAssertTrue(output.contains("data: [DONE]"))
        let count = await fixture.runtime.startedCount
        XCTAssertEqual(count, 1)
    }

    func testResponsesToolEventsAreEncodedButNeverExecuted() async throws {
        let fixture = try await APIServerFixture.make(output: [#"<tool_call>{"name":"lookup","arguments":{"key":"x"}}</tool_call>"#])
        defer { fixture.close() }
        let body = Data(#"{"model":"test-model","input":"lookup x","stream":true,"tools":[{"type":"function","name":"lookup","parameters":{"type":"object","properties":{"key":{"type":"string"}},"required":["key"],"additionalProperties":false}}],"tool_choice":"required"}"#.utf8)
        let output = try await fixture.exchange(method: "POST", path: "/v1/responses", id: UUID().uuidString, body: body)
        XCTAssertTrue(output.contains("event: response.created"))
        XCTAssertTrue(output.contains("event: response.function_call_arguments.delta"))
        XCTAssertTrue(output.contains("event: response.completed"))
        XCTAssertTrue(output.contains("\"name\":\"lookup\""))
        XCTAssertTrue(output.contains("\"sequence_number\":"))
    }

    func testQueuePressureRejectsSixthRequestAndDeadlineIsTerminal() async throws {
        let fixture = try await APIServerFixture.make(held: true)
        defer { fixture.close() }
        let rejected = expectation(description: "queue full is returned without waiting for native work")
        let body = Data(#"{"model":"test-model","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        let requests = (0..<6).map { _ in Task {
            let value = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: UUID().uuidString, body: body)
            if value.hasPrefix("HTTP/1.1 429") { rejected.fulfill() }
            return value
        } }
        await fulfillment(of: [rejected], timeout: 3)
        await fixture.runtime.release()
        var results: [String] = []
        for request in requests { results.append(try await request.value) }
        XCTAssertEqual(results.filter { $0.hasPrefix("HTTP/1.1 429") }.count, 1)
        XCTAssertEqual(results.filter { $0.hasPrefix("HTTP/1.1 200") }.count, 5)

        var limits = PhoneCoderHTTPLimits(); limits.requestSeconds = 0.05
        let timed = try await APIServerFixture.make(held: true, limits: limits)
        defer { timed.close() }
        let output = try await timed.exchange(method: "POST", path: "/v1/chat/completions", id: UUID().uuidString,
            body: Data(#"{"model":"test-model","messages":[{"role":"user","content":"x"}],"stream":true}"#.utf8))
        XCTAssertTrue(output.contains("deadline_exceeded"))
        XCTAssertFalse(output.contains("\"finish_reason\":\"stop\""))
    }

    func testModelHealthAndCompletedReplayDoNotDependOnStaleReadyState() async throws {
        let fixture = try await APIServerFixture.make()
        defer { fixture.close() }
        let id = UUID().uuidString
        let body = Data(#"{"model":"test-model","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        let completed = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: id, body: body)
        await fixture.runtime.setAvailability(.unavailable(.memoryPressure))
        let health = try await fixture.exchange(path: "/health")
        XCTAssertTrue(health.contains("\"ready\":false"))
        XCTAssertTrue(health.contains("memory_pressure"))
        let replay = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: id, body: body)
        XCTAssertEqual(replay, completed)
        let fresh = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: UUID().uuidString, body: body)
        XCTAssertTrue(fresh.hasPrefix("HTTP/1.1 503"))
        let other = try await fixture.store.create(name: "Other")
        let privateReplay = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", id: id, bearer: other.bearer, body: body)
        XCTAssertTrue(privateReplay.hasPrefix("HTTP/1.1 404"))
    }

    func testOutputLimitAndInvalidToolArgumentsProduceErrorsWithoutFalseSuccess() async throws {
        let oversized = try await APIServerFixture.make(output: [String(repeating: "a", count: 262_145)])
        defer { oversized.close() }
        let output = try await oversized.exchange(method: "POST", path: "/v1/chat/completions", id: UUID().uuidString,
            body: Data(#"{"model":"test-model","messages":[{"role":"user","content":"x"}],"stream":true}"#.utf8))
        XCTAssertTrue(output.contains("output_limit"))
        XCTAssertFalse(output.contains("\"finish_reason\":\"stop\""))
        let malformed = try await APIServerFixture.make(output: [#"<tool_call>{"name":"lookup","arguments":{"key":42}}</tool_call>"#])
        defer { malformed.close() }
        let body = Data(#"{"model":"test-model","input":"lookup","tools":[{"type":"function","name":"lookup","parameters":{"type":"object","properties":{"key":{"type":"string"}},"required":["key"]}}],"tool_choice":"required"}"#.utf8)
        let rejected = try await malformed.exchange(method: "POST", path: "/v1/responses", id: UUID().uuidString, body: body)
        XCTAssertTrue(rejected.contains("invalid_tool_output"))
        XCTAssertFalse(rejected.contains("\"arguments\""))
    }

    func testPairingDenialConsumesTokenAndApprovalCancellationClosesPrompt() async throws {
        let fixture = try await APIServerFixture.make()
        fixture.shouldApprove = false
        defer { fixture.close() }
        let payload = try await fixture.pairing.issue(server: "http://100.64.0.1", apiVersion: "phone-coder-api/1", tailnetIdentity: "100.64.0.1")
        let body = try JSONSerialization.data(withJSONObject: ["token": payload.token, "name": "Denied"])
        let rejected = try await fixture.exchange(method: "POST", path: "/pair/exchange", bearer: "", body: body)
        XCTAssertTrue(rejected.hasPrefix("HTTP/1.1 403"))
        fixture.shouldApprove = true
        let replay = try await fixture.exchange(method: "POST", path: "/pair/exchange", bearer: "", body: body)
        XCTAssertTrue(replay.hasPrefix("HTTP/1.1 403"))
        let owner = PhoneCoderPairingApproval()
        let task = Task { await owner.request(name: "Pending") }
        let appeared = expectation(description: "owner approval is visible")
        let subscription = owner.$pending.sink { if $0 != nil { appeared.fulfill() } }
        await fulfillment(of: [appeared], timeout: 2)
        owner.cancel()
        let approved = await task.value
        XCTAssertFalse(approved)
        XCTAssertNil(owner.pending)
        subscription.cancel()
    }

    func testPairExchangeRequiresOwnerApprovalAndTokenCannotReplay() async throws {
        let fixture = try await APIServerFixture.make()
        defer { fixture.close() }
        let payload = try await fixture.pairing.issue(server: "http://100.64.0.1", apiVersion: "phone-coder-api/1", tailnetIdentity: "100.64.0.1")
        let body = try JSONSerialization.data(withJSONObject: ["token": payload.token, "name": "New laptop"])
        let accepted = try await fixture.exchange(method: "POST", path: "/pair/exchange", bearer: "", body: body)
        XCTAssertTrue(accepted.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(fixture.approvedNames, ["New laptop"])
        let replay = try await fixture.exchange(method: "POST", path: "/pair/exchange", bearer: "", body: body)
        XCTAssertTrue(replay.hasPrefix("HTTP/1.1 403"))
        XCTAssertEqual(fixture.approvedNames.count, 1)
    }

    func testStopInvalidatesListenerAndTruncatedUploadTimesOut() async throws {
        var limits = PhoneCoderHTTPLimits(); limits.bodySeconds = 0.05
        let fixture = try await APIServerFixture.make(limits: limits)
        defer { fixture.close() }
        let start = ContinuousClock.now
        do {
            let truncated = try await fixture.exchange(method: "POST", path: "/v1/chat/completions", extra: ["Content-Length": "100"], body: Data("{".utf8))
            XCTAssertTrue(truncated.isEmpty || truncated.hasPrefix("HTTP/1.1 408"))
        } catch is NWError { /* A read timeout closes the native socket. */ }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        fixture.server.gate.close(sessionID: fixture.session)
        do { _ = try await fixture.server.start(port: 0, sessionID: fixture.session); XCTFail("Stopped gate reopened") }
        catch { }
    }

    func testIncompleteHeaderHasBoundedReadDeadline() async throws {
        var limits = PhoneCoderHTTPLimits(); limits.headerSeconds = 0.05
        let fixture = try await APIServerFixture.make(limits: limits)
        defer { fixture.close() }
        let socket = APIWireClient(port: fixture.port)
        defer { socket.close() }
        let start = ContinuousClock.now
        try await socket.send(Data("GET /health HTTP/1.1\r\nHost:".utf8))
        do {
            let response = try await socket.read()
            XCTAssertFalse(response.hasPrefix("HTTP/1.1 200"))
        } catch is NWError { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testStopSequenceAcrossChunksPreservesUnicodeAndExcludesSuffix() {
        var filter = PhoneCoderStopBuffer(stops: ["END"])
        XCTAssertEqual(filter.consume("🙂E"), "🙂")
        XCTAssertEqual(filter.consume("N"), "")
        XCTAssertEqual(filter.consume("Dhidden"), "")
        XCTAssertTrue(filter.stopped)
        XCTAssertEqual(filter.finish(), "")
    }
    func testHTTPHeadRejectsAmbiguousFramingAndBoundsBeforeBody() throws {
        let valid = Data("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer abc\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let head = try XCTUnwrap(PhoneCoderHTTPHead.parse(valid, limits: .init()))
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.path, "/v1/chat/completions")
        XCTAssertEqual(head.contentLength, 2)
        XCTAssertEqual(valid.suffix(from: head.byteCount), Data("{}".utf8))
        for headers in [
            "Content-Length: 2\r\nContent-Length: 2",
            "Content-Length: 2\r\ncontent-length: 3",
            "Transfer-Encoding: chunked", "Content-Length: -1",
            "Content-Length: 1048577", "Authorization: Bearer a\r\nAuthorization: Bearer b",
            "Host: local\r\n folded: value"
        ] {
            XCTAssertThrowsError(try PhoneCoderHTTPHead.parse(Data("POST /v1/responses HTTP/1.1\r\nHost: localhost\r\n\(headers)\r\n\r\n".utf8), limits: .init()))
        }
        XCTAssertNil(try PhoneCoderHTTPHead.parse(Data("GET /health HTTP/1.1\r\nHost: localhost\r\n".utf8), limits: .init()))
        XCTAssertThrowsError(try PhoneCoderHTTPHead.parse(Data(repeating: 65, count: 16_385), limits: .init()))
        XCTAssertThrowsError(try PhoneCoderHTTPHead.parse(Data("GET http://public.example/health HTTP/1.1\r\nHost: local\r\n\r\n".utf8), limits: .init()))
    }

    func testOnlyLoopbackAndExactTailnetRangesAreAcceptedAndAdvertised() {
        for host in ["127.0.0.1", "::1", "100.64.0.0", "100.127.255.255", "fd7a:115c:a1e0::1"] {
            XCTAssertTrue(PhoneCoderNetworkExposure.allows(host: host), host)
        }
        for host in ["100.63.255.255", "100.128.0.0", "192.168.1.5", "10.0.0.1", "8.8.8.8", "::", "fd7a:115c:a1e1::1", "fe80::1", "localhost", "100.100.100.100.example"] {
            XCTAssertFalse(PhoneCoderNetworkExposure.allows(host: host), host)
        }
        XCTAssertTrue(PhoneCoderNetworkExposure.advertises(host: "100.101.102.103", interface: "utun4"))
        XCTAssertTrue(PhoneCoderNetworkExposure.advertises(host: "fd7a:115c:a1e0::ab", interface: "utun3"))
        XCTAssertFalse(PhoneCoderNetworkExposure.advertises(host: "127.0.0.1", interface: "lo0"))
        XCTAssertFalse(PhoneCoderNetworkExposure.advertises(host: "100.101.102.103", interface: "pdp_ip0"))
        XCTAssertFalse(PhoneCoderNetworkExposure.advertises(host: "100.101.102.103", interface: "awdl0"))
        XCTAssertFalse(PhoneCoderNetworkExposure.advertises(host: "192.168.1.2", interface: "utun4"))
    }

    func testActivityPersistsOnlyMetadataPrunesSevenDaysAndClears() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("activity.json")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = PhoneCoderServerActivityStore(url: url)
        let old = PhoneCoderServerActivity(clientID: UUID(), clientName: "Ubuntu", modelID: "model", startedAt: now.addingTimeInterval(-604_801), endedAt: now.addingTimeInterval(-604_801), inputTokens: 3, outputTokens: 4, terminal: .completed)
        let recent = PhoneCoderServerActivity(clientID: UUID(), clientName: "Laptop", modelID: "model", startedAt: now.addingTimeInterval(-2), endedAt: now, inputTokens: 7, outputTokens: 5, terminal: .cancelled)
        try await store.record(old, now: old.endedAt)
        try await store.record(recent, now: now)
        let restored = PhoneCoderServerActivityStore(url: url)
        let rows = try await restored.entries(now: now)
        XCTAssertEqual(rows, [recent])
        let data = try Data(contentsOf: url)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(encoded.first).keys), Set(["id", "clientID", "clientName", "modelID", "startedAt", "endedAt", "inputTokens", "outputTokens", "terminal"]))
        try await restored.clear()
        let empty = try await restored.entries(now: now)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data("[]".utf8))
    }
}

private final class APITestPairingStorage: PhoneCoderPairingStorage {
    private var value: String?
    func read() throws -> String? { value }
    func write(_ value: String) throws { self.value = value }
}

private actor APITestRuntime: PhoneCoderTextRuntime {
    var startedCount = 0
    private var started: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Error>?
    private var held: Bool
    private let output: [String]
    private var availability: PhoneCoderRuntimeAvailability = .available
    init(held: Bool, output: [String]) { self.held = held; self.output = output }
    func installedModels() async -> [PhoneCoderModelDescriptor] { [.init(id: "test-model", displayName: "Test model")] }
    func liveAvailability() async -> PhoneCoderRuntimeAvailability { availability }
    func setAvailability(_ value: PhoneCoderRuntimeAvailability) { availability = value }
    func load(modelID: String) async throws -> PhoneCoderModelSession { .init(id: UUID(), modelID: modelID) }
    func unload() async {}
    func capabilities(session: PhoneCoderModelSession) async throws -> PhoneCoderRuntimeCapabilities {
        .init(limits: .init(contextWindow: 4096, maximumOutputTokens: 512, defaultOutputTokens: 32, limitSource: .runtime, tokenCountMode: .exact), toolParser: .hermes)
    }
    func preflight(_ request: PhoneCoderGenerationRequest, session: PhoneCoderModelSession) async throws -> PhoneCoderRuntimePreflight {
        let value = try await capabilities(session: session)
        let output = try LocalAPIStrictInput.outputTokens(requested: request.maxTokens, promptTokens: 7, limits: value.limits)
        return .init(prompt: .init(tokens: 7, mode: .exact), limits: value.limits, outputTokens: output)
    }
    func generate(_ request: PhoneCoderGenerationRequest, session: PhoneCoderModelSession, onEvent: @escaping @Sendable (PhoneCoderRuntimeEvent) async -> Void) async throws -> PhoneCoderGenerationResult {
        startedCount += 1
        for text in output { await onEvent(.init(requestID: request.id, sessionID: request.sessionID, modelSessionID: session.id, text: text)) }
        if held {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started.forEach { $0.resume() }; started.removeAll()
            }
        } else { started.forEach { $0.resume() }; started.removeAll() }
        return .init(requestID: request.id, sessionID: request.sessionID, modelSessionID: session.id, promptTokens: 7, completionTokens: 3, finishReason: .stop)
    }
    func cancel(requestID: PhoneCoderRequestID) async { continuation?.resume(throwing: PhoneCoderRuntimeError.cancelled); continuation = nil }
    func release() { held = false; continuation?.resume(); continuation = nil }
    func waitUntilStarted() async {
        if continuation != nil || (!held && startedCount > 0) { return }
        await withCheckedContinuation { started.append($0) }
    }
}

@MainActor
private final class APIServerFixture {
    let session: UUID
    let runtime: APITestRuntime
    let store: PhoneCoderPairingStore
    let pairing: PhoneCoderPairingExchange
    let coordinator: PhoneCoderInferenceCoordinator
    let ledger: PhoneCoderRequestLedger
    var client: PhoneCoderClientCredential!
    var server: PhoneCoderAPIServer!
    var port: UInt16 = 0
    var approvedNames: [String] = []
    var shouldApprove = true
    init(held: Bool, output: [String]) {
        let runtime = APITestRuntime(held: held, output: output)
        let store = PhoneCoderPairingStore(storage: APITestPairingStorage())
        let session = UUID()
        self.runtime = runtime; self.store = store; self.session = session
        pairing = PhoneCoderPairingExchange(store: store)
        coordinator = PhoneCoderInferenceCoordinator(runtime: runtime, reconstruct: { runtime })
        ledger = PhoneCoderRequestLedger(sessionID: session)
    }
    static func make(held: Bool = false, output: [String] = ["hello ", "🙂"], limits: PhoneCoderHTTPLimits = .init()) async throws -> APIServerFixture {
        let fixture = APIServerFixture(held: held, output: output)
        fixture.client = try await fixture.store.create(name: "Ubuntu")
        _ = try await fixture.coordinator.switchModel(to: "test-model")
        fixture.server = PhoneCoderAPIServer(coordinator: fixture.coordinator, ledger: fixture.ledger,
            pairings: fixture.store, exchange: fixture.pairing, activity: PhoneCoderServerActivityStore(url: nil),
            limits: limits, approval: { [weak fixture] name in fixture?.approvedNames.append(name); return fixture?.shouldApprove ?? false })
        fixture.server.gate.open(sessionID: fixture.session)
        fixture.port = try await fixture.server.start(port: 0, sessionID: fixture.session)
        return fixture
    }
    func close() {
        server.gate.close()
        let server = server!, runtime = runtime
        Task { await runtime.release(); await server.stop(sessionID: session) }
    }
    func request(method: String = "GET", path: String, id: String? = nil, bearer: String? = nil, extra: [String: String] = [:], body: Data? = nil) -> Data {
        var headers = ["Host": "localhost", "Authorization": "Bearer \(bearer ?? client.bearer)", "Content-Type": "application/json", "Connection": "close"]
        if let id { headers["X-Phone-Coder-Request-ID"] = id }
        if let body { headers["Content-Length"] = String(body.count) }
        headers.merge(extra) { _, new in new }
        var data = Data(("\(method) \(path) HTTP/1.1\r\n" + headers.keys.sorted().map { "\($0): \(headers[$0]!)\r\n" }.joined() + "\r\n").utf8)
        data.append(body ?? Data())
        return data
    }
    func exchange(method: String = "GET", path: String, id: String? = nil, bearer: String? = nil, extra: [String: String] = [:], body: Data? = nil, fragmentBytes: Int = Int.max) async throws -> String {
        let socket = APIWireClient(port: port)
        defer { socket.close() }
        try await socket.send(request(method: method, path: path, id: id, bearer: bearer, extra: extra, body: body), fragmentBytes: fragmentBytes)
        return try await socket.read()
    }
}

private final class APIWireClient: @unchecked Sendable {
    private let connection: NWConnection
    init(port: UInt16) { connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp) }
    func close() { connection.cancel() }
    func send(_ data: Data, fragmentBytes: Int = Int.max) async throws {
        connection.start(queue: .global())
        for offset in stride(from: 0, to: data.count, by: min(fragmentBytes, data.count)) {
            let end = offset + min(fragmentBytes, data.count - offset)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }
    }
    func read(until marker: String? = nil) async throws -> String {
        let timeout = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { connection.cancel() } }
        defer { timeout.cancel() }
        var result = Data()
        while true {
            let next: (Data, Bool) = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, error in
                    if let error, data == nil { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: (data ?? Data(), done)) }
                }
            }
            result.append(next.0)
            if let marker, String(decoding: result, as: UTF8.self).contains(marker) { break }
            if next.1 || next.0.isEmpty { break }
        }
        return String(decoding: result, as: UTF8.self)
    }
}
