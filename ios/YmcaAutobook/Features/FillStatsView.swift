import SwiftUI

/// How fast classes fill once their booking window opens — every class at both
/// branches, from the daily fill history. Opened from the Classes tab.
struct FillStatsView: View {
    @EnvironmentObject var stats: FillStatsRepository
    @EnvironmentObject var classes: ClassesRepository

    enum Filter: String, CaseIterable, Identifiable {
        case mine = "Mine", fast = "Fill fast", all = "All"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .mine
    @State private var search = ""

    private let order = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private func isMine(_ s: FillStatsRepository.Slot) -> Bool {
        classes.classes.contains { stats.stats(for: $0)?.key == s.key }
    }

    private var rows: [FillStatsRepository.Slot] {
        let q = search.lowercased()
        return stats.slots.filter { s in
            switch filter {
            case .mine: if !isMine(s) { return false }
            case .fast: if !s.fillsFast { return false }
            case .all: break
            }
            return q.isEmpty || s.name.lowercased().contains(q)
        }
        .sorted {
            filter == .fast
                ? ($0.median_fill_s ?? .infinity) < ($1.median_fill_s ?? .infinity)
                : (order.firstIndex(of: $0.weekday) ?? 9, $0.start) < (order.firstIndex(of: $1.weekday) ?? 9, $1.start)
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("How long each class takes to fill after its booking window opens (167 h before class), over the last \(stats.windowWeeks) weeks. From the YMCA's own \"filled at\" times, refreshed daily."
                     + (stats.updatedAt.map { " Updated \($0.formatted(.relative(presentation: .named)))." } ?? ""))
            }
            if rows.isEmpty {
                Text(stats.slots.isEmpty ? "No stats yet — they appear after the next daily schedule snapshot."
                                         : "No classes match.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { s in
                StatsRow(slot: s, mine: isMine(s))
            }
        }
        .navigationTitle("Fill speed")
        .searchable(text: $search, prompt: "Search classes")
        .refreshable { await stats.load() }
        .overlay { if let e = stats.error { Text(e).font(.footnote).foregroundStyle(.red).padding() } }
    }
}

private struct StatsRow: View {
    let slot: FillStatsRepository.Slot
    let mine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(slot.name).font(.body.weight(mine ? .semibold : .regular))
                if mine { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.caption) }
                Spacer()
                Text(slot.filled == 0 ? "never full" : FillStatsRepository.duration(slot.median_fill_s))
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(slot.fillsFast ? .red : slot.filled == 0 ? .secondary : .primary)
            }
            HStack(spacing: 8) {
                Text("\(slot.weekday) \(slot.start) · \(slot.branch)")
                Spacer()
                Text("full \(slot.filled)/\(slot.weeks) wk")
                if let f = slot.fastest_fill_s, slot.filled > 1 { Text("fastest \(FillStatsRepository.duration(f))") }
                if slot.median_waitlist > 0 { Text("waitlist ~\(slot.median_waitlist)") }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
