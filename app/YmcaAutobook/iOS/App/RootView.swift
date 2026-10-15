#if os(iOS)
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
            ClassesTab()
                .tabItem { Label("Classes", systemImage: "list.bullet") }.tag(1)
            UpcomingTab()
                .tabItem { Label("Upcoming", systemImage: "clock") }.tag(2)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
        }
        // Back from Classes (Book): the Week view should show what was just booked or cancelled.
        .onChange(of: tab) { old, _ in
            if old == 1 { Task { await bookings.load() } }
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

/// Book any single class, the weekly lineup, or how fast classes fill. Booking
/// single classes goes through the Mac, so GitHub mode has no Book segment.
private struct ClassesTab: View {
    @EnvironmentObject var auth: AuthStore
    // Launch arg `-classesSegment weekly|fill` picks the segment (for screenshots).
    @AppStorage("classesSegment") private var segment = "book"

    private var canBook: Bool { auth.isCloud || SampleMode.active }
    private var shown: String { segment == "book" && !canBook ? "weekly" : segment }

    var body: some View {
        NavigationStack {
            Group {
                switch shown {
                case "book": BookView(embedded: true)
                case "fill": FillStatsView()
                default: ClassesView(embedded: true)
                }
            }
            // A large title would scroll under the segment bar and blur.
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                SegmentBar(selection: Binding(get: { shown }, set: { segment = $0 }),
                           options: (canBook ? [("book", "Book")] : []) + [("weekly", "Weekly"), ("fill", "Fill speed")])
            }
        }
    }
}

/// When each booking opens and how it went, and the days off.
private struct UpcomingTab: View {
    @AppStorage("upcomingSegment") private var segment = "openings"

    var body: some View {
        NavigationStack {
            Group {
                if segment == "away" { AwayView(embedded: true) } else { JobsView(embedded: true) }
            }
            // A large title would scroll under the segment bar and blur.
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                SegmentBar(selection: $segment, options: [("openings", "Openings"), ("away", "Away")])
            }
        }
    }
}

private struct SegmentBar: View {
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        Picker("Show", selection: $selection) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}
#endif
