import SwiftUI

/// Every opening the Mac has handled: the booking at that second, how late the
/// read landed, and how fast the class filled.
struct LogView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        Table(engine.log.reversed()) {
            TableColumn("Class") { e in
                VStack(alignment: .leading) {
                    Text(e.className).bold()
                    Text(e.occursAt.formatted(.dateTime.weekday().month().day().hour().minute()))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 150, ideal: 180)
            TableColumn("Opened") { e in
                Text(e.openAt.formatted(date: .abbreviated, time: .standard)).monospacedDigit()
            }
            .width(min: 140, ideal: 160)
            TableColumn("Verdict at the opening second") { e in Text(e.verdict) }
                .width(min: 200, ideal: 240)
            TableColumn("Sent / reply") { e in
                Text([e.sendLag, e.fireLag].map { $0.map { String(format: "%+.0f", $0 * 1000) } ?? "—" }
                    .joined(separator: " / ") + " ms").monospacedDigit()
            }
            .width(110)
            TableColumn("Session") { e in Text(e.sessionPath?.rawValue ?? "—") }
                .width(70)
            TableColumn("Filled after") { e in
                Text(e.fillSeconds.map { String(format: "%.0fs", $0) } ?? "not full").monospacedDigit()
            }
            .width(80)
            TableColumn("Follow-ups (full · bookings · waitlist)") { e in
                Text(e.followUps.map { s in
                    "\(Int(s.at.timeIntervalSince(e.openAt)))s: \(s.isFull ? "FULL" : "open") v\(s.lockVersion) wl\(s.waitlist)"
                }.joined(separator: "   "))
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .toolbar {
            Button("Clear log", role: .destructive) { engine.clearLog() }
        }
        .overlay {
            if engine.log.isEmpty {
                Text("Nothing yet — the first entry appears at the next opening.").foregroundStyle(.secondary)
            }
        }
    }
}
