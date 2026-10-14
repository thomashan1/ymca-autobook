import SwiftUI

struct RootView: View {
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var pauses: PausesRepository
    @EnvironmentObject var swaps: SwapsRepository
    @EnvironmentObject var snapshot: SnapshotRepository
    @EnvironmentObject var bookings: BookingsRepository
    @EnvironmentObject var fullClasses: FullRepository
    @EnvironmentObject var fillStats: FillStatsRepository

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
        .task(id: "\(auth.hasToken)|\(auth.source.rawValue)") {
            // SampleMode (simulator, no token) serves canned data from the
            // repositories, so the tabs are worth loading without a token —
            // otherwise the sample lineup could never actually be seen.
            guard auth.isConnected || SampleMode.active else { return }
            await classes.load()
            await pauses.load()
            await swaps.load()
            await snapshot.load()
            await bookings.load()
            await fullClasses.load()
            await fillStats.load()
        }
        // A booking alert from the Mac means there's something new to show.
        .onReceive(NotificationCenter.default.publisher(for: .cloudChanged)) { _ in
            guard auth.isCloud else { return }
            Task {
                await CloudSource.shared.refresh()
                await classes.load(); await pauses.load(); await swaps.load()
                await bookings.load(); await fullClasses.load(); await fillStats.load()
            }
        }
        .sheet(isPresented: .constant(!auth.isConnected && !SampleMode.active)) {
            SettingsView(onboarding: true)
                .interactiveDismissDisabled()
        }
    }
}
