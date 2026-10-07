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

    /// Turn it on once, the first time the app runs; after that the user's
    /// choice in Settings sticks, including turning it off.
    static func enableOnFirstLaunch() {
        let key = "loginItemDefaulted"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
