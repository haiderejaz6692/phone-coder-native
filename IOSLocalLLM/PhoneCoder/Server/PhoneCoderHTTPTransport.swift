// Network.framework integration informed by the upstream LocalAPIServer.
// Copyright (c) 2026 Mesut and iOS Local LLM contributors. MIT; see LICENSE.
import Darwin
import Foundation
import Network

struct PhoneCoderHTTPLimits: Sendable {
    var headerBytes = 16_384
    var headerCount = 64
    var bodyBytes = PhoneCoderChatRequest.maximumBodyBytes
    var connections = 16
    var headerSeconds: TimeInterval = 10
    var bodySeconds: TimeInterval = 30
    var writeSeconds: TimeInterval = 15
    var requestSeconds: TimeInterval = 180
}

struct PhoneCoderHTTPFailure: Error, Sendable {
    let status: Int
    let error: PhoneCoderAPIError
    init(_ status: Int, _ code: String, _ message: String) {
        self.status = status
        error = .init(code: code, message: message)
    }
    static let closed = Self(503, "connection_closed", "Connection closed.")
    static let timeout = Self(408, "request_timeout", "Request timed out.")
}

/// Only HTTP/1.1 origin-form requests with a single, explicit framing are
/// accepted. Headers are parsed before authentication and body accumulation.
struct PhoneCoderHTTPHead: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let contentLength: Int
    let byteCount: Int

    static func parse(_ data: Data, limits: PhoneCoderHTTPLimits) throws -> Self? {
        let delimiter = Data([13, 10, 13, 10])
        guard let end = data.range(of: delimiter) else {
            guard data.count <= limits.headerBytes else { throw PhoneCoderHTTPFailure(431, "headers_too_large", "Request headers are too large.") }
            return nil
        }
        guard end.upperBound <= limits.headerBytes else { throw PhoneCoderHTTPFailure(431, "headers_too_large", "Request headers are too large.") }
        let bytes = data[..<end.lowerBound]
        guard bytes.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
              let text = String(data: bytes, encoding: .ascii) else { throw malformed }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, first.utf8.count <= 4096 else { throw malformed }
        let request = first.split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1",
              ["GET", "POST", "DELETE"].contains(String(request[0])),
              request[1].hasPrefix("/"), !request[1].hasPrefix("//"),
              !request[1].contains("?"), !request[1].contains("#"), !request[1].contains("%"),
              lines.count - 1 <= limits.headerCount else { throw malformed }
        var headers: [String: String] = [:]
        let token = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw malformed }
            let name = String(line[..<colon])
            guard !name.isEmpty, name.utf8.allSatisfy({ token.contains($0) }) else { throw malformed }
            let key = name.lowercased()
            guard headers[key] == nil else { throw malformed }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !value.contains("\r"), !value.contains("\n") else { throw malformed }
            headers[key] = value
        }
        guard let host = headers["host"], !host.isEmpty,
              headers["transfer-encoding"] == nil, headers["expect"] == nil else { throw malformed }
        var length = 0
        if let value = headers["content-length"] {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int(value) else { throw malformed }
            guard parsed <= limits.bodyBytes else { throw PhoneCoderHTTPFailure(413, "body_too_large", "Request body is too large.") }
            length = parsed
        }
        guard request[0] == "POST" || length == 0 else { throw malformed }
        return Self(method: String(request[0]), path: String(request[1]), headers: headers, contentLength: length, byteCount: end.upperBound)
    }

    private static var malformed: PhoneCoderHTTPFailure { .init(400, "invalid_http", "Malformed or unsupported HTTP request.") }
}

/// Snapshot only the interfaces actually used by this accepted connection,
/// not the unrelated interfaces available elsewhere on the device.
struct PhoneCoderConnectionPath: Sendable {
    struct Interface: Sendable {
        enum Kind: Equatable, Sendable { case loopback, other, cellular, wifi, wired, unknown }
        let name: String
        let kind: Kind
    }
    let satisfied: Bool
    let usedInterfaces: [Interface]

