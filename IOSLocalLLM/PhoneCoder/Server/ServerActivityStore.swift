import Foundation

enum PhoneCoderActivityTerminal: String, Codable, Sendable {
    case completed, cancelled, deadline, outputLimit, modelUnavailable, memoryPressure, thermal, runtimeFailure, serverStopped, invalidOutput
}

/// This schema is deliberately incapable of storing prompts, output, tool
/// arguments, credentials, or arbitrary diagnostic strings.
struct PhoneCoderServerActivity: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    let clientID: UUID
    let clientName: String
    let modelID: String
    let startedAt: Date
    let endedAt: Date
    let inputTokens: Int
    let outputTokens: Int
    let terminal: PhoneCoderActivityTerminal
    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

actor PhoneCoderServerActivityStore {
    private let url: URL?
    private var records: [PhoneCoderServerActivity]?
    private let maximumRecords = 2048
    private let maximumFileBytes = 2_097_152
    init(url: URL?) { self.url = url }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneCoder", isDirectory: true).appendingPathComponent("server-activity.json")
    }

    func record(_ entry: PhoneCoderServerActivity, now: Date = Date()) throws {
        guard entry.clientName.utf8.count <= 512, entry.modelID.utf8.count <= 1024,
              entry.inputTokens >= 0, entry.outputTokens >= 0,
              entry.startedAt <= entry.endedAt, entry.endedAt <= now else { throw CocoaError(.coderInvalidValue) }
        var current = try load()
        current.append(entry)
        records = pruned(current, now: now)
        try save()
    }

    func entries(now: Date = Date()) throws -> [PhoneCoderServerActivity] {
        let previous = try load()
        let current = pruned(previous, now: now)
        records = current
        if previous != current { try save() }
        return current
    }

    func clear() throws { records = []; try save() }

    private func pruned(_ values: [PhoneCoderServerActivity], now: Date) -> [PhoneCoderServerActivity] {
        Array(values.filter { $0.endedAt > now.addingTimeInterval(-604_800) && $0.endedAt <= now }
            .sorted { $0.endedAt < $1.endedAt }.suffix(maximumRecords))
    }

    private func load() throws -> [PhoneCoderServerActivity] {
        if let records { return records }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { records = []; return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumFileBytes else { throw CocoaError(.fileReadTooLarge) }
        let decoded = try JSONDecoder().decode([PhoneCoderServerActivity].self, from: Data(contentsOf: url))
        guard decoded.count <= maximumRecords else { throw CocoaError(.coderInvalidValue) }
        records = decoded
        return decoded
    }

    private func save() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records ?? [])
        guard data.count <= maximumFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        var excluded = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
}
