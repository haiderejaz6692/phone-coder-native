import Foundation
import Security

/// Injectable boundary for Security operations; production always uses SecItem.
protocol KeychainOperations {
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SecurityKeychainOperations: KeychainOperations {
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - KeychainStore
// Minimal wrapper around the Security framework for API-key storage. Keys
// are stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so they
// survive backup OFF the device's keychain but stay locked when the device
// is asleep.
//
// Used by the Web Tool's API-key providers and the local API's bearer key.
// Never persists chat history, prompts, or any user content.

public enum KeychainStore {

    /// Account name namespace — keep it scoped to the web-tool so other parts
    /// of the app can use their own keychain space if they want one.
    // Keep this product's keychain namespace separate from the reference app.
    // A sideloaded clone must not read or overwrite the reference app's keys.
    #if PHONE_CODER_APP
    public static let service = "com.haider.phonecoder.webtool"
    #else
    public static let service = "com.mesutcydev.ondevicelas.webtool"
    #endif

    public static func set(
        _ value: String,
        account: String,
        serviceName: String = KeychainStore.service
    ) {
        set(value, account: account, serviceName: serviceName, operations: SecurityKeychainOperations())
    }

    static func set(_ value: String, account: String, serviceName: String = KeychainStore.service,
                    operations: any KeychainOperations) {
        try? setChecked(value, account: account, serviceName: serviceName, operations: operations)
    }

    public static func get(
        account: String,
        serviceName: String = KeychainStore.service
    ) -> String? {
        get(account: account, serviceName: serviceName, operations: SecurityKeychainOperations())
    }

    static func get(account: String, serviceName: String = KeychainStore.service,
                    operations: any KeychainOperations) -> String? {
        try? getChecked(account: account, serviceName: serviceName, operations: operations)
    }

    public static func delete(
        account: String,
        serviceName: String = KeychainStore.service
    ) {
        delete(account: account, serviceName: serviceName, operations: SecurityKeychainOperations())
    }

    static func delete(account: String, serviceName: String = KeychainStore.service,
                       operations: any KeychainOperations) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: serviceName,
                                    kSecAttrAccount as String: account]
        _ = operations.delete(query)
    }

    public struct CheckedError: Error {
        public let status: OSStatus
    }

    public static func setChecked(_ value: String, account: String, serviceName: String) throws {
        try setChecked(value, account: account, serviceName: serviceName, operations: SecurityKeychainOperations())
    }

    static func setChecked(_ value: String, account: String, serviceName: String,
                           operations: any KeychainOperations) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: serviceName,
                                    kSecAttrAccount as String: account]
        let status = operations.update(query, attributes: [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = operations.add(attributes)
            guard addStatus == errSecSuccess else { throw CheckedError(status: addStatus) }
        } else if status != errSecSuccess {
            throw CheckedError(status: status)
        }
    }

    public static func getChecked(account: String, serviceName: String) throws -> String? {
        try getChecked(account: account, serviceName: serviceName, operations: SecurityKeychainOperations())
    }

    static func getChecked(account: String, serviceName: String, operations: any KeychainOperations) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: serviceName,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        let (status, data) = operations.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CheckedError(status: status) }
        guard let data, let value = String(data: data, encoding: .utf8) else {
            throw CheckedError(status: errSecDecode)
        }
        return value
    }

    /// Removes every web-tool API key stored under this service namespace.
    static func deleteAll() {
        for account in knownAccounts {
            delete(account: account)
        }
    }

    private static let knownAccounts = [
        "brave.apiKey",
        "tavily.apiKey",
        "exa.apiKey",
        "localAPI.bearerKey",
    ]

    public static func has(
        account: String,
        serviceName: String = KeychainStore.service
    ) -> Bool {
        get(account: account, serviceName: serviceName) != nil
    }
}
