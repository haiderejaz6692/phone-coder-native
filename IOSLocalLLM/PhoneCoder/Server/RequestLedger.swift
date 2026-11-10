import CryptoKit
import Foundation

enum PhoneCoderCancellationReason: Equatable, Sendable {
    case client, deadline, outputLimit, sessionEnded, serverStopped
}

enum PhoneCoderTerminalResult: Equatable, Sendable {
    case completed
    case cancelled(PhoneCoderCancellationReason)
    case failed(PhoneCoderAPIError)
}

/// Memory-only authority for a request and its replayable stream.
actor PhoneCoderRequestLedger {
    enum BeginResult: Equatable, Sendable { case owner, existing }
    struct SequencedEvent: Equatable, Sendable {
        let id: Int
        let event: PhoneCoderStreamEvent
    }

    private struct Record {
        let fingerprint: SHA256.Digest
        let sessionID: UUID
        let deadline: ContinuousClock.Instant
        var nextID = 1
        var outputBytes = 0
        var events: [SequencedEvent] = []
        var terminal: PhoneCoderTerminalResult?
        var subscribers: [UUID: AsyncStream<SequencedEvent>.Continuation] = [:]
    }

    private var sessionID: UUID
    private let replayEventLimit: Int
    private let completedRecordLimit: Int
    private let subscriberLimit: Int
    private let outputByteLimit: Int
    private var records: [PhoneCoderRequestID: Record] = [:]
    private var completedIDs: [PhoneCoderRequestID] = []
    // Evicted responses retain only bounded identity metadata, never events.
    private var tombstones: [PhoneCoderRequestID: SHA256.Digest] = [:]
    private var tombstoneIDs: [PhoneCoderRequestID] = []

    init(sessionID: UUID, replayEventLimit: Int = 256, completedRecordLimit: Int = 128, outputByteLimit: Int = 8_388_608, subscriberLimit: Int = 8) {
        precondition(replayEventLimit > 0 && completedRecordLimit > 0 && outputByteLimit > 0 && subscriberLimit > 0)
        self.sessionID = sessionID
        self.replayEventLimit = replayEventLimit
        self.completedRecordLimit = completedRecordLimit
        self.subscriberLimit = subscriberLimit
        self.outputByteLimit = outputByteLimit
    }

    func begin(id: PhoneCoderRequestID, fingerprint: SHA256.Digest, sessionID: UUID, deadline: ContinuousClock.Instant) throws -> BeginResult {
        if let record = records[id] {
            guard record.fingerprint == fingerprint else { throw Self.conflict }
            guard sessionID == self.sessionID, record.sessionID == sessionID else { throw Self.staleSession }
            return .existing
        }
        if let previousFingerprint = tombstones[id] {
            guard previousFingerprint == fingerprint else { throw Self.conflict }
            throw Self.expired
        }
        guard sessionID == self.sessionID else { throw Self.staleSession }
        records[id] = Record(fingerprint: fingerprint, sessionID: sessionID, deadline: deadline)
        return .owner
    }

    /// Convenience for synchronous owners; inference callbacks must pass their captured session ID.
    func append(id: PhoneCoderRequestID, event: PhoneCoderStreamEvent) throws -> SequencedEvent {
        try append(id: id, event: event, sessionID: sessionID)
    }

    func append(id: PhoneCoderRequestID, event: PhoneCoderStreamEvent, sessionID: UUID) throws -> SequencedEvent {
        guard sessionID == self.sessionID else { throw Self.staleSession }
        guard var record = records[id] else { throw Self.expired }
        guard record.sessionID == sessionID else { throw Self.staleSession }
        guard record.terminal == nil else { throw Self.terminalError }
        let bytes = try PhoneCoderAPIEncoder.sse(id: record.nextID, event: event).count
        guard bytes <= outputByteLimit - record.outputBytes else {
            complete(id: id, terminal: .cancelled(.outputLimit))
            throw Self.outputLimit
        }
        let sequenced = SequencedEvent(id: record.nextID, event: event)
        record.nextID += 1
        record.outputBytes += bytes
        record.events.append(sequenced)
        if record.events.count > replayEventLimit { record.events.removeFirst() }
        var detached: [UUID] = []
        for (subscriberID, continuation) in record.subscribers {
            switch continuation.yield(sequenced) {
            case .enqueued: break
            case .dropped, .terminated:
                continuation.finish()
                detached.append(subscriberID)
            @unknown default:
                continuation.finish()
                detached.append(subscriberID)
            }
        }
        for subscriberID in detached { record.subscribers.removeValue(forKey: subscriberID) }
        records[id] = record
        return sequenced
    }

    /// Convenience for synchronous owners; inference callbacks must pass their captured session ID.
    func finish(id: PhoneCoderRequestID, terminal: PhoneCoderTerminalResult) throws {
        try finish(id: id, terminal: terminal, sessionID: sessionID)
    }

    func finish(id: PhoneCoderRequestID, terminal: PhoneCoderTerminalResult, sessionID: UUID) throws {
        guard sessionID == self.sessionID else { throw Self.staleSession }
        guard let record = records[id] else { throw Self.expired }
        guard record.sessionID == sessionID else { throw Self.staleSession }
        guard record.terminal == nil else { throw Self.terminalError }
        complete(id: id, terminal: terminal)
    }

    func terminal(id: PhoneCoderRequestID) throws -> PhoneCoderTerminalResult? {
        guard let record = records[id] else { throw Self.expired }
        return record.terminal
    }

    func attach(id: PhoneCoderRequestID, fingerprint: SHA256.Digest, after eventID: Int?) throws -> AsyncStream<SequencedEvent> {
        guard var record = records[id] else {
            if let previousFingerprint = tombstones[id], previousFingerprint != fingerprint { throw Self.conflict }
            throw Self.expired
        }
        guard record.fingerprint == fingerprint else { throw Self.conflict }
        let last = eventID ?? 0
        guard last >= 0 && last < record.nextID else { throw PhoneCoderAPIError.invalid("Invalid event ID") }
        if let first = record.events.first, last < first.id - 1 { throw Self.expired }
        if record.terminal == nil && record.subscribers.count >= subscriberLimit { throw Self.subscriberLimit }
        let subscriberID = UUID()
        // Preserve the oldest unread events; overflow disconnects rather than silently skipping one.
        let (stream, continuation) = AsyncStream<SequencedEvent>.makeStream(bufferingPolicy: .bufferingOldest(replayEventLimit))
        for event in record.events where event.id > last { continuation.yield(event) }
        if record.terminal != nil {
            continuation.finish()
        } else {
            record.subscribers[subscriberID] = continuation
            records[id] = record
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeSubscriber(subscriberID, from: id) }
            }
        }
        return stream
    }

    @discardableResult
    func cancel(id: PhoneCoderRequestID, reason: PhoneCoderCancellationReason) -> Bool {
        guard let record = records[id], record.terminal == nil else { return false }
        complete(id: id, terminal: .cancelled(reason))
        return true
    }

    func cancelAll(reason: PhoneCoderCancellationReason) {
        for id in Array(records.keys) { _ = cancel(id: id, reason: reason) }
    }

    /// Called by the owner at a chosen clock instant; no wall-clock timer is retained.
    func expire(now: ContinuousClock.Instant = .now) {
        for (id, record) in records where record.terminal == nil && record.deadline <= now {
            _ = cancel(id: id, reason: .deadline)
        }
    }

    func setSessionID(_ newSessionID: UUID) {
        guard newSessionID != sessionID else { return }
        cancelAll(reason: .sessionEnded)
        sessionID = newSessionID
    }

    private func complete(id: PhoneCoderRequestID, terminal: PhoneCoderTerminalResult) {
        guard var record = records[id], record.terminal == nil else { return }
        record.terminal = terminal
        for continuation in record.subscribers.values { continuation.finish() }
        record.subscribers.removeAll()
        records[id] = record
        completedIDs.append(id)
        while completedIDs.count > completedRecordLimit {
            let evictedID = completedIDs.removeFirst()
            if let evicted = records.removeValue(forKey: evictedID) {
                tombstones[evictedID] = evicted.fingerprint
                tombstoneIDs.append(evictedID)
            }
            if tombstoneIDs.count > completedRecordLimit {
                tombstones.removeValue(forKey: tombstoneIDs.removeFirst())
            }
        }
    }

    private func removeSubscriber(_ subscriberID: UUID, from id: PhoneCoderRequestID) {
        records[id]?.subscribers.removeValue(forKey: subscriberID)
    }

    private static let conflict = PhoneCoderAPIError(code: "request_conflict", message: "Request ID belongs to a different body.")
    private static let expired = PhoneCoderAPIError(code: "replay_expired", message: "Request replay is no longer available.")
    private static let staleSession = PhoneCoderAPIError(code: "stale_session", message: "Request session is no longer active.")
    private static let terminalError = PhoneCoderAPIError(code: "request_finished", message: "Request has already finished.")
    private static let subscriberLimit = PhoneCoderAPIError(code: "subscriber_limit", message: "Request has too many active subscribers.")
    private static let outputLimit = PhoneCoderAPIError(code: "output_limit", message: "Request output limit exceeded.")
}
