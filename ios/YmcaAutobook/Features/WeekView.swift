import SwiftUI

/// This week's booked classes. Two modes: an Agenda list and a Calendar grid
/// that mirrors the summary email `weekly_summary.py` sends. Both are dated to
/// the current Mon–Fri week.
struct WeekView: View {
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var pauses: PausesRepository
    @State private var mode: Mode = .agenda

    enum Mode: String, CaseIterable { case agenda = "Agenda", calendar = "Calendar" }

    private let weekdays: [Weekday] = [.mon, .tue, .wed, .thu, .fri]

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .agenda: agenda
                case .calendar: calendar
                }
            }
            .navigationTitle("This Week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
        }
    }

    // MARK: Agenda

    private func items(on day: Weekday) -> [GymClass] {
        classes.classes.filter { $0.weekday == day }.sorted { $0.start < $1.start }
    }

    private var agenda: some View {
        List {
            ForEach(weekdays, id: \.self) { day in
                let dayItems = items(on: day)
                if !dayItems.isEmpty {
                    Section {
                        ForEach(dayItems) { c in ClassRow(gymClass: c, away: isAway(c, day)) }
                    } header: {
                        Text(Self.longHeader(for: day))
                    }
                }
            }
        }
    }

    // MARK: Calendar grid (email-style), dated

    private var calendar: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 6) {
                ForEach(weekdays, id: \.self) { day in
                    VStack(spacing: 5) {
                        VStack(spacing: 1) {
                            Text(day.rawValue).font(.caption.weight(.bold))
                            Text(Self.shortDate(for: day))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        ForEach(items(on: day)) { c in
                            CalendarCell(gymClass: c, away: isAway(c, day))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(10)
        }
    }

    // MARK: Dates

    private func isAway(_ c: GymClass, _ day: Weekday) -> Bool {
        guard let date = Self.date(of: day) else { return false }
        return pauses.isAway(date, classKey: c.key)
    }

    /// The concrete date for `weekday` in the current Mon–Fri week.
    static func date(of weekday: Weekday) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Config.timeZone
        cal.firstWeekday = 2 // Monday, so the week interval starts on Monday
        let monday = cal.dateInterval(of: .weekOfYear, for: Date())?.start
        return monday.flatMap { cal.date(byAdding: .day, value: weekday.order, to: $0) }
    }

    static func longHeader(for day: Weekday) -> String {
        let s = shortDate(for: day)
        return s.isEmpty ? day.fullName : "\(day.fullName) · \(s)"
    }

    static func shortDate(for day: Weekday) -> String {
        guard let d = date(of: day) else { return "" }
        let f = DateFormatter()
        f.timeZone = Config.timeZone
        f.dateFormat = "M/d"
        return f.string(from: d)
    }
}

private struct ClassRow: View {
    let gymClass: GymClass
    let away: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: away ? "moon.zzz.fill" : "checkmark.circle.fill")
                .foregroundStyle(away ? Theme.away : Theme.booked)
            VStack(alignment: .leading, spacing: 2) {
                Text(gymClass.name)
                    .font(.body.weight(.medium))
                    .strikethrough(away, color: Theme.away)
                HStack(spacing: 6) {
                    Text(gymClass.start).font(.caption).foregroundStyle(.secondary)
                    BranchChip(branch: gymClass.branch)
                    if gymClass.isTrial {
                        Text("Trial").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.queued.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.queued)
                    }
                }
            }
            Spacer()
        }
        .opacity(away ? 0.55 : 1)
    }
}

private struct CalendarCell: View {
    let gymClass: GymClass
    let away: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(gymClass.start).font(.system(size: 10, weight: .bold)).monospacedDigit()
            Text(gymClass.name).font(.system(size: 10)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(
            (away ? Theme.away.opacity(0.12) : Theme.color(for: gymClass.branch).opacity(0.14)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .foregroundStyle(away ? Theme.away : .primary)
        .opacity(away ? 0.55 : 1)
    }
}
