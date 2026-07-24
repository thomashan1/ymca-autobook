import SwiftUI

/// The recurring lineup, grouped by weekday. Swipe a class to delete it — that
/// removes it from classes.yml via a PR (main is protected), which lands
/// automatically. Useful after a trial you didn't enjoy.
struct ClassesView: View {
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var snapshot: SnapshotRepository

    private let weekdays: [Weekday] = [.mon, .tue, .wed, .thu, .fri]

    @State private var deleteTarget: GymClass?
    @State private var deleting = false
    @State private var resultMessage: String?

    private func items(on day: Weekday) -> [GymClass] {
        classes.classes.filter { $0.weekday == day }.sorted { $0.start < $1.start }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
                        Text("Swipe a class left to remove it from the auto-book schedule. It's deleted from classes.yml via a pull request that merges automatically.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(weekdays, id: \.self) { day in
                    let dayItems = items(on: day)
                    if !dayItems.isEmpty {
                        Section(day.fullName) {
                            ForEach(dayItems) { c in
                                ClassInfoRow(gymClass: c,
                                             endTime: snapshot.endTime(for: c),
                                             minutes: snapshot.minutes(for: c))
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
        }
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
                resultMessage = "Couldn't remove \(c.name): \(why)"
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
