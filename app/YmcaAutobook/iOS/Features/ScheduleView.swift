#if os(iOS)
import SwiftUI

/// The next two weeks of your classes, one line each: booked, booking soon,
/// skipped or away. Merges the weekly lineup with real bookings (so one-offs
/// show too) and, from the Mac, single sessions queued to book. A card on top
/// says what books next. Swipe a class to skip it (or undo, cancel…); away
/// dates open from the toolbar. Tap a class for its details.
struct ScheduleView: View {
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var awayRanges: AwayRepository
    @EnvironmentObject var swaps: SwapsRepository
    @EnvironmentObject var snapshot: SnapshotRepository
    @EnvironmentObject var bookings: BookingsRepository
    @EnvironmentObject var fullClasses: FullRepository
    @EnvironmentObject var auth: AuthStore
    @ObservedObject private var cloud = CloudSource.shared
    /// iPad: the two-week calendar fits above the list, so it stays.
    @Environment(\.horizontalSizeClass) private var sizeClass

    private static let daysAhead = 14
    @State private var detail: ClassDetail?
    @State private var showAway = false
    @State private var showCalendar = UserDefaults.standard.bool(forKey: "screenshotCalendar")
    @State private var confirmCancel: ScheduleItem?
    @State private var bookNow: Row?
    @State private var message: String?

    private var cal: Calendar { CalendarHelper.pacific }

    /// One class on one day, and where it stands.
    struct Row: Identifiable {
        let date: Date
        let occ: Occurrence
        let status: Status
        /// The session as the Mac published it (iCloud mode), for its actions.
        let item: ScheduleItem?
        var id: String { "\(date.timeIntervalSince1970)|\(occ.id)" }

        var startsAt: Date? { CalendarHelper.startDate(occ.start, on: date) }
        var opensAt: Date? { startsAt.map { $0.addingTimeInterval(-Double(Config.bookOpenLeadHours) * 3600) } }
    }

    enum Status: Equatable {
        case booked, booking, books, away, skipped, swappedOut, full, notBooked

        var dropped: Bool { [.away, .skipped, .swappedOut].contains(self) }
    }

    private struct Day: Identifiable {
        let date: Date
        let rows: [Row]
        var id: TimeInterval { date.timeIntervalSince1970 }
    }

    private var days: [Day] {
        _ = cloud.version
        let now = Date()
        let today = cal.startOfDay(for: now)
        let queued = auth.isCloud || SampleMode.active ? cloud.oneOffs : []
        var out: [Day] = []
        for offset in 0..<Self.daysAhead {
            guard let date = cal.date(byAdding: .day, value: offset, to: today),
                  let wd = CalendarHelper.weekday(of: date) else { continue }
            var occs = Occurrence.build(date: date, weekday: wd,
                                        classes: classes, bookings: bookings, snapshot: snapshot,
                                        fullClasses: fullClasses)
            for p in queued where cal.isDate(p.occursAt, inSameDayAs: date) {
                let start = ClubTime.hhmm(p.occursAt)
                guard !occs.contains(where: { $0.name == p.name && $0.start == start }) else { continue }
                occs.append(Occurrence(name: p.name, start: start, end: nil, branch: Branch(p.branchId),
                                       classKey: nil, booked: false, room: p.room.isEmpty ? nil : p.room,
                                       instructor: p.trainer.isEmpty ? nil : p.trainer, isTrial: false, isFull: false))
            }
            let rows = occs
                .filter { CalendarHelper.startDate($0.start, on: date).map { $0 >= now } ?? true }
                .sorted { $0.start < $1.start }
                .map { row($0, on: date) }
            if !rows.isEmpty { out.append(Day(date: date, rows: rows)) }
        }
        return out
    }

