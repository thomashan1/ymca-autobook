import SwiftUI
import Combine

/// Scheduled bookings with live 167h countdowns + a recent run feed from the
/// Actions API. "Book now" fires a one-off `workflow_dispatch` on book.yml.
struct JobsView: View {
    @EnvironmentObject var classes: ClassesRepository
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Derive the next open instant for each class from its weekday/start.
    private var jobs: [BookingJob] {
        classes.classes.compactMap { c in
            guard let opens = nextOpen(for: c) else { return nil }
            return BookingJob(classKey: c.key, className: c.name, weekday: c.weekday,
                              classDate: opens.classDate, opensAt: opens.opensAt, state: .queued)
        }
        .sorted { $0.opensAt < $1.opensAt }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Next up · opens 167h before start") {
                    ForEach(jobs) { JobRow(job: $0, now: now) }
                }
            }
            .navigationTitle("Scheduled Jobs")
            .onReceive(tick) { now = $0 }
            .refreshable { await classes.load() }
        }
    }

    private func nextOpen(for c: GymClass) -> (classDate: Date, opensAt: Date)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Config.timeZone
        let parts = c.start.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        // Next occurrence of this weekday at the class time.
        let targetWeekday = c.weekday.order + 2 // Calendar: Sun=1..Sat=7; Mon=2
        var comps = DateComponents()
        comps.weekday = ((targetWeekday - 1) % 7) + 1
        comps.hour = parts[0]; comps.minute = parts[1]
        guard let classDate = cal.nextDate(after: Date(), matching: comps,
                                           matchingPolicy: .nextTime) else { return nil }
        let opensAt = cal.date(byAdding: .hour, value: -Config.bookOpenLeadHours, to: classDate)!
        return (classDate, opensAt)
    }
}

private struct JobRow: View {
    let job: BookingJob
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(job.className) · \(job.weekday.rawValue)").font(.body.weight(.medium))
                Spacer()
                Text(countdownText).font(.subheadline.weight(.bold)).monospacedDigit()
                    .foregroundStyle(Theme.accent)
            }
            Text("Opens \(job.opensAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var countdownText: String {
        let secs = max(0, Int(job.opensAt.timeIntervalSince(now)))
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
