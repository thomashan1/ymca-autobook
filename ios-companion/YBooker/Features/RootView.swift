import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house") }
            WeekView().tabItem { Label("Week", systemImage: "calendar") }
            ClassesView().tabItem { Label("Classes", systemImage: "list.bullet") }
            AwayView().tabItem { Label("Away", systemImage: "airplane") }
        }
    }
}

/// Pull to refresh, the last-updated time, and any error — shared by every tab.
struct CloudFooter: View {
    @EnvironmentObject var data: CloudData

    var body: some View {
        if let e = data.error {
            Label(e, systemImage: "exclamationmark.icloud").font(.footnote).foregroundStyle(.orange)
        } else if let t = data.lastRefresh {
            Text("Updated \(t.formatted(.relative(presentation: .named)))").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

// MARK: Home

struct HomeView: View {
    @EnvironmentObject var data: CloudData

    var body: some View {
        NavigationStack {
            List {
                Section { MacCard() } footer: { CloudFooter() }
                Section("Recent booking windows") {
                    let recent = data.openings.filter { $0.openAt > Date().addingTimeInterval(-14 * 86400) }
                    if recent.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                    ForEach(recent) { OpeningRow(o: $0) }
                }
            }
            .navigationTitle("Y Booker")
            .refreshable { await data.refresh() }
        }
    }
}

struct MacCard: View {
    @EnvironmentObject var data: CloudData

    var body: some View {
        if let m = data.mac {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: m.looksDown ? "desktopcomputer.trianglebadge.exclamationmark" : "desktopcomputer")
                        .foregroundStyle(m.looksDown ? .red : .green)
                    Text(m.looksDown ? "Mac hasn't checked in" : "Mac is booking").font(.headline)
                    Spacer()
                    Text(m.liveClasses > 0 ? "LIVE · \(m.liveClasses)" : "SHADOW")
                        .font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background((m.liveClasses > 0 ? Color.green : .orange).opacity(0.2), in: Capsule())
                }
                Text("Last heard from \(m.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.subheadline).foregroundStyle(m.looksDown ? .red : .secondary)
                if let next = m.nextOpening {
                    Text("Next: \(m.nextOpeningClasses.joined(separator: " + ")) opens \(next.formatted(.dateTime.weekday().month().day().hour().minute()))")
                        .font(.subheadline)
                }
                if let e = m.syncError {
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        } else {
            Text("Waiting for your Mac — open Y Booker on it, signed in to the same iCloud account.")
                .foregroundStyle(.secondary)
        }
    }
}

struct OpeningRow: View {
    let o: Opening

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: o.paused ? "pause.circle" : o.booked ? "checkmark.circle.fill" : o.live ? "xmark.circle.fill" : "eye")
                .foregroundStyle(o.paused ? .secondary : o.booked ? Color.green : o.live ? .red : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(o.className).font(.body.weight(.medium))
                Text("for \(o.occursAt.formatted(.dateTime.weekday().month().day().hour().minute()))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(o.verdict).font(.caption).foregroundStyle(o.failed ? .red : .secondary)
            }
            Spacer()
            if let ms = o.sendLagMs {
                Text("+\(ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Week

struct WeekView: View {
    @EnvironmentObject var data: CloudData

    /// Today and the next 13 days.
    private var days: [Date] {
        (0..<14).compactMap { Day.calendar.date(byAdding: .day, value: $0, to: Day.calendar.startOfDay(for: Date())) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(days, id: \.self) { d in
                    let day = Day.string(d)
                    let items = data.classes.filter { $0.weekday == Day.weekday(d) }
                    let extra = data.swaps.filter { $0.date == day && $0.bookName != nil }
                    if !items.isEmpty || !extra.isEmpty {
                        Section(Day.short(day)) {
                            ForEach(items) { c in WeekRow(c: c, day: day) }
                            ForEach(extra) { w in
                                Label("\(w.bookName ?? "") \(w.bookStart ?? "") · swap", systemImage: "arrow.left.arrow.right")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
                Section { } footer: { CloudFooter() }
            }
            .navigationTitle("Next two weeks")
            .refreshable { await data.refresh() }
        }
    }
}

struct WeekRow: View {
    @EnvironmentObject var data: CloudData
    let c: GymClass
    let day: String

    var body: some View {
        let away = data.isAway(c, on: day)
        let swap = data.swap(c, on: day)
        let o = data.opening(c, on: day)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).strikethrough(away != nil || swap != nil)
                Text("\(c.start) · \(c.branch)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Group {
                if away != nil { Text("away") }
                else if swap != nil { Text("swapped out") }
                else if let o, o.booked { Label("booked", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                else if let o, o.failed { Label("not booked", systemImage: "xmark.circle.fill").foregroundStyle(.red) }
                else { Text("opens a week before") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Classes and fill speed

struct ClassesView: View {
    @EnvironmentObject var data: CloudData

    var body: some View {
        NavigationStack {
            List {
                ForEach(Day.order, id: \.self) { wd in
                    let items = data.classes.filter { $0.weekday == wd }
                    if !items.isEmpty {
                        Section(wd) {
                            ForEach(items) { c in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.name)
                                        Text("\(c.start) · \(c.branch)\(c.liveBooking ? "" : " · shadow only")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let s = data.stat(for: c) {
                                        Text(s.filledWeeks == 0 ? "never fills" : "fills in ~\(Day.duration(s.medianFill))")
                                            .font(.caption).foregroundStyle(s.fillsFast ? .red : .secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                Section { } footer: { CloudFooter() }
            }
            .navigationTitle("My classes")
            .toolbar {
                NavigationLink { FillSpeedView() } label: { Label("Fill speed", systemImage: "chart.bar.xaxis") }
            }
            .refreshable { await data.refresh() }
        }
    }
}

struct FillSpeedView: View {
    @EnvironmentObject var data: CloudData
    enum Filter: String, CaseIterable, Identifiable { case mine = "Mine", fast = "Fill fast", all = "All"; var id: String { rawValue } }
    @State private var filter = Filter.mine
    @State private var search = ""

    private var rows: [SlotStat] {
        let mine = Set(data.classes.map(\.slotKey))
        let q = search.lowercased()
        return data.stats.filter { s in
            switch filter {
            case .mine: if !mine.contains(s.id) { return false }
            case .fast: if !s.fillsFast { return false }
            case .all: break
            }
            return q.isEmpty || s.name.lowercased().contains(q)
        }
        .sorted {
            filter == .fast ? ($0.medianFill ?? .infinity) < ($1.medianFill ?? .infinity)
                : (Day.order.firstIndex(of: $0.weekday) ?? 9, $0.start) < (Day.order.firstIndex(of: $1.weekday) ?? 9, $1.start)
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
            } footer: {
                Text("How long each class takes to fill after booking opens (167 h before class), from the YMCA's own \"filled at\" times, collected by your Mac.")
            }
            ForEach(rows) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(s.name)
                        Spacer()
                        Text(s.filledWeeks == 0 ? "never full" : Day.duration(s.medianFill))
                            .font(.body.monospacedDigit().weight(.semibold))
                            .foregroundStyle(s.fillsFast ? .red : s.filledWeeks == 0 ? .secondary : .primary)
                    }
                    HStack(spacing: 8) {
                        Text("\(s.weekday) \(s.start) · \(s.branch)")
                        Spacer()
                        Text("full \(s.filledWeeks)/\(s.weeks) wk")
                        if let f = s.fastestFill, s.filledWeeks > 1 { Text("fastest \(Day.duration(f))") }
                    }
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .navigationTitle("Fill speed")
        .searchable(text: $search, prompt: "Search classes")
    }
}

// MARK: Away and swaps

struct AwayView: View {
    @EnvironmentObject var data: CloudData
    @State private var showPast = false

    var body: some View {
        NavigationStack {
            List {
                Section("Away — no booking on these days") {
                    let ps = data.pauses.filter { showPast || !$0.isPast }
                    if ps.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(ps) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.start == p.end ? Day.short(p.start) : "\(Day.short(p.start)) – \(Day.short(p.end))")
                            if let n = p.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                            if !p.except.isEmpty {
                                Text("still booking: \(p.except.map(name).joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(p.isPast ? .secondary : .primary)
                    }
                }
                Section("One-off swaps") {
                    let ws = data.swaps.filter { showPast || !$0.isPast }
                    if ws.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(ws) { w in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Day.short(w.date))
                            Text([w.skip.map { "skip \(name($0))" }, w.bookName.map { "take \($0) \(w.bookStart ?? "")" }]
                                    .compactMap { $0 }.joined(separator: ", "))
                                .font(.caption)
                            if let n = w.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                        }
                        .foregroundStyle(w.isPast ? .secondary : .primary)
                    }
                }
                Section { Toggle("Show past", isOn: $showPast) } footer: { CloudFooter() }
            }
            .navigationTitle("Away & swaps")
            .refreshable { await data.refresh() }
        }
    }

    private func name(_ key: String) -> String {
        data.classes.first { $0.key == key }.map { "\($0.name) \($0.weekday)" } ?? key
    }
}
