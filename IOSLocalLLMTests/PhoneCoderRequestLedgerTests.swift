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

    // Catches rejecting terminal payload/lookup reads after rotation or granting
    // fresh execution ownership for a retained ID; preserves the byte-budget guard.
    func testOwnedTerminalPayloadReplaysAcrossSessionAndTerminalFramesShareBudget() async throws {
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
        let newSession = UUID()
        await ledger.setSessionID(newSession)
        let payload = try await ledger.responseBody(id: next, fingerprint: hash, ownerClientID: owner)
        XCTAssertEqual(payload, Data("{}".utf8))
        let retained = try await ledger.existing(id: next, fingerprint: hash, ownerClientID: owner)
        XCTAssertTrue(retained)
        let replay = try await ledger.begin(id: next, fingerprint: hash, sessionID: newSession, deadline: .now, ownerClientID: owner)
        XCTAssertEqual(replay, .existing, "A retained terminal ID must never become an execution owner")
    }

    // Catches applying the current-session execution guard to a completed stream,
    // losing retained sequence IDs, or leaving a terminal reattachment open.
    func testCompletedStreamReplaysRetainedEventsAndEndsAfterSessionRotation() async throws {
        let owner = UUID()
        let ledger = PhoneCoderRequestLedger(sessionID: session)
        _ = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline, ownerClientID: owner)
        _ = try await ledger.append(id: id, event: .chatText(context, "first"), sessionID: session)
        _ = try await ledger.append(id: id, event: .chatText(context, "second"), sessionID: session)
        try await ledger.finish(id: id, terminal: .completed, sessionID: session, finalEvents: [.done])
        await ledger.setSessionID(UUID())
        let stream = try await ledger.attach(id: id, fingerprint: fingerprint, after: 1, ownerClientID: owner)
        let events = await terminalEvents(in: stream)
        XCTAssertEqual(events.map(\.id), [2, 3])
        XCTAssertEqual(events.map(\.event), [.chatText(context, "second"), .done])
    }

    // Catches rejecting interrupted terminal records after rotation, changing the
    // cancellation outcome, or registering terminal reattachments as live work.
    func testBackgroundAndSessionEndedCancellationReplayWithoutLiveSubscribers() async throws {
        for reason in [PhoneCoderCancellationReason.serverStopped, .sessionEnded] {
            let owner = UUID(), newSession = UUID()
            let ledger = PhoneCoderRequestLedger(sessionID: session, subscriberLimit: 1)
            _ = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline,
                ownerClientID: owner, terminalEvents: { _ in [.done] })
            _ = try await ledger.append(id: id, event: .chatText(context, "partial"), sessionID: session)
            if reason == .serverStopped { await ledger.cancelAll(reason: .serverStopped) }
            await ledger.setSessionID(newSession)
            let first = try await ledger.attach(id: id, fingerprint: fingerprint, after: nil, ownerClientID: owner)
            let second = try await ledger.attach(id: id, fingerprint: fingerprint, after: nil, ownerClientID: owner)
            let events = await terminalEvents(in: first)
            let repeated = await terminalEvents(in: second)
            XCTAssertEqual(events.map(\.event), [.chatText(context, "partial"), .done])
            XCTAssertEqual(repeated, events)
            let terminal = try await ledger.terminal(id: id, ownerClientID: owner)
            XCTAssertEqual(terminal, .cancelled(reason))
            let replay = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: newSession, deadline: deadline, ownerClientID: owner)
            XCTAssertEqual(replay, .existing)
        }
    }

    // Catches moving terminal-read permission ahead of owner/fingerprint checks,
    // including leaking a conflict to a caller who does not own the record.
    func testTerminalReplayAcrossRotationStillEnforcesOwnerAndFingerprint() async throws {
        let owner = UUID(), other = UUID(), newSession = UUID()
        let ledger = PhoneCoderRequestLedger(sessionID: session)
        let different = SHA256.hash(data: Data("different".utf8))
        _ = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline, ownerClientID: owner)
        try await ledger.finish(id: id, terminal: .completed, sessionID: session, finalEvents: [.done], responseBody: Data("{}".utf8))
        await ledger.setSessionID(newSession)
        for (client, hash, expected) in [
            (Optional(other), fingerprint, "request_not_found"),
            (Optional(other), different, "request_not_found"),
            (nil, fingerprint, "request_not_found"),
            (Optional(owner), different, "request_conflict")
        ] {
            await assertAPIError(expected) { _ = try await ledger.existing(id: self.id, fingerprint: hash, ownerClientID: client) }
            await assertAPIError(expected) { _ = try await ledger.attach(id: self.id, fingerprint: hash, after: nil, ownerClientID: client) }
            await assertAPIError(expected) { _ = try await ledger.responseBody(id: self.id, fingerprint: hash, ownerClientID: client) }
            await assertAPIError(expected) {
                _ = try await ledger.begin(id: self.id, fingerprint: hash, sessionID: newSession, deadline: self.deadline, ownerClientID: client)
            }
        }
    }

    // Catches retaining cross-session payloads past the completed-record bound,
    // dropping tombstone enforcement, or granting ownership to an evicted ID.
    func testCrossSessionTerminalReplayStillExpiresWhenEvicted() async throws {
        let owner = UUID(), newSession = UUID()
        let ledger = PhoneCoderRequestLedger(sessionID: session, completedRecordLimit: 1)
        _ = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline, ownerClientID: owner)
        try await ledger.finish(id: id, terminal: .completed, sessionID: session, finalEvents: [.done], responseBody: Data("{}".utf8))
        await ledger.setSessionID(newSession)
        let other = PhoneCoderRequestID(rawValue: "replacement")
        _ = try await ledger.begin(id: other, fingerprint: fingerprint, sessionID: newSession, deadline: deadline, ownerClientID: owner)
        try await ledger.finish(id: other, terminal: .completed, sessionID: newSession)
        await assertAPIError("replay_expired") { _ = try await ledger.existing(id: self.id, fingerprint: self.fingerprint, ownerClientID: owner) }
        await assertAPIError("replay_expired") { _ = try await ledger.attach(id: self.id, fingerprint: self.fingerprint, after: nil, ownerClientID: owner) }
        await assertAPIError("replay_expired") { _ = try await ledger.responseBody(id: self.id, fingerprint: self.fingerprint, ownerClientID: owner) }
        await assertAPIError("replay_expired") {
            _ = try await ledger.begin(id: self.id, fingerprint: self.fingerprint, sessionID: newSession, deadline: self.deadline, ownerClientID: owner)
        }
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

    // Catches using terminal-read permission for stale admission or writes, and
    // granting a fresh execution lease for the prior session's retained ID.
    func testSessionChangeRejectsStaleBeginsAndCallbacks() async throws {
        let ledger = PhoneCoderRequestLedger(sessionID: session)
        _ = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: session, deadline: deadline)
        let newSession = UUID()
        await ledger.setSessionID(newSession)
        for requestID in [id, PhoneCoderRequestID(rawValue: "new")] {
            await assertAPIError("stale_session") {
                _ = try await ledger.begin(id: requestID, fingerprint: self.fingerprint, sessionID: self.session, deadline: self.deadline)
            }
        }
        for callbackSession in [session, newSession] {
            await assertAPIError("stale_session") {
                _ = try await ledger.append(id: self.id, event: .done, sessionID: callbackSession)
            }
            await assertAPIError("stale_session") {
                try await ledger.finish(id: self.id, terminal: .completed, sessionID: callbackSession)
            }
        }
        let replay = try await ledger.begin(id: id, fingerprint: fingerprint, sessionID: newSession, deadline: deadline)
        XCTAssertEqual(replay, .existing)
        let fresh = try await ledger.begin(id: .init(rawValue: "fresh"), fingerprint: fingerprint, sessionID: newSession, deadline: deadline)
        XCTAssertEqual(fresh, .owner)
        let terminal = try await ledger.terminal(id: id)
        XCTAssertEqual(terminal, .cancelled(.sessionEnded))
    }

    private func assertAPIError(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                                operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let error as PhoneCoderAPIError { XCTAssertEqual(error.code, code, file: file, line: line) }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    private func terminalEvents(in stream: AsyncStream<PhoneCoderRequestLedger.SequencedEvent>) async -> [PhoneCoderRequestLedger.SequencedEvent] {
        let ended = expectation(description: "Retained terminal replay ends without waiting for new work")
        let reader = Task {
            var events: [PhoneCoderRequestLedger.SequencedEvent] = []
            for await event in stream { events.append(event) }
            ended.fulfill()
            return events
        }
        await fulfillment(of: [ended], timeout: 2)
        reader.cancel() // Also release a stuck iterator if the terminal-close assertion failed.
        return await reader.value
    }
}