    init(satisfied: Bool, usedInterfaces: [Interface]) {
        self.satisfied = satisfied; self.usedInterfaces = usedInterfaces
    }
    init(_ path: NWPath) {
        satisfied = path.status == .satisfied
        usedInterfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map { interface in
            let kind: Interface.Kind
            switch interface.type {
            case .loopback: kind = .loopback
            case .other: kind = .other
            case .cellular: kind = .cellular
            case .wifi: kind = .wifi
            case .wiredEthernet: kind = .wired
            @unknown default: kind = .unknown
            }
            return .init(name: interface.name, kind: kind)
        }
    }
}

enum PhoneCoderNetworkExposure {
    static func allows(host: String) -> Bool { addressKind(host) != nil }

    static func accepts(local: String, peer: String, path: PhoneCoderConnectionPath) -> Bool {
        guard path.satisfied else { return false }
        if addressKind(local) == .loopback, addressKind(peer) == .loopback {
            // Loopback is intrinsically on-device and may have no enumerated
            // interface in a simulator's Network.framework path snapshot.
            return true
        }
        guard addressKind(local) == .tailnet, addressKind(peer) == .tailnet,
              !path.usedInterfaces.isEmpty else { return false }
        // A carrier CGNAT address alone is never an overlay credential. Require
        // the actual accepted path to use only Darwin tunnel interfaces.
        return path.usedInterfaces.allSatisfy {
            let suffix = $0.name.dropFirst(4)
            return $0.kind == .other && $0.name.hasPrefix("utun") && !suffix.isEmpty
                && suffix.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    static func accepts(_ path: NWPath?) -> Bool {
        guard let path, case .hostPort(let local, _) = path.localEndpoint,
              case .hostPort(let remote, _) = path.remoteEndpoint else { return false }
        return accepts(local: String(describing: local), peer: String(describing: remote), path: .init(path))
    }

    static func advertises(host: String, interface: String) -> Bool {
        guard addressKind(host) == .tailnet else { return false }
        return !["lo", "pdp_ip", "awdl", "llw", "ipsec"].contains(where: interface.hasPrefix)
    }

    static func allows(endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        return allows(host: String(describing: host))
    }

    static func addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result = Set<String>()
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: host)
            if advertises(host: value, interface: String(cString: entry.pointee.ifa_name)) { result.insert(value) }
        }
        return result.sorted()
    }

    private enum Kind: Equatable { case loopback, tailnet }
    private static func addressKind(_ host: String) -> Kind? {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            if bytes[0] == 127 { return .loopback }
            return bytes[0] == 100 && (64...127).contains(bytes[1]) ? .tailnet : nil
        }
        var ipv6 = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return .loopback }
        if Array(bytes.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] { return .tailnet }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            if bytes[12] == 127 { return .loopback }
            if bytes[12] == 100, (64...127).contains(bytes[13]) { return .tailnet }
        }
        return nil
    }
}

/// Synchronous admission authority shared with the MainActor listener adapter.
/// stop invalidates even starts whose actor hop has not run yet.
final class PhoneCoderTransportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var session: UUID?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func open(sessionID: UUID) {
        close()
        lock.lock(); session = sessionID; lock.unlock()
    }
    func isOpen(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return session == id
    }
    func install(_ value: NWListener, sessionID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard session == sessionID else { value.cancel(); return false }
        listener = value
        return true
    }
    func admit(_ value: NWConnection, sessionID: UUID, limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard session == sessionID, connections.count < limit else { value.cancel(); return false }
        connections[ObjectIdentifier(value)] = value
        return true
    }
    func remove(_ value: NWConnection) {
        lock.lock(); connections.removeValue(forKey: ObjectIdentifier(value)); lock.unlock()
    }
    func close(sessionID: UUID? = nil) {
        lock.lock()
        guard sessionID == nil || session == sessionID else { lock.unlock(); return }
        session = nil
        let oldListener = listener
        let oldConnections = Array(connections.values)
        listener = nil; connections.removeAll()
        lock.unlock()
        oldListener?.cancel()
        oldConnections.forEach { $0.cancel() }
    }
}

