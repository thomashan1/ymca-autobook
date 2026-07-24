import SwiftUI

/// Forward-looking schedule. A two-week calendar grid sits on top (tap to open a
/// zoomable full-screen view); below it, a dated agenda grouped into This week /
/// Next week with prominent dividers. Past classes are hidden from the agenda
/// and dimmed in the grid; pause days are marked skipped. End times come from
/// the snapshot.
struct WeekView: View {
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var pauses: PausesRepository
    @EnvironmentObject var snapshot: SnapshotRepository

    private static let daysAhead = 14
    @State private var showZoom = false

    private var cal: Calendar { CalendarHelper.pacific }

    private struct Day: Identifiable {
        let date: Date
        let items: [GymClass]
        var id: TimeInterval { date.timeIntervalSince1970 }
    }

    private var days: [Day] {
        let now = Date()
        let today = cal.startOfDay(for: now)
        var out: [Day] = []
        for offset in 0..<Self.daysAhead {
            guard let date = cal.date(byAdding: .day, value: offset, to: today),
                  let wd = CalendarHelper.weekday(of: date) else { continue }
            let items = classes.classes
                .filter { $0.weekday == wd }
                .filter { CalendarHelper.startDate($0.start, on: date).map { $0 >= now } ?? true }
                .sorted { $0.start < $1.start }
            if !items.isEmpty { out.append(Day(date: date, items: items)) }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TwoWeekGrid(cellFont: 9, labelFont: 11)
                        .contentShape(Rectangle())
                        .onTapGesture { showZoom = true }
                        .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 6, trailing: 10))
                    Text("Tap the calendar to zoom")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 8, trailing: 10))
                }

                let thisWeek = days.filter { weekIndex(of: $0.date) == 0 }
                let nextWeek = days.filter { weekIndex(of: $0.date) >= 1 }
                if !thisWeek.isEmpty {
                    weekDivider("This week")
                    ForEach(thisWeek) { daySection($0) }
                }
                if !nextWeek.isEmpty {
                    weekDivider("Next week")
                    ForEach(nextWeek) { daySection($0) }
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
            .fullScreenCover(isPresented: $showZoom) { CalendarZoomSheet() }
        }
    }

    // MARK: Agenda pieces

    private func weekIndex(of date: Date) -> Int {
        guard let thisMon = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return 0 }
        let days = cal.dateComponents([.day], from: thisMon, to: cal.startOfDay(for: date)).day ?? 0
        return max(0, days / 7)
    }

    private func weekDivider(_ title: String) -> some View {
        Section {
            Text(title.uppercased())
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(Theme.accent.opacity(0.14))
        }
    }

    private func daySection(_ day: Day) -> some View {
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
}

// MARK: - Shared calendar date helpers

enum CalendarHelper {
    static var pacific: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Config.timeZone
        c.firstWeekday = 2 // Monday
        return c
    }

    static func weekday(of date: Date) -> Weekday? {
        let wd = pacific.component(.weekday, from: date)
        let order = (wd + 5) % 7 // Mon(2)->0 … Sat(7)->5, Sun(1)->6
        return Weekday.allCases.first { $0.order == order }
    }

    static func startDate(_ hhmm: String, on date: Date) -> Date? {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return pacific.date(bySettingHour: p[0], minute: p[1], second: 0, of: date)
    }
}

// MARK: - Two-week calendar grid (reused inline + zoomed)

private struct TwoWeekGrid: View {
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var pauses: PausesRepository

    var cellFont: CGFloat
    var labelFont: CGFloat

    private var weeks: [[Date]] {
        let cal = CalendarHelper.pacific
        guard let thisMon = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        return (0..<2).map { w in
            (0..<5).compactMap { d in cal.date(byAdding: .day, value: w * 7 + d, to: thisMon) }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if weeks.indices.contains(0) { weekRow(weeks[0], title: "This week") }
            Rectangle().fill(Theme.accent.opacity(0.5)).frame(height: 2)
            if weeks.indices.contains(1) { weekRow(weeks[1], title: "Next week") }
        }
    }

    private func weekRow(_ week: [Date], title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: labelFont - 1, weight: .heavy)).foregroundStyle(Theme.accent)
            HStack(alignment: .top, spacing: 5) {
                ForEach(week, id: \.self) { date in dayColumn(date) }
            }
        }
    }

    private func dayColumn(_ date: Date) -> some View {
        let items = CalendarHelper.weekday(of: date).map { w in
            classes.classes.filter { $0.weekday == w }.sorted { $0.start < $1.start }
        } ?? []
        return VStack(spacing: 4) {
            VStack(spacing: 1) {
                Text(date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: labelFont, weight: .bold))
                Text(date.formatted(.dateTime.month(.defaultDigits).day()))
                    .font(.system(size: labelFont - 2)).foregroundStyle(.secondary)
            }
            ForEach(items) { c in
                GridCell(gymClass: c,
                         away: pauses.isAway(date, classKey: c.key),
                         past: CalendarHelper.startDate(c.start, on: date).map { $0 < Date() } ?? false,
                         font: cellFont)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct GridCell: View {
    let gymClass: GymClass
    let away: Bool
    let past: Bool
    let font: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(gymClass.start).font(.system(size: font, weight: .bold)).monospacedDigit()
            Text(gymClass.name).font(.system(size: font)).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(5)
        .background(
            (away ? Theme.away.opacity(0.12) : Theme.color(for: gymClass.branch).opacity(0.14)),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .foregroundStyle(away ? Theme.away : .primary)
        .strikethrough(away, color: Theme.away)
        .opacity(past ? 0.35 : (away ? 0.6 : 1))
    }
}

// MARK: - Zoomable full-screen calendar

private struct CalendarZoomSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                TwoWeekGrid(cellFont: 13, labelFont: 15)
                    .frame(minWidth: UIScreen.main.bounds.width - 24)
                    .padding()
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: (UIScreen.main.bounds.width - 24) * scale,
                           alignment: .topLeading)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale = min(4, max(1, $0)) }
                    )
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset zoom") { withAnimation { scale = 1 } }.disabled(scale == 1)
                }
            }
        }
    }
}

// MARK: - Agenda row

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
                    if gymClass.isTrial { badge("Trial", Theme.queued) }
                    if away { badge("Skipped", Theme.away) }
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
