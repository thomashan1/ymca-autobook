#if os(macOS)
import Foundation

/// The Mac app used to be its own app ("Y Booker", com.thomashan.ybooker.mac).
/// Its settings move over once; its files (Application Support/YBookerMac) and
/// Keychain items (same service name) are used where they are.
enum LegacySettings {
    static let oldBundleId = "com.thomashan.ybooker.mac"
    private static let doneKey = "migratedFromYBookerMac"

    static func migrate(into defaults: UserDefaults = .standard,
                        from old: [String: Any]? = UserDefaults.standard.persistentDomain(forName: oldBundleId)) {
        guard !defaults.bool(forKey: doneKey) else { return }
        for (k, v) in old ?? [:] where defaults.object(forKey: k) == nil {
            defaults.set(v, forKey: k)
        }
        defaults.set(true, forKey: doneKey)
    }
}
#endif
