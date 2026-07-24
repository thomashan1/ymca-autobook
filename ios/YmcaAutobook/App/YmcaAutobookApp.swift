import SwiftUI

@main
struct YmcaAutobookApp: App {
    @StateObject private var auth = AuthStore()
    @StateObject private var classes = ClassesRepository()
    @StateObject private var pauses = PausesRepository()
    @StateObject private var snapshot = SnapshotRepository()
    @StateObject private var bookings = BookingsRepository()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(classes)
                .environmentObject(pauses)
                .environmentObject(snapshot)
                .environmentObject(bookings)
                .tint(Theme.accent)
        }
    }
}
