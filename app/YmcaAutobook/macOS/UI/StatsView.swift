#if os(macOS)
import SwiftUI

/// Fill history per weekly class slot: how often it fills, how fast, waitlists,
/// and — for your own classes, which the Mac samples every 3 s after opening —
/// how many people had signed up by 10 / 20 / 30 / 60 seconds.
struct StatsView: View {
    @ObservedObject var engine: Engine
    @State private var search = ""
    @State private var onlyMine = true
    @State private var onlyFilling = false

    private let order = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search classes", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Toggle("Only mine", isOn: $onlyMine)
                Toggle("Only classes that fill", isOn: $onlyFilling)
                Spacer()
            }
            Table(rows) {
                TableColumn("Class") { s in Text(s.name).bold(isMine(s)) }.width(min: 140, ideal: 170)
                TableColumn("Slot") { s in Text("\(s.weekday) \(s.start) · \(s.branch)") }.width(min: 150, ideal: 160)
                TableColumn("Filled") { s in Text("\(s.filledWeeks) of \(s.weeks) wk").monospacedDigit() }.width(80)
                TableColumn("Typical fill") { s in
                    Text(duration(s.medianFill)).monospacedDigit()
                        .foregroundStyle((s.medianFill ?? .infinity) <= 60 ? .red : .primary)
                }.width(80)
                TableColumn("Fastest") { s in Text(duration(s.fastestFill)).monospacedDigit() }.width(65)
                TableColumn("≤ 1 min") { s in
                    Text(s.weeks == 0 ? "—" : "\(Int((Double(s.filledWithinMinute) / Double(s.weeks) * 100).rounded()))%")
                        .monospacedDigit()
                }.width(55)
                TableColumn("Waitlist") { s in Text(s.medianWaitlist.map(String.init) ?? "—").monospacedDigit() }.width(55)
                TableColumn("Signed up by 10s · 20s · 30s · 60s") { s in
                    Text(s.signupsBy.isEmpty ? "—"
                         : [10, 20, 30, 60].map { t in s.signupsBy[t].map(String.init) ?? "–" }.joined(separator: " · ")
                            + "  (\(s.curveWeeks) wk)")
                        .monospacedDigit().foregroundStyle(s.signupsBy.isEmpty ? .secondary : .primary)
                }
            }
            .overlay {
                if engine.history.isEmpty {
                    Text("Building history — the first re-plan backfills about 4 weeks.").foregroundStyle(.secondary)
                }
            }
            Text("Fill times come from the YMCA's own \"filled at\" timestamp, for every class at both branches. Signup counts by 10/20/30/60 s come from the Mac sampling your classes every 3 s after each opening (it starts 2 s in, so it never competes with booking). Red = typically full within a minute.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var rows: [SlotStats] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return engine.slotStats().filter { s in
            (!onlyMine || isMine(s)) && (!onlyFilling || s.filledWeeks > 0)
                && (q.isEmpty || s.name.lowercased().contains(q))
        }
        .sorted { (order.firstIndex(of: $0.weekday) ?? 9, $0.start, $0.name) < (order.firstIndex(of: $1.weekday) ?? 9, $1.start, $1.name) }
    }

    private func isMine(_ s: SlotStats) -> Bool { engine.classes.contains { $0.slotKey == s.id } }

    private func duration(_ seconds: Double?) -> String { FillSpeed.duration(seconds) }
}
#endif
