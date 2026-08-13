import SwiftUI

/// Forward-looking schedule merging the recurring classes.yml plan with real
/// bookings (bookings.json) — so actual reservations always appear, even
/// one-offs not in classes.yml. A two-week calendar grid (tap to zoom) sits on
/// top; below, a dated agenda grouped by week with blue dividers. Tap any class
/// for a detail popup. Past classes are hidden from the agenda, dimmed in the
/// grid; pause days marked skipped.
struct WeekView: View {
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var pauses: PausesRepository
    @EnvironmentObject var swaps: SwapsRepository
    @EnvironmentObject var snapshot: SnapshotRepository
    @EnvironmentObject var bookings: BookingsRepository
    @EnvironmentObject var fullClasses: FullRepository

    private static let daysAhead = 14
    @State private var showZoom = false
    @State private var detail: ClassDetail?

    private var cal: Calendar { CalendarHelper.pacific }

    private struct Day: Identifiable {
        let date: Date
        let items: [Occurrence]
        var id: TimeInterval { date.timeIntervalSince1970 }
    }

    private var days: [Day] {
        let now = Date()
        let today = cal.startOfDay(for: now)
        var out: [Day] = []
        for offset in 0..<Self.daysAhead {
            guard let date = cal.date(byAdding: .day, value: offset, to: today),
                  let wd = CalendarHelper.weekday(of: date) else { continue }
            let items = Occurrence.build(date: date, weekday: wd,
                                         classes: classes, bookings: bookings, snapshot: snapshot,
                                         fullClasses: fullClasses)
                .filter { CalendarHelper.startDate($0.start, on: date).map { $0 >= now } ?? true }
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
                    Text("Tap the calendar to zoom · tap a class for details")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 8, trailing: 10))
                }

                let groups = Dictionary(grouping: days) { weekIndex(of: $0.date) }
                ForEach(groups.keys.sorted(), id: \.self) { wi in
                    weekDivider(weekLabel(wi))
                    ForEach(groups[wi] ?? []) { daySection($0) }
                }
                if days.isEmpty {
                    Text("No upcoming classes in the next two weeks.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("This & Next Week")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await classes.load(); await pauses.load(); await swaps.load()
                await snapshot.load(); await bookings.load()
                await fullClasses.load()
            }
            .fullScreenCover(isPresented: $showZoom) { CalendarZoomSheet() }
            .sheet(item: $detail) { ClassDetailSheet(detail: $0) }
        }
    }

    // MARK: Agenda pieces

    private func weekIndex(of date: Date) -> Int { CalendarHelper.weekIndex(of: date) }

    private func weekLabel(_ wi: Int) -> String { CalendarHelper.weekLabel(wi) }

    private func weekDivider(_ title: String) -> some View { WeekDivider(title: title) }

    private func daySection(_ day: Day) -> some View {
        Section {
            ForEach(day.items) { occ in
                let away = occ.classKey.map { pauses.isAway(day.date, classKey: $0) } ?? false
                let role = swaps.role(name: occ.name, start: occ.start,
                                      classKey: occ.classKey, on: day.date)
                Button {
                    detail = occ.detail(on: day.date)
                } label: {
                    OccurrenceRow(occ: occ, away: away, swapRole: role)
                }
                .buttonStyle(.plain)
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

    /// 0 = the Monday-anchored week containing today, 1 = next week, and so on.
    /// Dates before this week clamp to 0 rather than going negative — every
    /// screen using this shows forward-looking dates only.
    static func weekIndex(of date: Date) -> Int {
        let cal = pacific
        guard let thisMon = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return 0 }
        let days = cal.dateComponents([.day], from: thisMon, to: cal.startOfDay(for: date)).day ?? 0
        return max(0, days / 7)
    }

    static func weekLabel(_ wi: Int) -> String {
        switch wi {
        case 0: return "This week"
        case 1: return "Next week"
        default:
            let cal = pacific
            if let thisMon = cal.dateInterval(of: .weekOfYear, for: Date())?.start,
               let mon = cal.date(byAdding: .day, value: wi * 7, to: thisMon) {
                return "Week of " + mon.formatted(.dateTime.month().day())
            }
            return "Later"
        }
    }

    /// `weekLabel` spelled out as being about classes. A Jobs row names two
    /// dates — the class and the earlier instant its booking opens — so a bare
    /// "Next week" there would be genuinely ambiguous about which one the
    /// heading groups by. The Week view needs no such help; it lists classes.
    static func weekLabelForClasses(_ wi: Int) -> String {
        switch wi {
        case 0: return "This week's classes"
        case 1: return "Next week's classes"
        default: return "Classes " + weekLabel(wi).lowercased()
        }
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

// MARK: - A class occurrence on a date (recurring plan ∪ real booking)

struct Occurrence: Identifiable {
    let name: String
    let start: String
    let end: String?
    let branch: Branch
    let classKey: String?     // classes.yml key; nil when this is a booking-only occurrence
    let booked: Bool
    let room: String?
    let instructor: String?
    let isTrial: Bool
    /// Filled up before the bot could book it — distinct from merely unbooked,
    /// because this one will not resolve itself.
    let isFull: Bool

    var id: String { name + "|" + start }

    /// Merge the recurring schedule for `weekday` with real bookings on `date`.
    @MainActor
    static func build(date: Date, weekday: Weekday,
                      classes: ClassesRepository,
                      bookings: BookingsRepository,
                      snapshot: SnapshotRepository,
                      fullClasses: FullRepository) -> [Occurrence] {
        var map: [String: Occurrence] = [:]
        for c in classes.classes where c.weekday == weekday {
            map["\(c.name)|\(c.start)"] = Occurrence(
                name: c.name, start: c.start, end: snapshot.endTime(for: c),
                branch: c.branch, classKey: c.key, booked: false,
                room: nil, instructor: nil, isTrial: c.isTrial,
                isFull: fullClasses.isFull(name: c.name, on: date, start: c.start))
        }
        for b in bookings.bookings(on: date) {
            let k = "\(b.name)|\(b.start)"
            if let ex = map[k] {
                map[k] = Occurrence(name: ex.name, start: ex.start, end: b.end ?? ex.end,
                                    branch: ex.branch, classKey: ex.classKey, booked: true,
                                    room: b.room, instructor: b.instructor, isTrial: ex.isTrial,
                                    isFull: false)   // booked wins: it can't be both
            } else {
                map[k] = Occurrence(name: b.name, start: b.start, end: b.end,
                                    branch: b.branch, classKey: nil, booked: true,
                                    room: b.room, instructor: b.instructor, isTrial: false,
                                    isFull: false)
            }
        }
        return map.values.sorted { $0.start < $1.start }
    }

    func detail(on date: Date) -> ClassDetail {
        let time = end.map { "\(start)–\($0)" } ?? start
        return ClassDetail(
            name: name,
            whenLabel: date.formatted(.dateTime.weekday(.wide).month().day()),
            time: time, branch: branch, booked: booked,
            room: room, instructor: instructor, isTrial: isTrial)
    }
}

// MARK: - Two-week calendar grid

private struct TwoWeekGrid: View {
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var pauses: PausesRepository
    @EnvironmentObject var swaps: SwapsRepository
    @EnvironmentObject var snapshot: SnapshotRepository
    @EnvironmentObject var bookings: BookingsRepository
    @EnvironmentObject var fullClasses: FullRepository

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
            Rectangle().fill(Theme.weekDivider.opacity(0.6)).frame(height: 2)
            if weeks.indices.contains(1) { weekRow(weeks[1], title: "Next week") }
        }
    }

    private func weekRow(_ week: [Date], title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: labelFont - 1, weight: .heavy)).foregroundStyle(Theme.weekDivider)
            HStack(alignment: .top, spacing: 5) {
                ForEach(week, id: \.self) { date in dayColumn(date) }
            }
        }
    }

    private func dayColumn(_ date: Date) -> some View {
        let occs = CalendarHelper.weekday(of: date).map {
            Occurrence.build(date: date, weekday: $0, classes: classes, bookings: bookings,
                             snapshot: snapshot, fullClasses: fullClasses)
        } ?? []
        return VStack(spacing: 4) {
            VStack(spacing: 1) {
                Text(date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: labelFont, weight: .bold))
                Text(date.formatted(.dateTime.month(.defaultDigits).day()))
                    .font(.system(size: labelFont - 2)).foregroundStyle(.secondary)
            }
            ForEach(occs) { occ in
                let away = occ.classKey.map { pauses.isAway(date, classKey: $0) } ?? false
                GridCell(occ: occ, away: away,
                         swapRole: swaps.role(name: occ.name, start: occ.start,
                                              classKey: occ.classKey, on: date),
                         past: CalendarHelper.startDate(occ.start, on: date).map { $0 < Date() } ?? false,
                         font: cellFont)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct GridCell: View {
    let occ: Occurrence
    let away: Bool
    var swapRole: SwapRole? = nil
    let past: Bool
    let font: CGFloat

    /// A displaced class reads like an away day — struck through and dimmed —
    /// because in both cases it simply isn't happening for you that day.
    private var dropped: Bool { away || swapRole == .displaced }

    private var fill: Color {
        if dropped { return Theme.away.opacity(0.12) }
        if swapRole == .replacement { return Theme.queued.opacity(0.18) }
        return occ.booked ? Theme.booked.opacity(0.18) : Theme.away.opacity(0.10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Text(occ.start).font(.system(size: font, weight: .bold)).monospacedDigit()
                // No room for a word at this size, so the swap arrows carry it;
                // the agenda row below spells it out as a badge.
                if swapRole != nil {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: font - 1, weight: .heavy))
                        .foregroundStyle(swapRole == .replacement ? Theme.queued : Theme.away)
                }
                if occ.booked && !dropped {
                    Image(systemName: "checkmark").font(.system(size: font - 1, weight: .heavy))
                        .foregroundStyle(Theme.booked)
                }
            }
            Text(occ.name).font(.system(size: font)).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(5)
        .background(fill, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(strokeColor, lineWidth: 1)
        )
        .foregroundStyle(dropped ? Theme.away : .primary)
        .strikethrough(dropped, color: Theme.away)
        .opacity(past ? 0.4 : (dropped ? 0.6 : 1))
    }

    private var strokeColor: Color {
        if dropped { return .clear }
        if swapRole == .replacement { return Theme.queued.opacity(0.5) }
        return occ.booked ? Theme.booked.opacity(0.5) : .clear
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
                    .frame(width: (UIScreen.main.bounds.width - 24) * scale, alignment: .topLeading)
                    .gesture(MagnificationGesture().onChanged { scale = min(4, max(1, $0)) })
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

private struct OccurrenceRow: View {
    let occ: Occurrence
    let away: Bool
    var swapRole: SwapRole? = nil

    /// Displaced by a swap, or paused — either way it isn't happening that day.
    private var dropped: Bool { away || swapRole == .displaced }

    private var timeRange: String { occ.end.map { "\(occ.start)–\($0)" } ?? occ.start }
    /// Not a hollow circle for the unbooked state: that's the shape of a
    /// checkbox, so it invites a tap that does something else entirely (the row
    /// opens the detail sheet — nothing here is togglable, since booking is
    /// GitHub Actions' job). A clock says "waiting on its booking window"
    /// instead of "check me", and the "Not booked" badge already carries the
    /// literal status.
    private var icon: String {
        if swapRole == .displaced { return "arrow.triangle.swap" }
        if away { return "moon.zzz.fill" }
        if occ.booked { return "checkmark.circle.fill" }
        // A full class isn't "pending" — the clock would promise it still might
        // get booked, and it won't.
        return occ.isFull ? "person.crop.circle.badge.xmark" : "clock"
    }
    private var iconColor: Color {
        if swapRole == .displaced { return Theme.away }
        if swapRole == .replacement { return Theme.queued }
        if away { return Theme.away }
        if occ.booked { return Theme.booked }
        return occ.isFull ? Theme.accent : Theme.away
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(occ.name).font(.body.weight(.medium)).strikethrough(dropped, color: Theme.away)
                HStack(spacing: 6) {
                    Text(timeRange).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    BranchChip(branch: occ.branch)
                    if occ.isTrial { badge("Trial", Theme.queued) }
                    // The one-off marker comes first: it explains *why* the
                    // status beside it isn't what this weekday usually shows.
                    if swapRole == .replacement { badge("One-off", Theme.queued) }
                    if swapRole == .displaced { badge("Swapped out", Theme.away) }
                    else if away { badge("Skipped", Theme.away) }
                    else if occ.booked { badge("Booked", Theme.booked) }
                    else if occ.isFull { badge("Full", Theme.accent) }
                    else { badge("Not booked", Theme.away) }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .opacity(dropped ? 0.6 : 1)
        .contentShape(Rectangle())
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
