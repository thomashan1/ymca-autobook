import SwiftUI

/// This week's booked classes. Two modes: an Agenda list (the mockup) and a
/// Calendar grid that mirrors the summary email `weekly_summary.py` sends.
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

    private var agenda: some View {
        List {
            ForEach(weekdays, id: \.self) { day in
                let items = classes.classes.filter { $0.weekday == day }
                if !items.isEmpty {
                    Section(day.rawValue) {
                        ForEach(items) { c in ClassRow(gymClass: c, away: isAway(c, day)) }
                    }
                }
            }
        }
    }

    // MARK: Calendar grid (email-style)

    private var calendar: some View {
        GeometryReader { geo in
            let colW = geo.size.width / 5
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                    ForEach(weekdays, id: \.self) { day in
                        Text(day.rawValue)
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    ForEach(weekdays, id: \.self) { day in
                        VStack(spacing: 4) {
                            ForEach(classes.classes.filter { $0.weekday == day }) { c in
                                CalendarCell(gymClass: c, away: isAway(c, day))
                            }
                        }
                        .frame(width: colW - 4, alignment: .top)
                    }
                }
                .padding(8)
            }
        }
    }

    private func isAway(_ c: GymClass, _ day: Weekday) -> Bool {
        // Resolve the concrete date for `day` in the current week before checking.
        guard let date = Self.date(of: day) else { return false }
        return pauses.isAway(date, classKey: c.key)
    }

    static func date(of weekday: Weekday) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Config.timeZone
        let today = Date()
        let monday = cal.dateInterval(of: .weekOfYear, for: today)?.start
        return monday.flatMap { cal.date(byAdding: .day, value: weekday.order, to: $0) }
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
