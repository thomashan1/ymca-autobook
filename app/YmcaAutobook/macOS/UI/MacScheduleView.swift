#if os(macOS)
import SwiftUI

/// This week and next as a calendar of your classes: booked, booking soon,
/// skipped or away. A banner says what books next; click a class to skip it,
/// cancel it or stop booking it every week. Away dates open from the corner.
struct MacScheduleView: View {
    @ObservedObject var engine: Engine
    @State private var showAway = false
    @State private var open: Int?
    @State private var confirmCancel: ScheduleItem?

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = FisikalClient.zone
        c.firstWeekday = 2
        return c
    }()

    /// One of your sessions and how it stands.
    private struct Entry: Identifiable {
        let item: ScheduleItem
        let state: SessionState
        let away: Bool
        var id: Int { item.id }
    }

    private var entries: [Entry] {
        let now = Date(), until = now.addingTimeInterval(15 * 86400)
        return (engine.schedule ?? []).compactMap { i in
            guard i.occursAt > now, i.occursAt < until else { return nil }
            let s = engine.state(of: i)
            guard [.booked, .queued, .booking, .lineup, .skipped].contains(s) else { return nil }
            return Entry(item: i, state: s, away: s == .lineup && isAway(i))
        }
        .sorted { $0.item.occursAt < $1.item.occursAt }
    }

    /// Classes earlier this week, from the booking log: the schedule only has
    /// sessions still to come. One per class and time; booked ones read "done".
    private struct Past: Identifiable {
        let name: String
        let occursAt: Date
        let booked: Bool
        let verdict: String
        var id: String { "\(name)|\(occursAt.timeIntervalSince1970)" }
    }

    private func past(since monday: Date) -> [Past] {
        let now = Date()
        var seen: [String: Past] = [:]
        for e in engine.log where e.occursAt >= monday && e.occursAt <= now && !e.away {
            let p = Past(name: e.className, occursAt: e.occursAt,
                         booked: e.booking?.booked == true || e.atOpen?.isJoined == true, verdict: e.verdict)
            if let old = seen[p.id], old.booked { continue }
            seen[p.id] = p
        }
        return seen.values.sorted { $0.occursAt < $1.occursAt }
    }

    private func isAway(_ i: ScheduleItem) -> Bool {
        let k = engine.classes.first {
            $0.name == i.name && $0.weekday == ClubTime.weekday(i.occursAt) && $0.start == ClubTime.hhmm(i.occursAt)
                && ($0.locationIds.first ?? 0) == i.branchId
        }
        return k.map { engine.skipReason($0, on: i.occursAt) != nil } ?? false
    }

    /// The Mondays of this week and next (from Saturday on, next week and the one after).
    private var mondays: [Date] {
        let cal = Self.cal
        var mon = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
        if [7, 1].contains(cal.component(.weekday, from: Date())) { mon = cal.date(byAdding: .day, value: 7, to: mon) ?? mon }
        return [mon, cal.date(byAdding: .day, value: 7, to: mon) ?? mon]
    }

    var body: some View {
        let entries = entries
        let past = past(since: mondays[0])
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                nextBanner(entries)
                Button("Away dates…") { showAway = true }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(mondays.enumerated()), id: \.offset) { n, mon in
                        week(n == 0 ? "This week" : "Next week", from: mon, entries, past: n == 0 ? past : [])
                    }
                }
            }
            .overlay { if engine.schedule == nil { ProgressView("Reading the YMCA schedule…") } }
            Text("Click a class to skip it, cancel it or stop booking it every week. Your Mac books each class the second its booking opens, 7 days ahead.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showAway) {
            VStack(alignment: .trailing) {
                MacAwayView(engine: engine)
                HStack {
                    VersionTag()
                    Spacer()
                    Button("Done") { showAway = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 720, height: 560)
        }
        .confirmationDialog(confirmCancel.map { "Cancel \($0.name) on \($0.occursAt.formatted(.dateTime.weekday(.wide).month().day()))? Someone else may take the seat." } ?? "",
                            isPresented: Binding(get: { confirmCancel != nil }, set: { if !$0 { confirmCancel = nil } }),
                            titleVisibility: .visible) {
            if let i = confirmCancel {
                Button("Cancel booking", role: .destructive) { engine.perform(.cancel, on: i.pick) }
            }
        }
    }

    @ViewBuilder private func nextBanner(_ entries: [Entry]) -> some View {
        let next = entries.filter { !$0.away && ($0.state == .lineup || $0.state == .queued) && $0.item.openAt > Date() }
            .min { $0.item.openAt < $1.item.openAt }
        HStack(spacing: 14) {
            Text("NEXT TO BOOK").font(.caption.weight(.heavy)).foregroundStyle(.blue)
            if let n = next {
                Text("\(n.item.name) · \(n.item.occursAt.formatted(.dateTime.weekday().month(.defaultDigits).day().hour().minute()))")
                    .font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("books \(Self.when(n.item.openAt)) · in \(Self.countdown(to: n.item.openAt, from: ctx.date))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Text("Nothing waiting to book in the next two weeks.").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func week(_ title: String, from mon: Date, _ entries: [Entry], past: [Past]) -> some View {
        let cal = Self.cal
        let all = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: mon) }
        // Weekends only when something's on them.
        let days = all.enumerated().filter { n, d in n < 5 || entries.contains { cal.isDate($0.item.occursAt, inSameDayAs: d) } }.map(\.element)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.heavy)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                ForEach(days, id: \.self) { d in dayColumn(d, entries, past) }
            }
        }
    }

    private func cell(_ e: Entry) -> some View {
        let (label, color) = status(e)
        let dropped = e.away || e.state == .skipped
        return Button { open = e.id } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.item.name).font(.callout.weight(.semibold)).strikethrough(dropped).lineLimit(2)
                Text("\(e.item.occursAt.formatted(date: .omitted, time: .shortened)) · \(label)")
                    .font(.caption)
            }
            .foregroundStyle(dropped ? .secondary : color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background((dropped ? Color.gray : color).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder((dropped ? Color.gray : color).opacity(0.45), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { open == e.id }, set: { if !$0 { open = nil } }), arrowEdge: .trailing) {
            details(e)
        }
    }

    private func dayColumn(_ d: Date, _ entries: [Entry], _ past: [Past]) -> some View {
        let cal = Self.cal
        let today = cal.isDateInToday(d)
        let isPast = !today && d < Date()
        return VStack(alignment: .leading, spacing: 6) {
            Text(d.formatted(.dateTime.weekday().month(.defaultDigits).day()))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(today ? .blue : .secondary)
            ForEach(past.filter { cal.isDate($0.occursAt, inSameDayAs: d) }) { pastCell($0) }
            ForEach(entries.filter { cal.isDate($0.item.occursAt, inSameDayAs: d) }) { cell($0) }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(8)
        .background(isPast ? Color.gray.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
        // Each day its own box, like the iPhone's calendar; today's in blue.
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(today ? Color.blue.opacity(0.6) : Color.gray.opacity(0.25), lineWidth: today ? 1.5 : 1))
    }

    private func pastCell(_ p: Past) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.name).font(.callout.weight(.semibold)).lineLimit(2)
            Text("\(p.occursAt.formatted(date: .omitted, time: .shortened)) · \(p.booked ? "done" : "not booked")")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gray.opacity(0.3), lineWidth: 1))
        .help(p.verdict)
    }

    private func details(_ e: Entry) -> some View {
        let i = e.item
        return VStack(alignment: .leading, spacing: 8) {
            Text(i.name).font(.headline)
            Text("\(i.occursAt.formatted(.dateTime.weekday(.wide).month().day().hour().minute())) · \(i.minutes) min")
            Text([Branch.name(i.branchId), i.room, i.trainer].filter { !$0.isEmpty }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            Text(status(e).0).foregroundStyle(status(e).1)
            HStack {
                if let a = e.state.action {
                    Button(a.buttonTitle) {
                        open = nil
                        if a == .cancel { confirmCancel = i } else { engine.perform(a, on: i.pick) }
                    }
                }
                if e.state == .lineup || e.state == .skipped || (e.state == .booked && i.autoBook) {
                    Button("Stop booking every week") { open = nil; engine.perform(.removeWeekly, on: i.pick) }
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func status(_ e: Entry) -> (String, Color) {
        if e.away { return ("away", .orange) }
        switch e.state {
        // A darker green than .green: light green text on a light green card was hard to read.
        case .booked: return ("booked", Color(red: 0.10, green: 0.50, blue: 0.22))
        case .booking: return ("booking…", .blue)
        case .queued: return ("books \(Self.when(e.item.openAt)) · just once", .blue)
        case .lineup: return ("books \(Self.when(e.item.openAt))", .blue)
        case .skipped: return ("skipped", .secondary)
        default: return (e.state.label.lowercased(), .secondary)
        }
    }

    static func when(_ d: Date) -> String {
        let cal = Self.cal
        let t = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "today \(t)" }
        if cal.isDateInTomorrow(d) { return "tomorrow \(t)" }
        return "\(d.formatted(.dateTime.weekday())) \(t)"
    }

    static func countdown(to d: Date, from now: Date) -> String {
        let s = max(0, Int(d.timeIntervalSince(now)))
        let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if days > 0 { return "\(days)d \(h)h" }
        return String(format: "%d:%02d:%02d", h, m, s % 60)
    }
}
#endif
