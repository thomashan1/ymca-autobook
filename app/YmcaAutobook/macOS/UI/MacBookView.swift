#if os(macOS)
import SwiftUI

/// Every upcoming session at both branches, to book or cancel one at a time.
/// A session whose window is open is booked now; one that isn't yet is booked
/// at the second it opens. Weekly-lineup sessions can be skipped.
struct MacBookView: View {
    @ObservedObject var engine: Engine
    @State private var search = ""
    @State private var day: String = "All"
    @State private var branch = 0
    @State private var onlyMine = false
    @AppStorage("bookHidePool") private var hidePool = false
    @AppStorage("bookFrom") private var from = -1
    @AppStorage("bookUntil") private var until = -1
    @State private var confirm: (ScheduleItem, Cloud.Request.Action)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            filters
            Table(filtered) {
                TableColumn("") { i in actionButton(i) }.width(130)
                TableColumn("Class") { i in Text(i.name).bold(isMine(i)) }.width(min: 140, ideal: 170)
                TableColumn("When") { i in
                    Text("\(i.occursAt.formatted(.dateTime.weekday().month().day())) \(time(i.occursAt))–\(time(i.occursAt.addingTimeInterval(Double(i.minutes) * 60)))")
                        .monospacedDigit()
                }
                .width(min: 150, ideal: 170)
                TableColumn("Branch") { i in Text(Slot.branchName(i.branchId)) }.width(80)
                TableColumn("Room") { i in Text(i.room).foregroundStyle(.secondary) }.width(min: 90, ideal: 130)
                TableColumn("Instructor") { i in Text(i.trainer).foregroundStyle(.secondary) }.width(min: 80, ideal: 110)
                TableColumn("Status") { i in status(i) }.width(min: 110, ideal: 170)
            }
            .overlay {
                if engine.schedule == nil { ProgressView("Reading the YMCA schedule…") }
                else if filtered.isEmpty { Text("No classes match these filters.").foregroundStyle(.secondary) }
            }
            Text("Book: right away if its window is open, otherwise at the second it opens (\(Int(167 / 24)) days \(167 % 24) h before the class). Skip: the weekly lineup leaves that one session alone.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            if let (i, a) = confirm {
                Button(a.buttonTitle, role: a == .cancel ? .destructive : nil) { engine.perform(a, on: i.pick) }
            }
        }
    }

    private var filters: some View {
        HStack {
            TextField("Search classes, rooms, instructors", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            Picker("", selection: $day) {
                Text("All days").tag("All")
                ForEach(days, id: \.self) { d in Text(dayLabel(d)).tag(d) }
            }
            .frame(width: 130)
            Picker("", selection: $branch) {
                Text("Both branches").tag(0)
                Text("Southwest").tag(1392)
                Text("Northwest").tag(1388)
            }
            .frame(width: 130)
            Picker("", selection: $from) {
                Text("From any time").tag(-1)
                ForEach(ClassFilter.timeChoices, id: \.self) { Text("From \(ClassFilter.timeLabel($0))").tag($0) }
            }
            .frame(width: 140)
            .help("Classes starting at or after this time")
            Picker("", selection: $until) {
                Text("Until any time").tag(-1)
                ForEach(ClassFilter.timeChoices, id: \.self) { Text("Before \(ClassFilter.timeLabel($0))").tag($0) }
            }
            .frame(width: 150)
            .help("Classes starting before this time")
            Toggle("Only mine", isOn: $onlyMine)
            Toggle("Hide pool", isOn: $hidePool)
                .help("Hides swim, lap, aqua and other pool sessions")
            Spacer()
            Button { Task { await engine.plan() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload from the YMCA")
        }
    }

    @ViewBuilder private func actionButton(_ i: ScheduleItem) -> some View {
        let s = engine.state(of: i)
        if let a = s.action {
            Button(a.buttonTitle) {
                // Booking is cheap to undo; cancelling a seat in a class that fills isn't.
                if a == .cancel { confirm = (i, a) } else { engine.perform(a, on: i.pick) }
            }
            .controlSize(.small)
            .tint(a == .cancel ? .red : nil)
        } else if s == .booking {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private func status(_ i: ScheduleItem) -> some View {
        let s = engine.state(of: i)
        switch s {
        case .booked: Label("Booked", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .queued: Text("Books at \(opens(i))").foregroundStyle(.orange)
        case .lineup: Text("Weekly · books at \(opens(i))").foregroundStyle(.secondary)
        case .skipped: Text("Skipped").foregroundStyle(.secondary)
        case .future: Text("Opens \(opens(i))").foregroundStyle(.secondary)
        case .open: Text("Open · \(i.capacity) spots")
        case .full: Text("Full").foregroundStyle(.red)
        case .booking, .started: Text(s.label).foregroundStyle(.secondary)
        }
    }

    private var confirmTitle: String {
        guard let (i, _) = confirm else { return "" }
        return "Cancel \(i.name) on \(i.occursAt.formatted(.dateTime.weekday(.wide).month().day()))? Someone else may take the seat."
    }

    private var days: [String] {
        Array(Set((engine.schedule ?? []).map { Pause.day($0.occursAt) })).sorted()
    }

    private var filtered: [ScheduleItem] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return (engine.schedule ?? []).filter { i in
            i.occursAt > Date()
                && (day == "All" || Pause.day(i.occursAt) == day)
                && (branch == 0 || i.branchId == branch)
                && (!onlyMine || isMine(i))
                && ClassFilter.matches(i, hidePool: hidePool, from: from, until: until, calendar: Self.cal)
                && (q.isEmpty || i.name.lowercased().contains(q) || i.room.lowercased().contains(q)
                    || i.trainer.lowercased().contains(q))
        }
    }

    private func isMine(_ i: ScheduleItem) -> Bool {
        [.booked, .queued, .booking, .lineup, .skipped].contains(engine.state(of: i))
    }

    private func opens(_ i: ScheduleItem) -> String {
        i.openAt.formatted(.dateTime.weekday().month().day().hour().minute())
    }

    private func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = FisikalClient.zone
        return c
    }()

    private func dayLabel(_ ymd: String) -> String {
        let f = DateFormatter()
        f.timeZone = FisikalClient.zone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd).map { $0.formatted(.dateTime.weekday().month().day()) } ?? ymd
    }
}
#endif
