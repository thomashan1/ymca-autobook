import SwiftUI

@main
struct YmcaAutobookApp: App {
    @StateObject private var auth = AuthStore()
    @StateObject private var classes = ClassesRepository()
    @StateObject private var pauses = PausesRepository()
    @StateObject private var swaps = SwapsRepository()
    @StateObject private var snapshot = SnapshotRepository()
    @StateObject private var bookings = BookingsRepository()
    @StateObject private var fullClasses = FullRepository()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(classes)
                .environmentObject(pauses)
                .environmentObject(swaps)
                .environmentObject(snapshot)
                .environmentObject(bookings)
                .environmentObject(fullClasses)
                .tint(Theme.accent)
        }
    }
}
