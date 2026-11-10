import Foundation
import Security

struct PhoneCoderClientCredential: Codable, Equatable {
    let id: UUID
    let name: String
    let bearer: String
}

struct PhoneCoderAuthContext: Equatable {
    let id: UUID
    let name: String
}

protocol PhoneCoderPairingStorage {
    func read() throws -> String?
    func write(_ value: String) throws
}

struct PhoneCoderKeychainPairingStorage: PhoneCoderPairingStorage {
    let service: String
    private let account = "clients"
    init(service: String = "com.haider.phonecoder.pairings") { self.service = service }
    func read() throws -> String? { try KeychainStore.getChecked(account: account, serviceName: service) }
    func write(_ value: String) throws { try KeychainStore.setChecked(value, account: account, serviceName: service) }
}

enum PhoneCoderPairingError: Error {
    case invalidName, notFound, randomFailure, invalidRandomLength
}

// SecRandomCopyBytes is the only production entropy source. Hex encoding preserves
// all 256 bits while making bearer tokens safe for HTTP headers and QR payloads.
enum PhoneCoderSecret {
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PhoneCoderPairingError.randomFailure
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func checked(_ random: () throws -> String) throws -> String {
        let secret = try random()
        guard secret.utf8.count == 64, secret.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw PhoneCoderPairingError.invalidRandomLength
        }
        return secret
    }
    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = a.count ^ b.count
        // Fixed work for valid credentials, with no early exit on differing bytes.
        for index in 0..<max(a.count, b.count) {
            difference |= Int((index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0))
        }
        return difference == 0
    }
}

actor PhoneCoderPairingStore {
    private let storage: PhoneCoderPairingStorage
    private let random: () throws -> String
    init(storage: PhoneCoderPairingStorage = PhoneCoderKeychainPairingStorage(), random: @escaping () throws -> String = PhoneCoderSecret.generate) {
        self.storage = storage
        self.random = random
    }
    static func normalizedName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty, normalized.count <= 80,
              normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw PhoneCoderPairingError.invalidName
        }
        return normalized
    }
    private func load() throws -> [PhoneCoderClientCredential] {
        guard let value = try storage.read() else { return [] }
        return try JSONDecoder().decode([PhoneCoderClientCredential].self, from: Data(value.utf8))
    }
    private func save(_ clients: [PhoneCoderClientCredential]) throws {
        let data = try JSONEncoder().encode(clients)
        try storage.write(String(decoding: data, as: UTF8.self))
    }
    func create(name: String) throws -> PhoneCoderClientCredential {
        let normalized = try Self.normalizedName(name)
        var clients = try load()
        let bearer = try PhoneCoderSecret.checked(random)
        guard !clients.contains(where: { PhoneCoderSecret.equal($0.bearer, bearer) }) else { throw PhoneCoderPairingError.randomFailure }
        let client = PhoneCoderClientCredential(id: UUID(), name: normalized, bearer: bearer)
        clients.append(client)
        try save(clients)
        return client
    }
    func authenticate(bearer: String) -> PhoneCoderAuthContext? {
        guard let clients = try? load() else { return nil }
        var matched: PhoneCoderAuthContext?
        for client in clients {
            if PhoneCoderSecret.equal(client.bearer, bearer) { matched = PhoneCoderAuthContext(id: client.id, name: client.name) }
        }
        return matched
    }
    func revoke(id: UUID) throws {
        var clients = try load()
        clients.removeAll { $0.id == id }
        try save(clients)
    }
    func revokeAll() throws { try save([]) }
    func rotate(id: UUID) throws -> PhoneCoderClientCredential {
        var clients = try load()
        guard let index = clients.firstIndex(where: { $0.id == id }) else { throw PhoneCoderPairingError.notFound }
        let bearer = try PhoneCoderSecret.checked(random)
        guard !clients.contains(where: { PhoneCoderSecret.equal($0.bearer, bearer) }) else { throw PhoneCoderPairingError.randomFailure }
        let client = PhoneCoderClientCredential(id: id, name: clients[index].name, bearer: bearer)
        clients[index] = client
        // A single Keychain update replaces the old credential before publication.
        try save(clients)
        return client
    }
}
