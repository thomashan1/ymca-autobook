import SwiftUI

/// Every push wake-up: when it was sent vs. received, app state, whether the
/// saved session worked, and how long the work took. Spike 3's measurement.
struct WakeLogView: View {
    @State private var entries: [WakeEntry] = []

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    Text("No wake-ups yet. Send a test push, or tap Test now.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { e in row(e) }
            }
            .navigationTitle("Wake log")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { Task { await WakeLog.shared.clear() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Test now") {
                        Task { await WakeRunner.run(kind: .manual, payload: [:], appState: "foreground") }
                    }
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: WakeLog.changed)) { _ in
                Task { await reload() }
            }
        }
    }

    private func reload() async { entries = await WakeLog.shared.all() }

    @ViewBuilder private func row(_ e: WakeEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: icon(e.kind))
                Text(e.receivedAt.formatted(date: .abbreviated, time: .standard)).font(.subheadline.bold())
                Spacer()
                Image(systemName: e.error == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(e.error == nil ? .green : .red)
            }
            Text(details(e)).font(.caption).foregroundStyle(.secondary)
            if let err = e.error { Text(err).font(.caption).foregroundStyle(.red) }
        }
    }

    private func icon(_ k: WakeEntry.Kind) -> String {
        switch k {
        case .silentPush: return "bolt.fill"
        case .notificationTap: return "hand.tap.fill"
        case .manual: return "play.fill"
        }
    }

    private func details(_ e: WakeEntry) -> String {
        var parts = [e.kind.rawValue, e.appState]
        if let l = e.latency { parts.append(String(format: "delivered in %.1fs", l)) }
        if let d = e.duration { parts.append(String(format: "took %.1fs", d)) }
        if let p = e.sessionPath { parts.append("session \(p.rawValue)") }
        if let n = e.occurrences, let b = e.booked { parts.append("\(b) booked / \(n) visible") }
        return parts.joined(separator: " · ")
    }
}
