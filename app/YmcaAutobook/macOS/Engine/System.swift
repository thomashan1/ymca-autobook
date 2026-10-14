#if os(macOS)
import Foundation
import ServiceManagement
import UserNotifications

/// Local notifications: one per opening once its follow-up reads are in, plus
/// a heads-up if the YMCA can't be reached.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Open at login, via the system's own Login Items (System Settings → General →
/// Login Items). Registers this exact app bundle where it currently lives.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    private static let wantedKey = "loginItemWanted"

    /// On unless the user turned it off in Settings. Registered again on every
    /// launch, so it follows the app if it moves or is renamed (the system keeps
    /// the old location otherwise).
    static func registerIfWanted() {
        guard UserDefaults.standard.object(forKey: wantedKey) as? Bool ?? true else { return }
        try? SMAppService.mainApp.register()
    }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        UserDefaults.standard.set(on, forKey: wantedKey)
    }
}
#endif
