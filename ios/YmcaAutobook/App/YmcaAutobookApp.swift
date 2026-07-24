import SwiftUI

@main
struct YmcaAutobookApp: App {
    @StateObject private var auth = AuthStore()
    @StateObject private var classes = ClassesRepository()
    @StateObject private var pauses = PausesRepository()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(classes)
                .environmentObject(pauses)
                .tint(Theme.accent)
        }
    }
}
