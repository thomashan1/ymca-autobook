import SwiftUI

struct RootView: View {
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var pauses: PausesRepository
    @EnvironmentObject var snapshot: SnapshotRepository
    @EnvironmentObject var bookings: BookingsRepository

    var body: some View {
        TabView {
            WeekView()
                .tabItem { Label("Week", systemImage: "calendar") }
            ClassesView()
                .tabItem { Label("Classes", systemImage: "list.bullet") }
            JobsView()
                .tabItem { Label("Jobs", systemImage: "clock") }
            AwayView()
                .tabItem { Label("Away", systemImage: "mappin.and.ellipse") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
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
