import SwiftUI

/// Away dates synced to the private repo's `pauses.yml`. Add/remove ranges;
/// paused days grey out on the Week screen and skip their jobs.
struct AwayView: View {
    @EnvironmentObject var pauses: PausesRepository
    @EnvironmentObject var swaps: SwapsRepository
    @State private var showAdd = false
    @State private var showPast = false
    @State private var busy = false
    @State private var errorMessage: String?

    /// Midnight today in the gym's timezone — the cut between past and upcoming.
    /// A range that ends *today* still counts as current, not past.
    private var today: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Config.timeZone
        return cal.startOfDay(for: Date())
    }

    /// Ranges that haven't finished yet, soonest first.
    private var upcoming: [Pause] {
        pauses.pauses.filter { $0.end >= today }.sorted { $0.start < $1.start }
    }

    /// Ranges that ended before today, most recent first — collapsed by default.
    private var past: [Pause] {
        pauses.pauses.filter { $0.end < today }.sorted { $0.start > $1.start }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 16) {
                        MonthGrid(monthOffset: 0) { pauses.isPaused($0) }
                        MonthGrid(monthOffset: 1) { pauses.isPaused($0) }
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                }
                Section {
                    if upcoming.isEmpty {
                        Text(pauses.pauses.isEmpty ? "No away dates set."
                                                   : "No upcoming away dates.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(upcoming) { pause in
                        PauseRow(pause: pause)
                            .swipeActions(edge: .trailing) { deleteButton(pause) }
                    }
                } header: {
                    Text("Upcoming pauses")
                } footer: {
                    Text("Synced to ymca-private/pauses.yml — swipe to delete.")
                }

                // One-off swaps are the other kind of schedule exception, so they
                // belong next to pauses. Read-only: securing a swap means booking
                // the replacement before releasing the original, against a live
                // booking window — that's the Actions engine's job, not the app's.
                if !swaps.upcoming().isEmpty {
                    Section {
                        ForEach(swaps.upcoming()) { swap in
                            SwapRow(swap: swap)
                        }
                    } header: {
                        Text("One-off swaps")
                    } footer: {
                        Text("From ymca-private/swaps.yml. Booked by Actions — the original class is kept until its replacement is secured.")
                    }
                }

                // Past ranges stay out of the way but remain reachable (and deletable).
                if !past.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showPast) {
                            ForEach(past) { pause in
                                PauseRow(pause: pause)
                                    .foregroundStyle(.secondary)
                                    .swipeActions(edge: .trailing) { deleteButton(pause) }
                            }
                        } label: {
                            Label("Past pauses (\(past.count))", systemImage: "clock.arrow.circlepath")
                                .font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("Away Dates")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .disabled(busy)
                }
            }
            .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .refreshable {
                await pauses.load()
                await swaps.load()
            }
            .sheet(isPresented: $showAdd) { AddPauseSheet(onSave: add) }
            .alert("Away dates", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    @ViewBuilder
    private func deleteButton(_ pause: Pause) -> some View {
        Button(role: .destructive) { remove(pause) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func add(start: Date, end: Date, note: String?) {
        busy = true
        Task {
            if let err = await pauses.add(start: start, end: end, note: note) { errorMessage = err }
            busy = false
        }
    }

    private func remove(_ pause: Pause) {
        busy = true
        Task {
            if let err = await pauses.delete(pause) { errorMessage = err }
            busy = false
        }
    }
}

/// A compact month calendar with away days filled in; `monthOffset` 0 = current
/// month, 1 = next month.
private struct MonthGrid: View {
    let monthOffset: Int
    let isAway: (Date) -> Bool

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Config.timeZone
        c.firstWeekday = 2 // Monday
        return c
    }

    private var monthStart: Date {
        let base = cal.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
        return cal.date(from: cal.dateComponents([.year, .month], from: base)) ?? base
    }

    /// Weekdays only (Mon–Fri): leading blanks to the first weekday's column,
    /// then each Mon–Fri day of the month (weekend days omitted).
    private var cells: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: monthStart) else { return [] }
        let weekdays = range
            .compactMap { cal.date(byAdding: .day, value: $0 - 1, to: monthStart) }
            .filter { (2...6).contains(cal.component(.weekday, from: $0)) } // Mon(2)…Fri(6)
        guard let first = weekdays.first else { return [] }
        let lead = (cal.component(.weekday, from: first) + 5) % 7 // Mon->0 … Fri->4
        return Array(repeating: nil, count: lead) + weekdays.map(Optional.init)
    }

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)

    var body: some View {
        VStack(spacing: 6) {
            Text(monthStart.formatted(.dateTime.month(.wide).year()))
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(Array(["M", "T", "W", "T", "F"].enumerated()), id: \.offset) { _, d in
                    Text(d).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        dayCell(date)
                    } else {
                        Color.clear.frame(minHeight: 34)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let away = isAway(date)
        let today = cal.isDateInToday(date)
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(away ? Theme.away.opacity(0.45) : Color.clear)
            Text("\(cal.component(.day, from: date))")
                .font(.caption.weight(away ? .bold : .regular))
                .strikethrough(away, color: .white)
                .foregroundStyle(away ? .white : .primary)
        }
        .frame(maxWidth: .infinity, minHeight: 34)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(today ? Theme.accent : .clear, lineWidth: 2)
        )
    }
}

