import SwiftUI
import UIKit
import UserNotifications

@main
struct YBookerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { RootView() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let tokenChanged = Notification.Name("APNsTokenChanged")
    /// True when iOS launched us straight into the background (e.g. for a silent
    /// push) rather than the user opening the app — logged with the first wake.
    private var coldBackgroundLaunch = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        coldBackgroundLaunch = application.applicationState == .background
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        UserDefaults.standard.set(deviceToken.map { String(format: "%02x", $0) }.joined(), forKey: "apnsToken")
        UserDefaults.standard.removeObject(forKey: "apnsError")
        NotificationCenter.default.post(name: Self.tokenChanged, object: nil)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set(error.localizedDescription, forKey: "apnsError")
        NotificationCenter.default.post(name: Self.tokenChanged, object: nil)
    }

    // Silent push (content-available: 1). iOS gives ~30s; call the handler when done.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let state = describe(application.applicationState)
        Task {
            await WakeRunner.run(kind: .silentPush, payload: userInfo, appState: state)
            completionHandler(.newData)
        }
    }

    // Visible push while the app is open: still show it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }

    // The fallback path: user tapped a visible (time-sensitive) notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await WakeRunner.run(kind: .notificationTap,
                             payload: response.notification.request.content.userInfo,
                             appState: "tapped")
    }

    private func describe(_ s: UIApplication.State) -> String {
        defer { coldBackgroundLaunch = false }
        switch s {
        case .active: return "foreground"
        case .inactive: return "inactive"
        case .background: return coldBackgroundLaunch ? "background (cold launch)" : "background"
        @unknown default: return "unknown"
        }
    }
}
