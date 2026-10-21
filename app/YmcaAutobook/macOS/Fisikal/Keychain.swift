#if os(macOS)
import Foundation
import Security

/// Generic-password items in this Mac's login Keychain. Never synced or exported.
enum Keychain {
    // The old Mac app's service name, kept so the saved login carries over.
    private static let service = "com.thomashan.ybooker.mac"

    static func set(_ value: Data, for key: String) {
        if MacSample.active { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = value
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> Data? {
        if MacSample.active { return nil }   // screenshot mode: no saved login
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(_ key: String) {
        if MacSample.active { return }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ] as CFDictionary)
    }

    static func setString(_ value: String, for key: String) { set(Data(value.utf8), for: key) }
    static func string(_ key: String) -> String? { get(key).flatMap { String(data: $0, encoding: .utf8) } }
}
#endif
