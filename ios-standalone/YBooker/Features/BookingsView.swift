import SwiftUI

/// What you're actually booked into, straight from the YMCA — no GitHub, no snapshots.
struct BookingsView: View {
    @State private var booked: [Occurrence] = []
    @State private var visible = 0
    @State private var status: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                if let status {
                    Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
                }
                ForEach(groupedByDay, id: \.day) { group in
                    Section(group.day) {
                        ForEach(group.items) { o in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.title).font(.headline)
                                Text("\(o.occursAt.formatted(date: .omitted, time: .shortened)) · \(o.location)")
                                    .font(.subheadline)
                                if !o.trainer.isEmpty {
                                    Text(o.trainer).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .overlay { if loading && booked.isEmpty { ProgressView() } }
            .navigationTitle("Bookings")
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private var groupedByDay: [(day: String, items: [Occurrence])] {
        let groups = Dictionary(grouping: booked) { Calendar.current.startOfDay(for: $0.occursAt) }
        return groups.keys.sorted().map { d in
            (d.formatted(.dateTime.weekday(.wide).month().day()),
             groups[d]!.sorted { $0.occursAt < $1.occursAt })
        }
    }

    private func load() async {
        loading = true
        do {
            let r = try await FisikalClient.shared.occurrencesEnsuringSession(allowReloginInQuietWindow: true)
            booked = r.occurrences.filter(\.isJoined)
            visible = r.occurrences.count
            status = "\(booked.count) booked · \(visible) classes visible · session \(r.path.rawValue)"
        } catch {
            status = error.localizedDescription
        }
        loading = false
    }
}