/// A pending one-off swap: the class being dropped, and what takes its place.
private struct SwapRow: View {
    let swap: Swap

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(dateLabel).font(.body.weight(.medium))
            HStack(spacing: 6) {
                if let skip = swap.skipKey {
                    Text(skip)
                        .font(.caption)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                }
                if swap.skipKey != nil && swap.bookName != nil {
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                }
                if let name = swap.bookName {
                    Text([name, swap.bookStart].compactMap { $0 }.joined(separator: " "))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.booked)
                }
            }
            if let branch = swap.bookBranch {
                Text(branch).font(.caption2).foregroundStyle(.secondary)
            }
            if let note = swap.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Matches PauseRow: month/day this year, with the year once it isn't.
    private var dateLabel: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Config.timeZone
        let sameYear = cal.component(.year, from: swap.date) == cal.component(.year, from: Date())
        let style = sameYear
            ? Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day()
            : Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().year()
        return swap.date.formatted(style)
    }
}

private struct PauseRow: View {
    let pause: Pause
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(range).font(.body.weight(.medium))
            if let note = pause.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if !pause.except.isEmpty {
                Text("Still booking: \(pause.except.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(Theme.booked)
            }
        }
    }
    /// Month/day is enough for this year; anything else carries its year, since
    /// the list now runs across a school year (e.g. "Dec 21, 2026 – Jan 1, 2027").
    private var range: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Config.timeZone
        let thisYear = cal.component(.year, from: Date())
        let startYear = cal.component(.year, from: pause.start)
        let endYear = cal.component(.year, from: pause.end)

        let md = Date.FormatStyle().month(.abbreviated).day()
        let mdy = Date.FormatStyle().month(.abbreviated).day().year()

        if pause.start == pause.end {
            return pause.start.formatted(startYear == thisYear ? md : mdy)
        }
        if startYear != endYear {
            // Crosses New Year — without both years the range reads backwards.
            return "\(pause.start.formatted(mdy)) – \(pause.end.formatted(mdy))"
        }
        // Same year on both ends: one trailing year covers it.
        return "\(pause.start.formatted(md)) – \(pause.end.formatted(startYear == thisYear ? md : mdy))"
    }
}

/// Add-range editor. Commits to pauses.yml via the `onSave` callback.
private struct AddPauseSheet: View {
    let onSave: (_ start: Date, _ end: Date, _ note: String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var end = Date()
    @State private var note = ""

    private var validRange: Bool { end >= Calendar.current.startOfDay(for: start) }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Start", selection: $start, displayedComponents: .date)
                DatePicker("End", selection: $end, in: start..., displayedComponents: .date)
                TextField("Note (optional)", text: $note)
            } // Form
            .navigationTitle("Add pause")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(start, end, note.trimmingCharacters(in: .whitespaces).isEmpty ? nil : note)
                        dismiss()
                    }
                    .disabled(!validRange)
                }
            }
        }
    }
}
