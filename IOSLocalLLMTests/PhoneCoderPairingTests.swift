import XCTest
@testable import PhoneCoder

private final class MemoryPairingStorage: PhoneCoderPairingStorage {
    var value: String?
    var failWrites = false
    func read() throws -> String? { value }
    func write(_ value: String) throws {
        if failWrites { throw Failure.write }
        self.value = value
    }
    enum Failure: Error { case write }
}

private final class TestClock { var date = Date(timeIntervalSince1970: 0) }

final class PhoneCoderPairingTests: XCTestCase {
    func testCredentialsPersistRotateAndRevoke() async throws {
        let storage = MemoryPairingStorage()
        let store = PhoneCoderPairingStore(storage: storage)
        let credential = try await store.create(name: "  Laptop  ")
        XCTAssertEqual(credential.name, "Laptop")
        XCTAssertEqual(credential.bearer.count, 64)
        let restored = PhoneCoderPairingStore(storage: storage)
        let context = await restored.authenticate(bearer: credential.bearer)
        XCTAssertEqual(context?.id, credential.id)
        let rotated = try await restored.rotate(id: credential.id)
        XCTAssertNotEqual(rotated.bearer, credential.bearer)
        let old = await store.authenticate(bearer: credential.bearer)
        XCTAssertNil(old)
        try await restored.revoke(id: credential.id)
        let revoked = await store.authenticate(bearer: rotated.bearer)
        XCTAssertNil(revoked)
    }

    func testInvalidNamesAndFailedWritesAreRejected() async throws {
        let storage = MemoryPairingStorage()
        let store = PhoneCoderPairingStore(storage: storage)
        do { _ = try await store.create(name: " \n "); XCTFail("empty name accepted") } catch {}
        storage.failWrites = true
        do { _ = try await store.create(name: "Laptop"); XCTFail("failed write accepted") } catch {}
    }

    func testFailedRotationDoesNotPublishNewCredential() async throws {
        let storage = MemoryPairingStorage()
        let store = PhoneCoderPairingStore(storage: storage)
        let credential = try await store.create(name: "Laptop")
        storage.failWrites = true
        do { _ = try await store.rotate(id: credential.id); XCTFail("failed rotation accepted") } catch {}
        let original = await store.authenticate(bearer: credential.bearer)
        XCTAssertEqual(original?.id, credential.id)
    }

    func testKeychainPersistsCredentialsAcrossStoreInstances() async throws {
        let service = "com.haider.phonecoder.pairings.tests." + UUID().uuidString
        defer { KeychainStore.delete(account: "clients", serviceName: service) }
        let storage = PhoneCoderKeychainPairingStorage(service: service)
        let store = PhoneCoderPairingStore(storage: storage)
        let credential = try await store.create(name: "Laptop")
        let restored = PhoneCoderPairingStore(storage: storage)
        let context = await restored.authenticate(bearer: credential.bearer)
        XCTAssertEqual(context?.name, "Laptop")
    }

    func testRejectsShortRandomSecretAndIncorrectBearer() async throws {
        let bad = PhoneCoderPairingStore(storage: MemoryPairingStorage(), random: { "short" })
        do { _ = try await bad.create(name: "Laptop"); XCTFail("short secret accepted") } catch {}
        let store = PhoneCoderPairingStore(storage: MemoryPairingStorage())
        let credential = try await store.create(name: "Laptop")
        let altered = String(credential.bearer.dropLast()) + (credential.bearer.last == "0" ? "1" : "0")
        let context = await store.authenticate(bearer: altered)
        XCTAssertNil(context)
    }

    func testExchangeRequiresApprovalAndConsumesToken() async throws {
        let store = PhoneCoderPairingStore(storage: MemoryPairingStorage())
        let exchange = PhoneCoderPairingExchange(store: store)
        let payload = try await exchange.issue(server: "https://phone.tailnet", apiVersion: "1", tailnetIdentity: "phone")
        let rejected = try await exchange.redeem(token: payload.token, name: "Laptop") { _ in false }
        XCTAssertNil(rejected)
        let replay = try await exchange.redeem(token: payload.token, name: "Laptop") { _ in true }
        XCTAssertNil(replay)
        let next = try await exchange.issue(server: "https://phone.tailnet", apiVersion: "1", tailnetIdentity: "phone")
        let credential = try await exchange.redeem(token: next.token, name: "Laptop") { _ in true }
        XCTAssertNotNil(credential)
        let encoded = String(data: try JSONEncoder().encode(next), encoding: .utf8)!
        XCTAssertFalse(encoded.contains(credential!.bearer))
    }

    func testExchangeExpiresAtFiveMinutesAndRevokeAll() async throws {
        let storage = MemoryPairingStorage()
        let store = PhoneCoderPairingStore(storage: storage)
        let first = try await store.create(name: "One")
        let second = try await store.create(name: "Two")
        try await store.revokeAll()
        let a = await store.authenticate(bearer: first.bearer)
        let b = await store.authenticate(bearer: second.bearer)
        XCTAssertNil(a); XCTAssertNil(b)
        let clock = TestClock()
        let exchange = PhoneCoderPairingExchange(store: store, now: { clock.date })
        let payload = try await exchange.issue(server: "s", apiVersion: "1", tailnetIdentity: "t")
        clock.date = Date(timeIntervalSince1970: 300)
        let expired = try await exchange.redeem(token: payload.token, name: "Laptop") { _ in true }
        XCTAssertNil(expired)
    }
}