    private func row(_ occ: Occurrence, on date: Date) -> Row {
        let item = cloud.schedule?.first {
            $0.name == occ.name && ClubTime.hhmm($0.occursAt) == occ.start && cal.isDate($0.occursAt, inSameDayAs: date)
        }
        let away = occ.classKey.map { awayRanges.isAway(date, classKey: $0) } ?? false
        let swapRole = swaps.role(name: occ.name, start: occ.start, classKey: occ.classKey, on: date)
        let status: Status
        if occ.booked || item?.joined == true { status = .booked }
        else if away { status = .away }
        else if swapRole == .displaced { status = .swappedOut }
        else if let item {
            switch cloud.state(of: item) {
            case .booked: status = .booked
            case .booking: status = .booking
            case .queued, .lineup: status = .books
            case .skipped: status = .skipped
            case .full: status = .full
            case .future, .open, .started: status = occ.isFull ? .full : .notBooked
            }
        } else if occ.isFull { status = .full }
        else if occ.classKey != nil || swapRole == .replacement {
            let opens = CalendarHelper.startDate(occ.start, on: date)?.addingTimeInterval(-Double(Config.bookOpenLeadHours) * 3600)
            status = (opens ?? .distantPast) > Date() ? .books : .notBooked
        } else { status = .books }   // a queued single session
        return Row(date: date, occ: occ, status: status, item: item)
    }

    var body: some View {
        NavigationStack {
            let days = days
            List {
                Section { NextUpCard(next: days.flatMap(\.rows).filter { $0.status == .books }
                                        .min { ($0.opensAt ?? .distantFuture) < ($1.opensAt ?? .distantFuture) }) }
                if sizeClass == .regular {
                    Section {
                        TwoWeekGrid(cellFont: 13, labelFont: 15)
                            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    }
                }
                let groups = Dictionary(grouping: days) { CalendarHelper.weekIndex(of: $0.date) }
                ForEach(groups.keys.sorted(), id: \.self) { wi in
                    Section(CalendarHelper.weekLabel(wi)) {
                        ForEach(groups[wi] ?? []) { day in
                            ForEach(Array(day.rows.enumerated()), id: \.element.id) { n, r in
                                Button { detail = r.occ.detail(on: r.date) } label: {
                                    ScheduleRow(row: r, showDate: n == 0, awayNote: n == 0 ? awayNote(day.date) : nil)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) { actions(r) }
                            }
                        }
                    }
                }
                if days.isEmpty {
                    Text("No classes in the next two weeks. Add one under Classes.")
                        .foregroundStyle(.secondary)
                }
                Section {} footer: {
                    Text(auth.looksCloud ? "Swipe a class to skip it this week. Your Mac books each class the second its booking opens, 7 days ahead."
                                         : "Swipe a class to book it now. GitHub Actions books each class the second its booking opens, 7 days ahead.")
                }
            }
            .navigationTitle("Schedule")
            .toolbar {
                // The iPad shows the calendar above the list; the iPhone has no
                // room, so it's a tap away, full screen and zoomable.
                if sizeClass != .regular {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showCalendar = true } label: { Label("Calendar", systemImage: "calendar") }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAway = true } label: { Label("Away dates", systemImage: "airplane") }
                        .labelStyle(.titleAndIcon)
                }
            }
            .refreshable {
                if auth.isCloud { await cloud.refresh() }
                await classes.load(); await awayRanges.load(); await swaps.load()
                await snapshot.load(); await bookings.load(); await fullClasses.load()
            }
            .sheet(item: $detail) { ClassDetailSheet(detail: $0) }
            .sheet(isPresented: $showAway) { AwayView() }
            .fullScreenCover(isPresented: $showCalendar) { CalendarZoomSheet() }
            .confirmationDialog(confirmCancel.map { "Cancel \($0.name) on \($0.occursAt.formatted(.dateTime.weekday(.wide).month().day()))? Someone else may take the seat." } ?? "",
                                isPresented: Binding(get: { confirmCancel != nil }, set: { if !$0 { confirmCancel = nil } }),
                                titleVisibility: .visible) {
                if let i = confirmCancel {
                    Button("Cancel booking", role: .destructive) { send(.cancel, i) }
                }
            }
            .confirmationDialog(bookNow.map { "Book \($0.occ.name) now?" } ?? "",
                                isPresented: Binding(get: { bookNow != nil }, set: { if !$0 { bookNow = nil } }),
                                titleVisibility: .visible) {
                Button("Book now") { if let r = bookNow { dispatch(r) } }
            } message: {
                Text("This runs the booking workflow for this class now, ignoring away dates.")
            }
            .alert("YMCA Booker", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
    }

