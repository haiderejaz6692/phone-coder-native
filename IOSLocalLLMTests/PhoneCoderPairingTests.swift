import XCTest
import Foundation
import Security
@testable import PhoneCoder

private final class MemoryPairingStorage: PhoneCoderPairingStorage {
    var value: String?
    var failWrites = false
    var failReads = false
    func read() throws -> String? {
        if failReads { throw Failure.read }
        return value
    }
    func write(_ value: String) throws {
        if failWrites { throw Failure.write }
        self.value = value
    }
    enum Failure: Error { case read, write }
}

@MainActor
private final class ApprovalGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Bool, Never>?

    init(started: XCTestExpectation) { self.started = started }
    func wait() async -> Bool {
        MainActor.preconditionIsolated()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func resume() { continuation?.resume(returning: true); continuation = nil }
}

private final class TestClock { var date = Date(timeIntervalSince1970: 0) }

final class PhoneCoderPairingTests: XCTestCase {
    // Catches rejecting Unicode joiners or admitting more than 512 UTF-8 bytes.
    func testDirectStoreRejectsNamesOver512UTF8BytesWithoutWriting() async throws {
        let storage = MemoryPairingStorage()
        let store = PhoneCoderPairingStore(storage: storage)
        let boundary = String(repeating: "👨‍👩‍👧‍👦", count: 20) + String(repeating: "a", count: 12)
        XCTAssertEqual(boundary.utf8.count, 512)
        let accepted = try await store.create(name: boundary)
        XCTAssertEqual(accepted.name, boundary)
        let saved = storage.value
        do {
            _ = try await store.create(name: boundary + "a")
            XCTFail("A short grapheme count must not bypass the UTF-8 byte limit")
        } catch PhoneCoderPairingError.invalidName {
            // Expected: rejection occurs before persistence or entropy use.
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(storage.value, saved)
    }

    // Catches permitting embedded C0/C1 controls while allowing Unicode formats.
    func testNamesRejectEmbeddedControlCodesAndKeepNFCAndGraphemeBounds() async throws {
        let storage = MemoryPairingStorage()
        let store = PhoneCoderPairingStore(storage: storage)
        let accepted = try await store.create(name: "  Cafe\u{301}  ")
        XCTAssertEqual(accepted.name, "Café")
        let saved = storage.value
        for scalar in [0x00, 0x09, 0x1F, 0x7F, 0x85, 0x9F] {
            let name = "A" + String(UnicodeScalar(scalar)!) + "B"
            do { _ = try await store.create(name: name); XCTFail("Embedded control accepted: \(scalar)") }
            catch PhoneCoderPairingError.invalidName {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(storage.value, saved)
        }
        do { _ = try await store.create(name: String(repeating: "a", count: 81)); XCTFail("Grapheme bound bypassed") }
        catch PhoneCoderPairingError.invalidName {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(storage.value, saved)
    }

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

    // Catches bypassing injected Security operations or losing persistence across
    // distinct pairing-storage instances sharing one service/account namespace.
    func testKeychainPersistsCredentialsAcrossStoreInstances() async throws {
        let service = "com.haider.phonecoder.pairings.tests." + UUID().uuidString
        let operations = MemorySecurityOperations()
        let storage = PhoneCoderKeychainPairingStorage(service: service, operations: operations)
        let store = PhoneCoderPairingStore(storage: storage)
        let credential = try await store.create(name: "Laptop")
        let restored = PhoneCoderPairingStore(storage: PhoneCoderKeychainPairingStorage(service: service, operations: operations))
        let context = await restored.authenticate(bearer: credential.bearer)
        XCTAssertEqual(context?.name, "Laptop")
        let rotated = try await restored.rotate(id: credential.id)
        let stale = await store.authenticate(bearer: credential.bearer)
        let replacement = await store.authenticate(bearer: rotated.bearer)
        XCTAssertNil(stale)
        XCTAssertEqual(replacement?.id, credential.id)
        try await restored.revoke(id: credential.id)
        let revoked = await store.authenticate(bearer: rotated.bearer)
        XCTAssertNil(revoked)
    }

    func testAuthenticationFailsClosedOnReadAndDecodeErrors() async throws {
        let storage = MemoryPairingStorage()
        let store = PhoneCoderPairingStore(storage: storage)
        let credential = try await store.create(name: "Laptop")
        storage.failReads = true
        let readFailure = await store.authenticate(bearer: credential.bearer)
        XCTAssertNil(readFailure)
        storage.failReads = false
        storage.value = "not valid JSON"
        let decodeFailure = await store.authenticate(bearer: credential.bearer)
        XCTAssertNil(decodeFailure)
    }

    // Catches broken update/add/read/delete behavior, legacy incompatibility,
    // or dropped service/account selectors in the Security query boundary.
    func testCheckedKeychainUpdateLegacyCompatibilityAndNamespaceIsolation() throws {
        let operations = MemorySecurityOperations()
        let account = "regression." + UUID().uuidString
        let isolatedService = "com.haider.phonecoder.tests." + UUID().uuidString
        let webService = KeychainStore.service
        let pairingService = "com.haider.phonecoder.pairings"
        defer {
            for service in [isolatedService, webService, pairingService] {
                KeychainStore.delete(account: account, serviceName: service, operations: operations)
            }
        }
        try KeychainStore.setChecked("first", account: account, serviceName: isolatedService, operations: operations)
        XCTAssertEqual(try KeychainStore.getChecked(account: account, serviceName: isolatedService, operations: operations), "first")
        try KeychainStore.setChecked("second", account: account, serviceName: isolatedService, operations: operations)
        XCTAssertEqual(try KeychainStore.getChecked(account: account, serviceName: isolatedService, operations: operations), "second")
        XCTAssertEqual(KeychainStore.get(account: account, serviceName: isolatedService, operations: operations), "second")
        KeychainStore.set("legacy", account: account, serviceName: isolatedService, operations: operations)
        XCTAssertEqual(try KeychainStore.getChecked(account: account, serviceName: isolatedService, operations: operations), "legacy")
        try KeychainStore.setChecked("web", account: account, serviceName: webService, operations: operations)
        try KeychainStore.setChecked("pairing", account: account, serviceName: pairingService, operations: operations)
        try KeychainStore.setChecked("other account", account: "other", serviceName: isolatedService, operations: operations)
        KeychainStore.delete(account: account, serviceName: isolatedService, operations: operations)
        XCTAssertEqual(try KeychainStore.getChecked(account: "other", serviceName: isolatedService, operations: operations), "other account")
        XCTAssertNil(try KeychainStore.getChecked(account: account, serviceName: isolatedService, operations: operations))
        XCTAssertEqual(try KeychainStore.getChecked(account: account, serviceName: webService, operations: operations), "web")
        XCTAssertEqual(try KeychainStore.getChecked(account: account, serviceName: pairingService, operations: operations), "pairing")
        KeychainStore.delete(account: account, serviceName: webService, operations: operations)
        XCTAssertNil(KeychainStore.get(account: account, serviceName: webService, operations: operations))
        XCTAssertEqual(try KeychainStore.getChecked(account: account, serviceName: pairingService, operations: operations), "pairing")
    }

    // Catches swallowing an unexpected Security status, treating failed reads
    // as absence, or falling back to add after errors other than item-not-found.
    func testCheckedKeychainPropagatesSecurityFailuresAndDecodeErrors() throws {
        let operations = MemorySecurityOperations()
        operations.updateStatus = errSecMissingEntitlement
        XCTAssertThrowsError(try KeychainStore.setChecked("secret", account: "a", serviceName: "s", operations: operations)) {
            XCTAssertEqual(($0 as? KeychainStore.CheckedError)?.status, errSecMissingEntitlement)
        }
        operations.updateStatus = nil
        XCTAssertNil(try KeychainStore.getChecked(account: "a", serviceName: "s", operations: operations))
        operations.addStatus = errSecNotAvailable
        XCTAssertThrowsError(try KeychainStore.setChecked("secret", account: "a", serviceName: "s", operations: operations)) {
            XCTAssertEqual(($0 as? KeychainStore.CheckedError)?.status, errSecNotAvailable)
        }
        operations.addStatus = nil
        try KeychainStore.setChecked("secret", account: "a", serviceName: "s", operations: operations)
        operations.copyResult = (errSecInteractionNotAllowed, nil)
        XCTAssertThrowsError(try KeychainStore.getChecked(account: "a", serviceName: "s", operations: operations)) {
            XCTAssertEqual(($0 as? KeychainStore.CheckedError)?.status, errSecInteractionNotAllowed)
        }
        XCTAssertNil(KeychainStore.get(account: "a", serviceName: "s", operations: operations))
        operations.copyResult = (errSecSuccess, Data([0xFF]))
        XCTAssertThrowsError(try KeychainStore.getChecked(account: "a", serviceName: "s", operations: operations)) {
            XCTAssertEqual(($0 as? KeychainStore.CheckedError)?.status, errSecDecode)
        }
        operations.copyResult = nil
        XCTAssertEqual(try KeychainStore.getChecked(account: "a", serviceName: "s", operations: operations), "secret")
    }

    @MainActor
    func testConcurrentAndSuccessfulExchangeReplayCannotIssueAnotherCredential() async throws {
        let storage = MemoryPairingStorage()
        let store = PhoneCoderPairingStore(storage: storage)
        let exchange = PhoneCoderPairingExchange(store: store)
        let payload = try await exchange.issue(server: "s", apiVersion: "1", tailnetIdentity: "t")
        let started = expectation(description: "approval is suspended")
        let gate = ApprovalGate(started: started)
        let first = Task {
            try await exchange.redeem(token: payload.token, name: "Laptop") { _ in
                MainActor.preconditionIsolated()
                return await gate.wait()
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let competing = try await exchange.redeem(token: payload.token, name: "Other") { _ in
            XCTFail("consumed token requested approval")
            return true
        }
        XCTAssertNil(competing)
        gate.resume()
        let credential = try await first.value
        XCTAssertNotNil(credential)
        let replay = try await exchange.redeem(token: payload.token, name: "Other") { _ in
            XCTFail("successful token requested approval again")
            return true
        }
        XCTAssertNil(replay)
        let clients = try JSONDecoder().decode([PhoneCoderClientCredential].self, from: Data(XCTUnwrap(storage.value).utf8))
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients.first?.id, credential?.id)
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

/// Test-only Security backend. Query selectors and status behavior are modeled
/// below the real KeychainStore logic, so no entitlement or global hook is needed.
private final class MemorySecurityOperations: KeychainOperations {
    private struct Key: Hashable { let service: String; let account: String }
    private var items: [Key: Data] = [:]
    var updateStatus: OSStatus?
    var addStatus: OSStatus?
    var copyResult: (OSStatus, Data?)?

    private func key(_ query: [String: Any]) -> Key? {
        guard query[kSecClass as String] as? String == kSecClassGenericPassword as String,
              let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String else { return nil }
        return Key(service: service, account: account)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        if let updateStatus { return updateStatus }
        guard let key = key(query), let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        guard items[key] != nil else { return errSecItemNotFound }
        items[key] = data
        return errSecSuccess
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        if let addStatus { return addStatus }
        guard let key = key(attributes), let data = attributes[kSecValueData as String] as? Data,
              attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String else { return errSecParam }
        guard items[key] == nil else { return errSecDuplicateItem }
        items[key] = data
        return errSecSuccess
    }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        if let copyResult { return copyResult }
        guard let key = key(query), query[kSecReturnData as String] as? Bool == true,
              query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String else { return (errSecParam, nil) }
        guard let data = items[key] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        guard let key = key(query) else { return errSecParam }
        return items.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
    }
}
