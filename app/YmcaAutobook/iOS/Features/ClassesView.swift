#if os(iOS)
import SwiftUI

/// The recurring lineup, grouped by weekday. Swipe a class to delete it — that
/// removes it from classes.yml in the private repo. Useful after a trial you didn't enjoy.
struct ClassesView: View {
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var snapshot: SnapshotRepository
    @EnvironmentObject var fillStats: FillStatsRepository

    private let weekdays: [Weekday] = [.mon, .tue, .wed, .thu, .fri]

    @EnvironmentObject var bookings: BookingsRepository
    @EnvironmentObject var auth: AuthStore
    @State private var deleteTarget: GymClass?
    @State private var deleting = false
    @State private var resultMessage: String?
    @State private var detail: ClassDetail?

    private func items(on day: Weekday) -> [GymClass] {
        classes.classes.filter { $0.weekday == day }.sorted { $0.start < $1.start }
    }

    /// Shown under a segmented control in a combined tab, which owns the
    /// navigation stack.
    var embedded = false

    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }

    private var content: some View {
            List {
                if !auth.isCloud {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Edits here change classes.yml", systemImage: "doc.text.fill")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                        Text("This is your recurring auto-book schedule, stored in **classes.yml** in your private repo, next to **away.yml** (away dates, under Upcoming → Away). Swiping a class to remove it edits that file.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                }
                if !classes.classes.isEmpty {
                    Section {
                        WeeklyGrid(weekdays: weekdays, items: items(on:), endTime: snapshot.endTime(for:)) {
                            detail = classDetail($0)
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                    }
                }
                ForEach(weekdays, id: \.self) { day in
                    let dayItems = items(on: day)
                    if !dayItems.isEmpty {
                        Section(day.fullName) {
                            ForEach(dayItems) { c in
                                Button {
                                    detail = classDetail(c)
                                } label: {
                                    ClassInfoRow(gymClass: c,
                                                 endTime: snapshot.endTime(for: c),
                                                 minutes: snapshot.minutes(for: c),
                                                 fill: fillStats.stats(for: c))
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing) {
                                    if !auth.isCloud {
                                        Button(role: .destructive) {
                                            deleteTarget = c
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if auth.isCloud {
                    Section {} footer: { Text("Your Mac's lineup. Change classes on the Mac.") }
                }
            }
            .navigationTitle("My Classes")
            .overlay { if classes.isLoading || deleting { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .refreshable { await classes.load() }
            .confirmationDialog(
                deleteTarget.map { "Remove \($0.name) (\($0.weekday.fullName) \($0.start))?" } ?? "",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove from schedule", role: .destructive) {
                    if let c = deleteTarget { remove(c) }
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("Stops auto-booking this class. Removes it from classes.yml in your private repo.")
            }
            .alert("Remove class", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
                Button("OK") { resultMessage = nil }
            } message: {
                Text(resultMessage ?? "")
            }
            .sheet(item: $detail) { ClassDetailSheet(detail: $0) }
    }

    private func classDetail(_ c: GymClass) -> ClassDetail {
        let time = snapshot.endTime(for: c).map { "\(c.start)–\($0)" } ?? c.start
        return ClassDetail(
            name: c.name, whenLabel: "Every \(c.weekday.fullName)", time: time,
            branch: c.branch, booked: false, room: nil, instructor: nil,
            isTrial: c.isTrial, showStatus: false)
    }

    private func remove(_ c: GymClass) {
        deleteTarget = nil
        deleting = true
        Task {
            switch await classes.delete(c) {
            case .merged:
                resultMessage = "Removed \(c.name) from the schedule."
            case .failed(let why):
                if why.contains("403") || why.lowercased().contains("not accessible") {
                    resultMessage = "Couldn't remove \(c.name): your token can't write to the private repo. In your GitHub token settings, set Contents = Read and write (see Settings → How to create a token), then try again."
                } else {
                    resultMessage = "Couldn't remove \(c.name): \(why)"
                }
            }
            deleting = false
        }
    }
}

/// The lineup as a Mon–Fri calendar, one column per day, like the Week tab's
/// calendar but for the recurring classes rather than dated sessions.
private struct WeeklyGrid: View {
    let weekdays: [Weekday]
    let items: (Weekday) -> [GymClass]
    let endTime: (GymClass) -> String?
    let onTap: (GymClass) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            ForEach(weekdays, id: \.self) { day in
                VStack(spacing: 4) {
                    Text(day.fullName.prefix(3)).font(.system(size: 11, weight: .bold))
                    ForEach(items(day)) { c in
                        Button { onTap(c) } label: { cell(c) }.buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func cell(_ c: GymClass) -> some View {
        let color = Theme.color(for: c.branch)
        return VStack(alignment: .leading, spacing: 1) {
            Text(c.start).font(.system(size: 10, weight: .bold)).monospacedDigit()
            if let end = endTime(c) {
                Text("–" + end).font(.system(size: 8)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(c.name).font(.system(size: 9)).lineLimit(3)
            Text(c.branch.short).font(.system(size: 8, weight: .bold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(5)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(color.opacity(0.4), lineWidth: 1))
    }
}

private struct ClassInfoRow: View {
    let gymClass: GymClass
    let endTime: String?
    let minutes: Int?
    let fill: FillStatsRepository.Slot?

    private var title: String {
        if let m = minutes { return "\(gymClass.name) (\(m)m)" }
        return gymClass.name
    }
    private var timeRange: String {
        if let end = endTime { return "\(gymClass.start)–\(end)" }
        return gymClass.start
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.body.weight(.medium))
                if gymClass.isTrial {
                    Text("Trial").font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.queued.opacity(0.18), in: Capsule())
                        .foregroundStyle(Theme.queued)
                }
            }
            HStack(spacing: 6) {
                Text(timeRange).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                BranchChip(branch: gymClass.branch)
                if let fill {
                    Text(fill.filled == 0 ? "never fills"
                         : "fills in ~\(FillStatsRepository.duration(fill.median_fill_s))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(fill.fillsFast ? .red : .secondary)
                }
            }
        }
    }
}
#endif
