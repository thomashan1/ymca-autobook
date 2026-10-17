#if os(iOS)
import SwiftUI

/// Every upcoming session at every branch, to book or cancel one at a time.
/// The iPhone doesn't talk to the YMCA itself: each tap is a request the Mac
/// picks up within about half a minute, and books right away if the window is
/// open, otherwise at the second it opens.
struct BookView: View {
    @ObservedObject private var cloud = CloudSource.shared
    @Environment(\.dismiss) private var dismiss
    /// Shown in the Classes tab rather than as a sheet: no navigation stack of
    /// its own and no Done button.
    var embedded = false
    @State private var search = ""
    @AppStorage("bookBranches") private var branches = ""
    /// nil = every day.
    @State private var day: Date?
    /// Screenshots: start filtered to the Nth day (`-screenshotBookDay N`).
    @State private var startDay: Int? = UserDefaults.standard.object(forKey: "screenshotBookDay") == nil ? nil : UserDefaults.standard.integer(forKey: "screenshotBookDay")
    @State private var onlyMine = false
    @AppStorage("bookHidePool") private var hidePool = false
    @AppStorage("bookHidePaid") private var hidePaid = false
    @AppStorage("bookFrom") private var from = -1
    @AppStorage("bookUntil") private var until = -1
    @State private var confirm: (ScheduleItem, Cloud.Request.Action)?
    @State private var error: String?

    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }

    private var content: some View {
            // Filter once per redraw: every branch is thousands of classes.
            let byDay = Dictionary(grouping: filtered) { Self.cal.startOfDay(for: $0.occursAt) }
            let days = byDay.keys.sorted()
            return List {
                header(days: days)
                ForEach(day.map { d in days.filter { $0 == d } } ?? days, id: \.self) { day in
                    Section(day.formatted(.dateTime.weekday(.wide).month().day())) {
                        ForEach(byDay[day] ?? []) { row($0) }
                    }
                }
                Section {} footer: {
                    Text("Booking opens 7 days ahead. Tap Book on any class: your Mac books it now if it's open, or at the second it opens.")
                }
            }
            .navigationTitle("Book")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Classes, rooms, instructors")
            .refreshable { await cloud.refresh() }
            .task {
                await cloud.ensureFresh()
                let days = Set(filtered.map { Self.cal.startOfDay(for: $0.occursAt) }).sorted()
                if let n = startDay, days.indices.contains(n) { day = days[n]; startDay = nil }
            }
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible) {
                if let (i, a) = confirm {
                    Button(a.buttonTitle, role: a == .cancel ? .destructive : nil) { send(a, i) }
                }
            }
            .alert("Couldn't reach iCloud", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
    }

    @ViewBuilder private func header(days: [Date]) -> some View {
        Section {
            ChipRow {
                MenuChip(options: dayOptions(days), selection: $day, active: day != nil)
                BranchesMenuChip(stored: $branches)
                Chip(title: "Mine", systemImage: "person.fill", selected: onlyMine) { onlyMine.toggle() }
                MenuChip(options: [(-1, "From any time")] + ClassFilter.timeChoices.map { ($0, "From \(ClassFilter.timeLabel($0))") },
                         selection: $from, active: from >= 0)
                MenuChip(options: [(-1, "Until any time")] + ClassFilter.timeChoices.map { ($0, "Before \(ClassFilter.timeLabel($0))") },
                         selection: $until, active: until >= 0)
                Chip(title: "Hide pool", systemImage: "drop.fill", selected: hidePool) { hidePool.toggle() }
                Chip(title: "Hide paid", systemImage: "dollarsign.circle", selected: hidePaid) { hidePaid.toggle() }
            }
        }
        if (cloud.mac?.looksDown ?? false) || cloud.schedule == nil {
            Section {
                if let mac = cloud.mac, mac.looksDown {
                    Label("Your Mac hasn't checked in since \(mac.updatedAt.formatted(.relative(presentation: .named))). Requests wait until it's back.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if cloud.schedule == nil {
                    Text(cloud.error ?? "Waiting for the class schedule from your Mac. Update YMCA Booker on the Mac if this stays empty.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ i: ScheduleItem) -> some View {
        let s = cloud.state(of: i)
        let branch = Branch(i.branchId)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(i.name).font(.body.weight(isMine(s) ? .semibold : .regular))
                    BranchChip(branch: branch)
                }
                // Time and instructor first, room on its own line: on one line the
                // instructor was the part that got cut off.
                Text("\(time(i.occursAt))–\(time(i.occursAt.addingTimeInterval(Double(i.minutes) * 60)))"
                     + (i.trainer.isEmpty ? "" : " · \(i.trainer)"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !i.room.isEmpty {
                    Text(i.room).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                status(i, s).font(.caption)
            }
            Spacer(minLength: 4)
            if let a = s.action {
                Button(a == .book ? "Book" : a == .cancel ? "Cancel" : a == .withdraw ? "Undo" : a == .skip ? "Skip" : "Unskip") {
                    if a == .cancel { confirm = (i, a) } else { send(a, i) }
                }
                // Book is the one filled, blue button; Cancel stays red but outlined,
                // so the two never look alike (the app's red accent made them twins).
                .modifier(ActionStyle(primary: a == .book))
                .tint(a == .cancel ? .red : a == .book ? .blue : .secondary)
                .controlSize(.small)
            } else if s == .booking {
                ProgressView()
            }
        }
    }

    @ViewBuilder private func status(_ i: ScheduleItem, _ s: SessionState) -> some View {
        switch s {
        case .booked:
            HStack(spacing: 4) { Image(systemName: "checkmark.circle.fill"); Text("Booked") }.foregroundStyle(Theme.booked)
        case .queued: Text("Books \(opens(i))").foregroundStyle(Theme.queued)
        case .booking: Text("Your Mac is on it…").foregroundStyle(Theme.queued)
        case .lineup: Text("Weekly · books \(opens(i))").foregroundStyle(.secondary)
        case .skipped: Text("Skipped this week").foregroundStyle(.secondary)
        case .future: Text("Opens \(opens(i))").foregroundStyle(.secondary)
        case .open: Text("Open · \(i.capacity) spots").foregroundStyle(.secondary)
        case .full: Text("Full").foregroundStyle(.red)
        case .started: Text("Started").foregroundStyle(.secondary)
        }
    }

    private func send(_ a: Cloud.Request.Action, _ i: ScheduleItem) {
        Task {
            do { try await cloud.send(a, i.pick) }
            catch { self.error = error.localizedDescription }
        }
    }

    private var filtered: [ScheduleItem] {
        _ = cloud.version
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        let chosen = Branch.parse(branches)
        return (cloud.schedule ?? []).filter { i in
            Branch.isShown(i.branchId, by: chosen)
                && (!onlyMine || isMine(cloud.state(of: i)))
                && ClassFilter.matches(i, hidePool: hidePool, hidePaid: hidePaid, from: from, until: until, calendar: Self.cal)
                && (q.isEmpty || i.name.lowercased().contains(q) || i.room.lowercased().contains(q)
                    || i.trainer.lowercased().contains(q))
        }
    }

    /// The day dropdown: every day with a class matching the other filters
    /// (the chips), plus the chosen one even if the other filters have just
    /// emptied it, so its label stays.
    private func dayOptions(_ days: [Date]) -> [(Date?, String)] {
        let list = day.map { d in days.contains(d) ? days : (days + [d]).sorted() } ?? days
        return [(nil, "All days")] + list.map { ($0, $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) }
    }

    private func isMine(_ s: SessionState) -> Bool { [.booked, .queued, .booking, .lineup, .skipped].contains(s) }

    private var confirmTitle: String {
        guard let (i, _) = confirm else { return "" }
        return "Cancel \(i.name) on \(i.occursAt.formatted(.dateTime.weekday(.wide).month().day()))? Someone else may take the seat."
    }

    private func opens(_ i: ScheduleItem) -> String {
        let cal = Self.cal
        let t = i.openAt.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(i.openAt) { return "today \(t)" }
        if cal.isDateInTomorrow(i.openAt) { return "tomorrow \(t)" }
        return "\(i.openAt.formatted(.dateTime.weekday().month().day())) \(t)"
    }

    private func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    private struct ActionStyle: ViewModifier {
        let primary: Bool
        func body(content: Content) -> some View {
            if primary { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Config.timeZone
        return c
    }()
}
#endif