    /// The note on the away range covering this day, if any.
    private func awayNote(_ date: Date) -> String? {
        guard awayRanges.isAway(date) else { return nil }
        return awayRanges.awayRanges.first { $0.start <= date && date <= $0.end }?.note ?? "Away"
    }

    @ViewBuilder private func actions(_ r: Row) -> some View {
        if let item = r.item, auth.isCloud {
            switch cloud.state(of: item).action {
            case .skip?: Button("Skip") { send(.skip, item) }.tint(.orange)
            case .unskip?: Button("Undo skip") { send(.unskip, item) }.tint(.blue)
            case .withdraw?: Button("Don't book") { send(.withdraw, item) }.tint(.orange)
            case .cancel?: Button("Cancel", role: .destructive) { confirmCancel = item }
            default: EmptyView()
            }
        } else if !auth.looksCloud, r.occ.classKey != nil, !r.occ.booked {
            Button { bookNow = r } label: { Label("Book now", systemImage: "bolt.fill") }.tint(Theme.accent)
        }
    }

    private func send(_ a: Cloud.Request.Action, _ i: ScheduleItem) {
        Task {
            do { try await cloud.send(a, i.pick) }
            catch { message = "Couldn't reach iCloud: \(error.localizedDescription)" }
        }
    }

    private func dispatch(_ r: Row) {
        guard let key = r.occ.classKey else { return }
        bookNow = nil
        Task {
            do {
                try await GitHubClient().dispatchBook(classKey: key)
                message = "Asked GitHub Actions to book \(r.occ.name). It runs in a few seconds; pull to refresh shortly."
            } catch {
                message = "Couldn't start the booking: \(error). Check the token has Actions (write) permission."
            }
        }
    }
}

