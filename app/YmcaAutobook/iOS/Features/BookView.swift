#if os(iOS)
import SwiftUI

/// Every upcoming session at both branches, to book or cancel one at a time.
/// The iPhone doesn't talk to the YMCA itself: each tap is a request the Mac
/// picks up within about half a minute, and books right away if the window is
/// open, otherwise at the second it opens.
struct BookView: View {
    @ObservedObject private var cloud = CloudSource.shared
    @State private var search = ""
    @State private var branch = 0
    @State private var onlyMine = false
    @State private var confirm: (ScheduleItem, Cloud.Request.Action)?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                header
                ForEach(days, id: \.self) { day in
                    Section(day.formatted(.dateTime.weekday(.wide).month().day())) {
                        ForEach(items(on: day)) { row($0) }
                    }
                }
            }
            .navigationTitle("Book")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Classes, rooms, instructors")
            .refreshable { await cloud.refresh() }
            .task { await cloud.ensureFresh() }
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
    }

    @ViewBuilder private var header: some View {
        Section {
            Picker("Branch", selection: $branch) {
                Text("Both").tag(0)
                Text("Southwest").tag(1392)
                Text("Northwest").tag(1388)
            }
            .pickerStyle(.segmented)
            Toggle("Only mine", isOn: $onlyMine)
            if let mac = cloud.mac, mac.looksDown {
                Label("Your Mac hasn't checked in since \(mac.updatedAt.formatted(.relative(presentation: .named))). Requests wait until it's back.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if cloud.schedule == nil {
                Text(cloud.error ?? "Waiting for the class schedule from your Mac. Update YMCA Booker on the Mac if this stays empty.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Booking opens 7 days ahead. Tap Book on any class: your Mac books it now if it's open, or at the second it opens.")
        }
    }

    private func row(_ i: ScheduleItem) -> some View {
        let s = cloud.state(of: i)
        let branch = Branch(rawValue: i.branchId) ?? .southwest
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(i.name).font(.body.weight(isMine(s) ? .semibold : .regular))
                    BranchChip(branch: branch)
                }
                Text("\(time(i.occursAt))–\(time(i.occursAt.addingTimeInterval(Double(i.minutes) * 60)))"
                     + ([i.room, i.trainer].filter { !$0.isEmpty }.map { " · \($0)" }.joined()))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                status(i, s).font(.caption)
            }
            Spacer(minLength: 4)
            if let a = s.action {
                Button(a == .book ? "Book" : a == .cancel ? "Cancel" : a == .withdraw ? "Undo" : a == .skip ? "Skip" : "Unskip") {
                    if a == .cancel { confirm = (i, a) } else { send(a, i) }
                }
                .buttonStyle(.bordered)
                .tint(a == .cancel ? .red : a == .book ? Theme.accent : .secondary)
                .controlSize(.small)
            } else if s == .booking {
                ProgressView()
            }
        }
    }

    @ViewBuilder private func status(_ i: ScheduleItem, _ s: SessionState) -> some View {
        switch s {
        case .booked: Label("Booked", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.booked)
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
        return (cloud.schedule ?? []).filter { i in
            (branch == 0 || i.branchId == branch)
                && (!onlyMine || isMine(cloud.state(of: i)))
                && (q.isEmpty || i.name.lowercased().contains(q) || i.room.lowercased().contains(q)
                    || i.trainer.lowercased().contains(q))
        }
    }

    private var days: [Date] {
        Array(Set(filtered.map { Self.cal.startOfDay(for: $0.occursAt) })).sorted()
    }

    private func items(on day: Date) -> [ScheduleItem] {
        filtered.filter { Self.cal.isDate($0.occursAt, inSameDayAs: day) }
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

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Config.timeZone
        return c
    }()
}
#endif
