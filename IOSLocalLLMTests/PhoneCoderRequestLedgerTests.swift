import CryptoKit
import Foundation
import XCTest
@testable import PhoneCoder

final class PhoneCoderRequestLedgerTests: XCTestCase {
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
