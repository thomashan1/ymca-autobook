#if os(iOS)
import SwiftUI

struct RootView: View {
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var awayRanges: AwayRepository
    @EnvironmentObject var swaps: SwapsRepository
    @EnvironmentObject var snapshot: SnapshotRepository
    @EnvironmentObject var bookings: BookingsRepository
    @EnvironmentObject var fullClasses: FullRepository
    @EnvironmentObject var fillStats: FillStatsRepository
    @Environment(\.scenePhase) private var scenePhase

    // Initial tab, overridable via launch arg `-screenshotTab N` (for screenshots).
    @State private var tab = UserDefaults.standard.integer(forKey: "screenshotTab")

    var body: some View {
        TabView(selection: $tab) {
            ScheduleView()
                .tabItem { Label("Schedule", systemImage: "calendar") }.tag(0)
            ClassesView()
                .tabItem { Label("Classes", systemImage: "list.bullet") }.tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
        // Back from Classes: the Schedule should show what was just added or booked.
        .onChange(of: tab) { old, _ in
            if old == 1 { Task { await bookings.load() } }
        }
        .task(id: "\(auth.hasToken)|\(auth.source.rawValue)") {
            // SampleMode (simulator, no token) serves canned data from the
            // repositories, so the tabs are worth loading without a token —
            // otherwise the sample lineup could never actually be seen.
            guard auth.isConnected || SampleMode.active else { return }
            await classes.load()
            await awayRanges.load()
            await swaps.load()
            await snapshot.load()
            await bookings.load()
            await fullClasses.load()
            await fillStats.load()
        }
        // A booking alert from the Mac means there's something new to show.
        .onReceive(NotificationCenter.default.publisher(for: .cloudChanged)) { _ in reloadFromMac() }
        // So does coming back to the app: the Mac may have booked while it was
        // in the background, and not everyone opens it from the alert.
        .onChange(of: scenePhase) { _, phase in if phase == .active { reloadFromMac() } }
        .sheet(isPresented: .constant(!auth.isConnected && !SampleMode.active)) {
            SettingsView(onboarding: true)
                .interactiveDismissDisabled()
        }
    }

    private func reloadFromMac() {
        guard auth.isCloud else { return }
        Task {
            await CloudSource.shared.refresh()
            await classes.load(); await awayRanges.load(); await swaps.load()
            await bookings.load(); await fullClasses.load(); await fillStats.load()
        }
    }
}
#endif
