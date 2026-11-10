import Foundation
import Security

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
        guard let data = value.data(using: .utf8) else { return }
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        // Try update first; fall back to add.
        let upd: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, upd as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func get(
        account: String,
        serviceName: String = KeychainStore.service
    ) -> String? {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &item) { ptr -> OSStatus in
            SecItemCopyMatching(q as CFDictionary, ptr)
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    public static func delete(
        account: String,
        serviceName: String = KeychainStore.service
    ) {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }

    public struct CheckedError: Error {
        public let status: OSStatus
    }

    public static func setChecked(_ value: String, account: String, serviceName: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: serviceName,
                                    kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CheckedError(status: addStatus) }
        } else if status != errSecSuccess {
            throw CheckedError(status: status)
        }
    }

    public static func getChecked(account: String, serviceName: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: serviceName,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CheckedError(status: status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
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