/// What books next and when, counting down, plus a warning when the Mac has
/// gone quiet (nothing books while it's asleep).
private struct NextUpCard: View {
    let next: ScheduleView.Row?
    @ObservedObject private var cloud = CloudSource.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let m = cloud.mac, m.looksDown, DataSource.isCloud {
                Label("Your Mac hasn't checked in since \(m.updatedAt.formatted(.relative(presentation: .named))). Nothing books until it's back.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
            }
            Text("NEXT TO BOOK").font(.caption.weight(.heavy)).foregroundStyle(Theme.weekDivider)
            if let next, let opens = next.opensAt, let starts = next.startsAt {
                Text("\(next.occ.name) · \(starts.formatted(.dateTime.weekday().month(.defaultDigits).day())), \(next.occ.start)")
                    .font(.title3.weight(.bold))
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Books \(Self.when(opens)) · in \(Self.countdown(to: opens, from: ctx.date))")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Text("Nothing waiting to book in the next two weeks.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    static func when(_ d: Date) -> String {
        let cal = CalendarHelper.pacific
        let t = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "today \(t)" }
        if cal.isDateInTomorrow(d) { return "tomorrow \(t)" }
        return "\(d.formatted(.dateTime.weekday())) \(t)"
    }

    static func countdown(to d: Date, from now: Date) -> String {
        let s = max(0, Int(d.timeIntervalSince(now)))
        let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if days > 0 { return "\(days)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m \(s % 60)s"
    }
}

/// One class in the Schedule: the day (on a day's first row), the class, and
/// one status chip.
private struct ScheduleRow: View {
    let row: ScheduleView.Row
    let showDate: Bool
    let awayNote: String?

    private var timeRange: String { row.occ.end.map { "\(row.occ.start)–\($0)" } ?? row.occ.start }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 0) {
                if showDate {
                    Text(row.date.formatted(.dateTime.weekday(.abbreviated))).font(.caption.weight(.bold))
                    Text(row.date.formatted(.dateTime.month(.defaultDigits).day())).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                if let awayNote, showDate {
                    Text(awayNote).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                Text(row.occ.name).font(.body.weight(.medium))
                    .strikethrough(row.status.dropped, color: .secondary)
                HStack(spacing: 6) {
                    Text(timeRange).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    BranchChip(branch: row.occ.branch)
                }
            }
            Spacer(minLength: 4)
            chip
        }
        .opacity(row.status.dropped ? 0.6 : 1)
        .contentShape(Rectangle())
    }

    private var chip: some View {
        let (text, color): (String, Color) = {
            switch row.status {
            case .booked: return ("Booked", Theme.booked)
            case .booking: return ("Booking…", Theme.weekDivider)
            case .books: return (row.opensAt.map { "Books " + NextUpCard.when($0).components(separatedBy: " ").first! } ?? "Books", Theme.weekDivider)
            case .away: return ("Away", .orange)
            case .skipped: return ("Skipped", .secondary)
            case .swappedOut: return ("Swapped", .secondary)
            case .full: return ("Full", Theme.accent)
            case .notBooked: return ("Not booked", .secondary)
            }
        }()
        return Text(text).font(.caption.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
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

    /// The Monday that starts the week the app calls "this week".
    ///
    /// Not simply the calendar week: the schedule is Mon–Fri, so from Saturday
    /// on there is nothing left in it — "This week" would head five days that
    /// have all already happened, and the only useful week is the one ahead.
    /// So once Friday is done, Saturday and Sunday anchor to the coming Monday.
    ///
    /// Every screen that divides classes into weeks reads this, so the grid,
    /// the agenda and the Jobs headings roll over together.
    static var currentMonday: Date {
        let cal = pacific
        let now = Date()
        guard let mon = cal.dateInterval(of: .weekOfYear, for: now)?.start else {
            return cal.startOfDay(for: now)
        }
        // firstWeekday is Monday, so within this calendar the weekend days are
        // the tail of the week: .weekday 7 = Saturday, 1 = Sunday.
        let wd = cal.component(.weekday, from: now)
        guard wd == 7 || wd == 1 else { return mon }
        return cal.date(byAdding: .day, value: 7, to: mon) ?? mon
    }

    /// 0 = the week starting at `currentMonday`, 1 = the one after, and so on.
    /// Dates before it clamp to 0 rather than going negative — every screen
    /// using this shows forward-looking dates only.
    static func weekIndex(of date: Date) -> Int {
        let cal = pacific
        let days = cal.dateComponents([.day], from: currentMonday,
                                      to: cal.startOfDay(for: date)).day ?? 0
        return max(0, days / 7)
    }

    static func weekLabel(_ wi: Int) -> String {
        switch wi {
        case 0: return "This week"
        case 1: return "Next week"
        default:
            let cal = pacific
            if let mon = cal.date(byAdding: .day, value: wi * 7, to: currentMonday) {
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
    @EnvironmentObject var awayRanges: AwayRepository
    @EnvironmentObject var swaps: SwapsRepository
    @EnvironmentObject var snapshot: SnapshotRepository
    @EnvironmentObject var bookings: BookingsRepository
    @EnvironmentObject var fullClasses: FullRepository
    @ObservedObject private var cloud = CloudSource.shared

    var cellFont: CGFloat
    var labelFont: CGFloat

    private var weeks: [[Date]] {
        let cal = CalendarHelper.pacific
        let thisMon = CalendarHelper.currentMonday
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

    /// Skipped in YMCA Booker (iCloud mode): struck through like an away day.
    private func skipped(_ occ: Occurrence, on date: Date) -> Bool {
        _ = cloud.version
        guard let item = cloud.schedule?.first(where: {
            $0.name == occ.name && ClubTime.hhmm($0.occursAt) == occ.start
                && CalendarHelper.pacific.isDate($0.occursAt, inSameDayAs: date)
        }) else { return false }
        return cloud.state(of: item) == .skipped
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
                let away = occ.classKey.map { awayRanges.isAway(date, classKey: $0) } ?? false
                GridCell(occ: occ, away: away || skipped(occ, on: date),
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

    var body: some View {
        // No room for a word at this size, so the swap arrows carry it; the
        // agenda row below spells it out as a badge.
        CalendarCell(time: occ.start, name: occ.name, booked: occ.booked, dropped: dropped, past: past,
                     queued: swapRole == .replacement,
                     symbol: swapRole.map { ("arrow.triangle.swap", $0 == .replacement ? Theme.queued : Theme.away) },
                     font: font)
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
#endif
