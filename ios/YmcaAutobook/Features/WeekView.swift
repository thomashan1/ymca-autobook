import SwiftUI

/// Forward-looking schedule: every class the bot would book over the next two
/// weeks, grouped by date. Past classes are hidden; days in a pause are shown
/// but clearly marked as skipped. Durations/end times come from the snapshot.
struct WeekView: View {
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var pauses: PausesRepository
    @EnvironmentObject var snapshot: SnapshotRepository

    private static let daysAhead = 14

    private struct Day: Identifiable {
        let date: Date
        let items: [GymClass]
        var id: TimeInterval { date.timeIntervalSince1970 }
    }

    private var days: [Day] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Config.timeZone
        let now = Date()
        let today = cal.startOfDay(for: now)
        var out: [Day] = []
        for offset in 0..<Self.daysAhead {
            guard let date = cal.date(byAdding: .day, value: offset, to: today),
                  let wd = Self.weekday(of: date, cal: cal) else { continue }
            let items = classes.classes
                .filter { $0.weekday == wd }
                .filter { startDate($0, on: date, cal: cal).map { $0 >= now } ?? true } // hide past
                .sorted { $0.start < $1.start }
            if !items.isEmpty { out.append(Day(date: date, items: items)) }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(days) { day in
                    Section {
                        ForEach(day.items) { c in
                            ClassRow(gymClass: c,
                                     away: pauses.isAway(day.date, classKey: c.key),
                                     endTime: snapshot.endTime(for: c),
                                     minutes: snapshot.minutes(for: c))
                        }
                    } header: {
                        Text(day.date.formatted(.dateTime.weekday(.wide).month().day()))
                    }
                }
                if days.isEmpty {
                    Text("No upcoming classes in the next two weeks.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("This & Next Week")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await classes.load()
                await pauses.load()
                await snapshot.load()
            }
        }
    }

    private func startDate(_ c: GymClass, on date: Date, cal: Calendar) -> Date? {
        let p = c.start.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return cal.date(bySettingHour: p[0], minute: p[1], second: 0, of: date)
    }

    /// Our Weekday for a concrete date (Calendar weekday: Sun=1..Sat=7).
    static func weekday(of date: Date, cal: Calendar) -> Weekday? {
        let wd = cal.component(.weekday, from: date)
        let order = (wd + 5) % 7 // Sun(1)->6, Mon(2)->0, ... Sat(7)->5
        return Weekday.allCases.first { $0.order == order }
    }
}

private struct ClassRow: View {
    let gymClass: GymClass
    let away: Bool
    let endTime: String?
    let minutes: Int?

    private var title: String {
        if let m = minutes { return "\(gymClass.name) (\(m)m)" }
        return gymClass.name
    }
    private var timeRange: String {
        if let end = endTime { return "\(gymClass.start)–\(end)" }
        return gymClass.start
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: away ? "moon.zzz.fill" : "checkmark.circle.fill")
                .foregroundStyle(away ? Theme.away : Theme.booked)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .strikethrough(away, color: Theme.away)
                HStack(spacing: 6) {
                    Text(timeRange).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    BranchChip(branch: gymClass.branch)
                    if gymClass.isTrial {
                        badge("Trial", Theme.queued)
                    }
                    if away {
                        badge("Skipped", Theme.away)
                    }
                }
            }
            Spacer()
        }
        .opacity(away ? 0.6 : 1)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
