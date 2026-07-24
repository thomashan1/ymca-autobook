import SwiftUI

/// Away dates synced to the private repo's `pauses.yml`. Add/remove ranges;
/// paused days grey out on the Week screen and skip their jobs.
struct AwayView: View {
    @EnvironmentObject var pauses: PausesRepository
    @State private var showAdd = false
    @State private var busy = false
    @State private var errorMessage: String?

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
                    if pauses.pauses.isEmpty {
                        Text("No away dates set.").foregroundStyle(.secondary)
                    }
                    ForEach(pauses.pauses) { pause in
                        PauseRow(pause: pause)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { remove(pause) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text("Upcoming pauses")
                } footer: {
                    Text("Synced to ymca-private/pauses.yml — swipe to delete.")
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
            .refreshable { await pauses.load() }
            .sheet(isPresented: $showAdd) { AddPauseSheet(onSave: add) }
            .alert("Away dates", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
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

    /// Leading blanks (Mon-based) + each day of the month.
    private var cells: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: monthStart) else { return [] }
        let firstWeekday = cal.component(.weekday, from: monthStart) // 1=Sun..7=Sat
        let lead = (firstWeekday + 5) % 7 // Mon->0 … Sun->6
        var out: [Date?] = Array(repeating: nil, count: lead)
        for d in range {
            out.append(cal.date(byAdding: .day, value: d - 1, to: monthStart))
        }
        return out
    }

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        VStack(spacing: 6) {
            Text(monthStart.formatted(.dateTime.month(.wide).year()))
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"], id: \.self) { d in
                    Text(d).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let away = isAway(date)
                        let today = cal.isDateInToday(date)
                        Text("\(cal.component(.day, from: date))")
                            .font(.caption.weight(away ? .bold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(away ? Theme.weekDivider : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(away ? .white : .primary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(today ? Theme.accent : .clear, lineWidth: 2)
                            )
                    } else {
                        Color.clear.frame(minHeight: 30)
                    }
                }
            }
        }
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
    private var range: String {
        let f = Date.FormatStyle().month(.abbreviated).day()
        return pause.start == pause.end
            ? pause.start.formatted(f)
            : "\(pause.start.formatted(f)) – \(pause.end.formatted(f))"
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
