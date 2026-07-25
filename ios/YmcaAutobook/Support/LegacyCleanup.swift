import Foundation
import Security

/// One-shot removal of Keychain items left by the standalone-engine experiment
/// (#59, decided against — GitHub Actions remains the booking engine).
///
/// The Lab stored the real egym username/password on-device so the app could
/// sign itself in unattended. With that direction dropped, those credentials are
/// live secrets with no purpose, so they're purged rather than left behind —
/// especially since app deletion was observed *not* to clear Keychain items.
enum LegacyCleanup {
    private static let ranKey = "cleanup.gymCredentials.v1"
    private static let service = "com.thomashan.ymcaautobook.gym"

    static func purgeGymCredentialsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: ranKey) else { return }

        for account in ["username", "password", "session"] {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }
        // Spike logs held no secrets, but they're equally purposeless now.
        UserDefaults.standard.removeObject(forKey: "lab.results")
        UserDefaults.standard.removeObject(forKey: "lab.fires")

        UserDefaults.standard.set(true, forKey: ranKey)
    }
}
