import SwiftUI

struct RootView: View {
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var pauses: PausesRepository
    @EnvironmentObject var snapshot: SnapshotRepository
    @EnvironmentObject var bookings: BookingsRepository

    // Initial tab, overridable via launch arg `-screenshotTab N` (for screenshots).
    @State private var tab = UserDefaults.standard.integer(forKey: "screenshotTab")

    var body: some View {
        TabView(selection: $tab) {
            WeekView()
                .tabItem { Label("Week", systemImage: "calendar") }.tag(0)
            ClassesView()
                .tabItem { Label("Classes", systemImage: "list.bullet") }.tag(1)
            JobsView()
                .tabItem { Label("Jobs", systemImage: "clock") }.tag(2)
            AwayView()
                .tabItem { Label("Away", systemImage: "mappin.and.ellipse") }.tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
        }
        .task(id: auth.hasToken) {
            guard auth.hasToken else { return }
            await classes.load()
            await pauses.load()
            await snapshot.load()
            await bookings.load()
        }
        .sheet(isPresented: .constant(!auth.hasToken)) {
            SettingsView(onboarding: true)
                .interactiveDismissDisabled()
        }
    }
}
