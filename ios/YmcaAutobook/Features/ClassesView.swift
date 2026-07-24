import SwiftUI

/// The recurring lineup, grouped by weekday. Swipe a class to delete it — that
/// removes it from classes.yml via a PR (main is protected), which lands
/// automatically. Useful after a trial you didn't enjoy.
struct ClassesView: View {
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var snapshot: SnapshotRepository

    private let weekdays: [Weekday] = [.mon, .tue, .wed, .thu, .fri]

    @EnvironmentObject var bookings: BookingsRepository
    @State private var deleteTarget: GymClass?
    @State private var deleting = false
    @State private var resultMessage: String?
    @State private var detail: ClassDetail?

    private func items(on day: Weekday) -> [GymClass] {
        classes.classes.filter { $0.weekday == day }.sorted { $0.start < $1.start }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Edits here change classes.yml", systemImage: "doc.text.fill")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                        Text("This is your recurring auto-book schedule, stored in **classes.yml** in the public repo **thomashan1/ymca-autobook**. Swiping a class to remove it opens a pull request against that file (main is protected) which merges automatically. Away dates live separately in **pauses.yml** (private repo) — edit those on the Away tab.")
                            .font(.footnote).foregroundStyle(.secondary)
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
                                                 minutes: snapshot.minutes(for: c))
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing) {
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
                Text("Stops auto-booking this class. Opens a PR against classes.yml that merges automatically.")
            }
            .alert("Remove class", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
                Button("OK") { resultMessage = nil }
            } message: {
                Text(resultMessage ?? "")
            }
            .sheet(item: $detail) { ClassDetailSheet(detail: $0) }
        }
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
            case .prOpened(let n, _):
                resultMessage = "Opened PR #\(n) to remove \(c.name). It'll merge automatically once checks pass."
            case .failed(let why):
                if why.contains("403") || why.lowercased().contains("not accessible") {
                    resultMessage = "Couldn't remove \(c.name): your token can't open a pull request. In your GitHub token settings, add Pull requests = Read and write (see Settings → How to create a token), then try again."
                } else {
                    resultMessage = "Couldn't remove \(c.name): \(why)"
                }
            }
            deleting = false
        }
    }
}

private struct ClassInfoRow: View {
    let gymClass: GymClass
    let endTime: String?
    let minutes: Int?

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
            }
        }
    }
}
