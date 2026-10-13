import SwiftUI
import UIKit
import UserNotifications

@main
struct YBookerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var data = CloudData.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(data)
                .task { await data.refresh() }
                .onChange(of: phase) { _, p in if p == .active { Task { await data.refresh() } } }
        }
    }
}

/// Registers for pushes (iCloud's change notifications need it) and refreshes
/// when one arrives, so the app is current by the time it's opened.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        app.registerForRemoteNotifications()
        Task { await CloudData.shared.ensureSubscriptions() }
        return true
    }

    func application(_ app: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        await CloudData.shared.refresh()
        return .newData
    }

    // Show booking alerts even while the app is open.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification)
        async -> UNNotificationPresentationOptions {
        Task { await CloudData.shared.refresh() }
        return [.banner, .sound, .list]
    }
}