/// Each operation races its native callback with one bounded timer. Completion
/// is synchronized so timeout/cancellation can never resume a continuation twice.
private final class PhoneCoderNetworkOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var timer: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func installTimer(_ task: Task<Void, Never>) {
        lock.lock()
        if continuation == nil { lock.unlock(); task.cancel(); return }
        timer = task; lock.unlock()
    }
    @discardableResult func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard let next = continuation else { lock.unlock(); return false }
        continuation = nil
        let timer = timer; self.timer = nil
        lock.unlock()
        timer?.cancel(); next.resume(with: result)
        return true
    }
}

final class PhoneCoderHTTPSocket: @unchecked Sendable {
    let connection: NWConnection
    let limits: PhoneCoderHTTPLimits
    private let responseLock = NSLock()
    private var beganResponse = false
    var responseStarted: Bool { responseLock.lock(); defer { responseLock.unlock() }; return beganResponse }
    private func markResponseStarted() { responseLock.lock(); beganResponse = true; responseLock.unlock() }
    init(_ connection: NWConnection, limits: PhoneCoderHTTPLimits) { self.connection = connection; self.limits = limits }

    func ready() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = PhoneCoderNetworkOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(.success(()))
                case .failed, .cancelled: once.finish(.failure(PhoneCoderHTTPFailure.closed))
                default: break
                }
            }
            once.installTimer(timeout(after: limits.headerSeconds, once: once))
            connection.start(queue: .global(qos: .userInitiated))
        }
        guard PhoneCoderNetworkExposure.accepts(connection.currentPath) else {
            connection.cancel()
            throw PhoneCoderHTTPFailure(403, "network_not_allowed", "Use the paired tailnet connection.")
        }
    }

    func receive(maximum: Int, seconds: TimeInterval) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let once = PhoneCoderNetworkOnce<Data>(continuation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                    if error != nil { once.finish(.failure(PhoneCoderHTTPFailure.closed)) }
                    else { once.finish(.success(data ?? Data())) }
                }
                once.installTimer(timeout(after: seconds, once: once))
            }
        } onCancel: { self.connection.cancel() }
    }

    func send(_ data: Data) async throws {
        // A single route owns writes; await completion for every bounded frame.
        for offset in stride(from: 0, to: data.count, by: 16_384) {
            try Task.checkCancellation()
            let piece = data.subdata(in: offset..<min(data.count, offset + 16_384))
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let once = PhoneCoderNetworkOnce(continuation)
                    connection.send(content: piece, completion: .contentProcessed { error in
                        once.finish(error == nil ? .success(()) : .failure(PhoneCoderHTTPFailure.closed))
                    })
                    once.installTimer(timeout(after: limits.writeSeconds, once: once))
                }
            } onCancel: { self.connection.cancel() }
        }
    }

    func response(status: Int, body: Data, contentType: String = "application/json", extra: [String: String] = [:]) async throws {
        markResponseStarted()
        try await send(Self.headers(status: status, contentType: contentType, length: body.count, extra: extra))
        try await send(body)
    }

    func beginStream(extra: [String: String] = [:]) async throws {
        markResponseStarted()
        try await send(Self.headers(status: 200, contentType: "text/event-stream; charset=utf-8", length: nil, extra: extra))
    }

    static func headers(status: Int, contentType: String, length: Int?, extra: [String: String] = [:]) -> Data {
        var lines = ["HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")", "Content-Type: \(contentType)",
                     "Cache-Control: no-store", "X-Content-Type-Options: nosniff", "Connection: close",
                     "X-Phone-Coder-API-Version: phone-coder-api/1"]
        if let length { lines.append("Content-Length: \(length)") }
        // Extra values are created from server-owned numeric/enum metadata only.
        for key in extra.keys.sorted() { lines.append("\(key): \(extra[key]!)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func timeout<Value: Sendable>(after seconds: TimeInterval, once: PhoneCoderNetworkOnce<Value>) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(max(0.001, seconds))) } catch { return }
            if once.finish(.failure(PhoneCoderHTTPFailure.timeout)) { self.connection.cancel() }
        }
    }
}
