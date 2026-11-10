import CryptoKit
import Foundation
import XCTest
@testable import PhoneCoder

final class PhoneCoderRequestLedgerTests: XCTestCase {
    func testClientOwnershipProtectsReplayCancellationAndFinalPayload() async throws {
        let session = UUID(), owner = UUID(), other = UUID()
        let ledger = PhoneCoderRequestLedger(sessionID: session)
        let id = PhoneCoderRequestID(rawValue: "owned")
        let hash = SHA256.hash(data: Data("body".utf8))
        _ = try await ledger.begin(id: id, fingerprint: hash, sessionID: session, deadline: .now.advanced(by: .seconds(60)), ownerClientID: owner)
        for client in [other, nil] as [UUID?] {
            do { _ = try await ledger.attach(id: id, fingerprint: hash, after: nil, ownerClientID: client); XCTFail("Cross-client replay") }
            catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "request_not_found") }
            do { _ = try await ledger.cancelOwned(id: id, ownerClientID: client, reason: .client); XCTFail("Cross-client cancellation") }
            catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "request_not_found") }
        }
        let payload = Data("{\"result\":\"ok\"}".utf8)
        try await ledger.finish(id: id, terminal: .completed, sessionID: session, finalEvents: [], responseBody: payload)
        let result = try await ledger.responseBody(id: id, fingerprint: hash, ownerClientID: owner)
        XCTAssertEqual(result, payload)
        do { _ = try await ledger.responseBody(id: id, fingerprint: hash, ownerClientID: other); XCTFail("Cross-client payload") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "request_not_found") }
        do { _ = try await ledger.begin(id: id, fingerprint: hash, sessionID: session, deadline: .now, ownerClientID: other); XCTFail("Cross-client begin") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "request_not_found") }
    }

    func testAtomicFinalPayloadAndFramesAreBoundedAndEvictedTogether() async throws {
        let session = UUID(), owner = UUID()
        let ledger = PhoneCoderRequestLedger(sessionID: session, completedRecordLimit: 1, outputByteLimit: 2048)
        let hash = SHA256.hash(data: Data("body".utf8))
        let first = PhoneCoderRequestID(rawValue: "first"), second = PhoneCoderRequestID(rawValue: "second")
        _ = try await ledger.begin(id: first, fingerprint: hash, sessionID: session, deadline: .now, ownerClientID: owner)
        try await ledger.finish(id: first, terminal: .completed, sessionID: session, finalEvents: [.done], responseBody: Data("{}".utf8))
        let stream = try await ledger.attach(id: first, fingerprint: hash, after: nil, ownerClientID: owner)
        var events: [PhoneCoderStreamEvent] = []
        for await value in stream { events.append(value.event) }
        XCTAssertEqual(events, [.done])
        _ = try await ledger.begin(id: second, fingerprint: hash, sessionID: session, deadline: .now, ownerClientID: owner)
        do { try await ledger.finish(id: second, terminal: .completed, sessionID: session, finalEvents: [.done], responseBody: Data(repeating: 65, count: 2049)); XCTFail("Oversized result") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "output_limit") }
        let terminal = try await ledger.terminal(id: second, ownerClientID: owner)
        XCTAssertEqual(terminal, .cancelled(.outputLimit))
        do { _ = try await ledger.responseBody(id: first, fingerprint: hash, ownerClientID: owner); XCTFail("Evicted payload") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "replay_expired") }
    }

    func testOwnedPayloadCannotReplayAcrossSessionAndTerminalFramesShareBudget() async throws {
        let session = UUID(), owner = UUID()
        let hash = SHA256.hash(data: Data("body".utf8))
        let ledger = PhoneCoderRequestLedger(sessionID: session, outputByteLimit: 256)
        let id = PhoneCoderRequestID(rawValue: "bounded")
        _ = try await ledger.begin(id: id, fingerprint: hash, sessionID: session, deadline: .now,
            ownerClientID: owner, terminalEvents: { _ in [.done] })
        do {
            try await ledger.finish(id: id, terminal: .completed, sessionID: session, responseBody: Data(repeating: 65, count: 256))
            XCTFail("Terminal frame and payload must share the byte budget")
        } catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "output_limit") }
        let next = PhoneCoderRequestID(rawValue: "next-session")
        _ = try await ledger.begin(id: next, fingerprint: hash, sessionID: session, deadline: .now, ownerClientID: owner)
        try await ledger.finish(id: next, terminal: .completed, sessionID: session, responseBody: Data("{}".utf8))
        await ledger.setSessionID(UUID())
        do { _ = try await ledger.responseBody(id: next, fingerprint: hash, ownerClientID: owner); XCTFail("Session payload replay") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "stale_session") }
    }

    private let id = PhoneCoderRequestID(rawValue: "request")
    private let session = UUID()
    private var fingerprint: SHA256.Digest { SHA256.hash(data: Data("body".utf8)) }
    private var deadline: ContinuousClock.Instant { ContinuousClock.now.advanced(by: .seconds(60)) }
    private let context = PhoneCoderCompletionContext(id: "c", model: "m", created: 1)

    func testConcurrentBeginsGrantExactlyOneOwnerAndRejectDifferentBody() async throws {
        let ledger = PhoneCoderRequestLedger(sessionID: session)
        async let a = ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline)
        async let b = ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline)
        let results = try await [a, b]
        XCTAssertEqual(results.filter { $0 == .owner }.count, 1)
        XCTAssertEqual(results.filter { $0 == .existing }.count, 1)
        do {
            _ = try await ledger.begin(id: id, fingerprint: SHA256.hash(data: Data("other".utf8)), sessionID: session, deadline: deadline)
            XCTFail("Expected conflict")
        } catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "request_conflict") }
    }

    func testReplayAndCompletedStreamUseIncreasingIDs() async throws {
        let ledger = PhoneCoderRequestLedger(sessionID: session)
        _ = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline)
        let first = try await ledger.append(id: id, event: .chatText(context, "a"))
        let second = try await ledger.append(id: id, event: .chatText(context, "b"))
        XCTAssertEqual([first.id, second.id], [1, 2])
        try await ledger.finish(id: id, terminal: .completed)
        let stream = try await ledger.attach(id: id, fingerprint: fingerprint, after: 1)
        var events: [PhoneCoderRequestLedger.SequencedEvent] = []
        for await event in stream { events.append(event) }
        XCTAssertEqual(events, [second])
        let terminal = try await ledger.terminal(id: id)
        XCTAssertEqual(terminal, .completed)
    }

    func testLiveAttachReceivesEventsAndClosesOnCancellation() async throws {
        let ledger = PhoneCoderRequestLedger(sessionID: session)
        _ = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline)
        let stream = try await ledger.attach(id: id, fingerprint: fingerprint, after: nil)
        let event = try await ledger.append(id: id, event: .done)
        let cancelled = await ledger.cancel(id: id, reason: .client)
        let repeated = await ledger.cancel(id: id, reason: .client)
        XCTAssertTrue(cancelled)
        XCTAssertFalse(repeated)
        var events: [PhoneCoderRequestLedger.SequencedEvent] = []
        for await value in stream { events.append(value) }
        XCTAssertEqual(events, [event])
        let terminal = try await ledger.terminal(id: id)
        XCTAssertEqual(terminal, .cancelled(.client))
    }

    func testSubscriberCapAndSlowConsumerOverflowAllowReplay() async throws {
        let ledger = PhoneCoderRequestLedger(sessionID: session, replayEventLimit: 1, subscriberLimit: 1)
        _ = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline)
        let slow = try await ledger.attach(id: id, fingerprint: fingerprint, after: nil)
        do { _ = try await ledger.attach(id: id, fingerprint: fingerprint, after: nil); XCTFail("Expected subscriber admission limit") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "subscriber_limit") }

        let first = try await ledger.append(id: id, event: .chatText(context, "one"))
        let second = try await ledger.append(id: id, event: .chatText(context, "two"))
        var iterator = slow.makeAsyncIterator()
        let buffered = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(buffered, first)
        XCTAssertNil(end)

        // Overflow frees the admission slot, and the missed event remains in the ledger.
        let resumed = try await ledger.attach(id: id, fingerprint: fingerprint, after: first.id)
        try await ledger.finish(id: id, terminal: .completed)
        var replayed: [PhoneCoderRequestLedger.SequencedEvent] = []
        for await event in resumed { replayed.append(event) }
        XCTAssertEqual(replayed, [second])
        let terminal = try await ledger.terminal(id: id)
        XCTAssertEqual(terminal, .completed)
    }

    func testEvictedEventsAndCompletedRecordsReturnReplayExpired() async throws {
        let ledger = PhoneCoderRequestLedger(sessionID: session, replayEventLimit: 1, completedRecordLimit: 1)
        _ = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline)
        _ = try await ledger.append(id: id, event: .done)
        _ = try await ledger.append(id: id, event: .done)
        do { _ = try await ledger.attach(id: id, fingerprint: fingerprint, after: nil); XCTFail("Expected expired replay") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "replay_expired") }
        try await ledger.finish(id: id, terminal: .completed)
        let other = PhoneCoderRequestID(rawValue: "other")
        _ = try await ledger.begin(id: other, fingerprint: fingerprint, sessionID: session, deadline: deadline)
        try await ledger.finish(id: other, terminal: .completed)
        do { _ = try await ledger.attach(id: id, fingerprint: fingerprint, after: 2); XCTFail("Expected expired record") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "replay_expired") }
    }

    func testEvictedRecordRetainsOnlyBoundedFingerprintTombstone() async throws {
        let ledger = PhoneCoderRequestLedger(sessionID: session, completedRecordLimit: 1)
        let different = SHA256.hash(data: Data("different".utf8))
        let second = PhoneCoderRequestID(rawValue: "second")
        let third = PhoneCoderRequestID(rawValue: "third")
        _ = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline)
        _ = try await ledger.append(id: id, event: .chatText(context, "private payload"))
        try await ledger.finish(id: id, terminal: .completed)
        _ = try await ledger.begin(id: second, fingerprint: fingerprint, sessionID: session, deadline: deadline)
        try await ledger.finish(id: second, terminal: .completed)

        do { _ = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline); XCTFail("Eviction must not grant ownership") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "replay_expired") }
        do { _ = try await ledger.begin(id: id, fingerprint: different, sessionID: session, deadline: deadline); XCTFail("Expected conflict") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "request_conflict") }
        do { _ = try await ledger.attach(id: id, fingerprint: fingerprint, after: nil); XCTFail("Evicted payload must not be replayable") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "replay_expired") }
        do { _ = try await ledger.attach(id: id, fingerprint: different, after: nil); XCTFail("Expected conflict") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "request_conflict") }
        do { _ = try await ledger.terminal(id: id); XCTFail("Terminal record must be evicted") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "replay_expired") }

        _ = try await ledger.begin(id: third, fingerprint: fingerprint, sessionID: session, deadline: deadline)
        try await ledger.finish(id: third, terminal: .completed)
        let reused = try await ledger.begin(id: id, fingerprint: different, sessionID: session, deadline: deadline)
        XCTAssertEqual(reused, .owner)
        do { _ = try await ledger.begin(id: second, fingerprint: fingerprint, sessionID: session, deadline: deadline); XCTFail("Newest tombstone must remain") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "replay_expired") }
    }

    func testExpiryAndOutputLimitTerminateOnce() async throws {
        let ledger = PhoneCoderRequestLedger(sessionID: session, outputByteLimit: 1)
        _ = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline)
        do { _ = try await ledger.append(id: id, event: .chatText(context, "too long")); XCTFail("Expected output limit") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "output_limit") }
        let outputTerminal = try await ledger.terminal(id: id)
        XCTAssertEqual(outputTerminal, .cancelled(.outputLimit))
        let other = PhoneCoderRequestID(rawValue: "other")
        let now = ContinuousClock.now
        _ = try await ledger.begin(id: other, fingerprint: fingerprint, sessionID: session, deadline: now)
        await ledger.expire(now: now)
        let expiredTerminal = try await ledger.terminal(id: other)
        XCTAssertEqual(expiredTerminal, .cancelled(.deadline))
        let cancelled = await ledger.cancel(id: other, reason: .client)
        XCTAssertFalse(cancelled)
    }

    func testSessionChangeRejectsStaleBeginsAndCallbacks() async throws {
        let ledger = PhoneCoderRequestLedger(sessionID: session)
        _ = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline)
        await ledger.setSessionID(UUID())
        do { _ = try await ledger.begin(id: PhoneCoderRequestID(rawValue: "new"), fingerprint: fingerprint, sessionID: session, deadline: deadline); XCTFail("Expected stale session") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "stale_session") }
        do { _ = try await ledger.append(id: id, event: .done, sessionID: session); XCTFail("Expected stale callback") }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, "stale_session") }
        let terminal = try await ledger.terminal(id: id)
        XCTAssertEqual(terminal, .cancelled(.sessionEnded))
    }
}
