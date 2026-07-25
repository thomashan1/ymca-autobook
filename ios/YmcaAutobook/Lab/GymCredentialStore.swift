import Foundation
import Security

/// LAB — Keychain storage for the gym login and the harvested Fisikal session.
///
/// Deliberately **stricter** than the app's existing `KeychainStore` (which holds
/// the GitHub PAT):
///
/// - `AfterFirstUnlock` — readable during a locked background run. The whole
///   point is booking at 9:45am with the phone in a pocket; `WhenUnlocked` would
///   fail at exactly the moment it matters.
/// - `ThisDeviceOnly` — never syncs to iCloud Keychain and never lands in a
///   backup. The gym password stays on this one device and is never transmitted
///   anywhere except to egym's own login page.
enum GymCredentialStore {
    private static let service = "com.thomashan.ymcaautobook.gym"

    // MARK: Generic item helpers

    private static func write(_ account: String, _ data: Data) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func read(_ account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    // MARK: Credentials

    static func saveCredentials(username: String, password: String) {
        write("username", Data(username.utf8))
        write("password", Data(password.utf8))
    }

    static var username: String? { read("username").flatMap { String(data: $0, encoding: .utf8) } }
    static var password: String? { read("password").flatMap { String(data: $0, encoding: .utf8) } }
    static var hasCredentials: Bool { username?.isEmpty == false && password?.isEmpty == false }

    // MARK: Session (cookies + CSRF)

    static func saveSession(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        write("session", data)
    }

    static var session: StoredSession? {
        read("session").flatMap { try? JSONDecoder().decode(StoredSession.self, from: $0) }
    }

    static func clearSession() { delete("session") }

    static func clearAll() {
        ["username", "password", "session"].forEach(delete)
    }
}

/// A harvested Fisikal session: just enough to replay authenticated requests on
/// a plain `URLSession` — no browser needed at booking time.
struct StoredSession: Codable {
    struct Cookie: Codable {
        let name: String
        let value: String
        let domain: String
    }

    var cookies: [Cookie]
    var csrf: String
    var capturedAt: Date

    var ageHours: Double { Date().timeIntervalSince(capturedAt) / 3600 }

    /// Cookie header scoped to the Fisikal host — the same shaping the Python
    /// TTL probe proved works without a browser.
    var cookieHeader: String {
        let scoped = cookies.filter { $0.domain.contains("fisikal") }
        let use = scoped.isEmpty ? cookies : scoped
        return use.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}
