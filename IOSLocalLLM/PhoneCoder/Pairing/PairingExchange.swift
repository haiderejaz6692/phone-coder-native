import Foundation

struct PhoneCoderPairingPayload: Codable {
    let server: String
    let apiVersion: String
    let tailnetIdentity: String
    let token: String
}

actor PhoneCoderPairingExchange {
    private let store: PhoneCoderPairingStore
    private let now: () -> Date
    private let random: () throws -> String
    private var tokens: [String: Date] = [:]

    init(store: PhoneCoderPairingStore, now: @escaping () -> Date = Date.init,
         random: @escaping () throws -> String = PhoneCoderSecret.generate) {
        self.store = store
        self.now = now
        self.random = random
    }
    func issue(server: String, apiVersion: String, tailnetIdentity: String) throws -> PhoneCoderPairingPayload {
        let date = now()
        tokens = tokens.filter { $0.value > date }
        let token = try PhoneCoderSecret.checked(random)
        guard tokens[token] == nil else { throw PhoneCoderPairingError.randomFailure }
        tokens[token] = date.addingTimeInterval(300)
        return PhoneCoderPairingPayload(server: server, apiVersion: apiVersion, tailnetIdentity: tailnetIdentity, token: token)
    }
    func redeem(token: String, name: String,
                approval: @MainActor (String) async -> Bool) async throws -> PhoneCoderClientCredential? {
        // Consume before any suspension, validation, or approval, including rejection.
        guard let expiry = tokens.removeValue(forKey: token), expiry > now() else { return nil }
        let normalized = try PhoneCoderPairingStore.normalizedName(name)
        guard await approval(normalized) else { return nil }
        return try await store.create(name: normalized)
    }
    func invalidate(token: String) { tokens.removeValue(forKey: token) }
}
