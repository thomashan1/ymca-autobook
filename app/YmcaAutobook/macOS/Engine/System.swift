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
/// macOS 12 has no SMAppService, so there it's a launch agent in
/// ~/Library/LaunchAgents that starts the app with `-launchedAtLogin YES`.
enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// Started by the macOS 12 launch agent rather than by hand.
    static var launchedAtLogin: Bool { UserDefaults.standard.bool(forKey: "launchedAtLogin") }

    private static let wantedKey = "loginItemWanted"

    /// On unless the user turned it off in Settings. Registered again on every
    /// launch, so it follows the app if it moves or is renamed (the system keeps
    /// the old location otherwise).
    static func registerIfWanted() {
        guard UserDefaults.standard.object(forKey: wantedKey) as? Bool ?? true else { return }
        try? register()
    }

    static func set(_ on: Bool) throws {
        if on { try register() } else { try unregister() }
        UserDefaults.standard.set(on, forKey: wantedKey)
    }

    private static func register() throws {
        if #available(macOS 13, *) {
            // A Mac upgraded from macOS 12 would otherwise start the app twice.
            try? FileManager.default.removeItem(at: agentURL)
            try SMAppService.mainApp.register()
            return
        }
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [exe, "-launchedAtLogin", "YES"],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentURL)
    }

    private static func unregister() throws {
        if #available(macOS 13, *) { try SMAppService.mainApp.unregister(); return }
        if FileManager.default.fileExists(atPath: agentURL.path) { try FileManager.default.removeItem(at: agentURL) }
    }

    private static let agentLabel = "com.thomashan.ymcaautobook.login"
    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }
}
#endif
