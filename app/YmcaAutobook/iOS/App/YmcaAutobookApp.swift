#if os(iOS)
import SwiftUI
import UserNotifications


struct YmcaAutobookApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var auth = AuthStore()
    @StateObject private var classes = ClassesRepository()
    @StateObject private var awayRanges = AwayRepository()
    @StateObject private var swaps = SwapsRepository()
    @StateObject private var snapshot = SnapshotRepository()
    @StateObject private var bookings = BookingsRepository()
    @StateObject private var fullClasses = FullRepository()
    @StateObject private var fillStats = FillStatsRepository()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(classes)
                .environmentObject(awayRanges)
                .environmentObject(swaps)
                .environmentObject(snapshot)
                .environmentObject(bookings)
                .environmentObject(fullClasses)
                .environmentObject(fillStats)
                .tint(Theme.accent)
        }
    }
}

extension Notification.Name {
    /// Posted when an iCloud alert arrives from the Mac app.
    static let cloudChanged = Notification.Name("cloudChanged")
}

/// Shows the Mac's booking alerts while the app is open too, and refreshes on them.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if DataSource.isCloud { application.registerForRemoteNotifications() }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        await MainActor.run { NotificationCenter.default.post(name: .cloudChanged, object: nil) }
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { NotificationCenter.default.post(name: .cloudChanged, object: nil) }
    }
}
#endif
