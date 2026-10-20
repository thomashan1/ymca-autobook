#if os(iOS)
import SwiftUI

/// Your classes: the weekly lineup, each with how fast it fills, and single
/// sessions queued to book once. "Add a class" opens the YMCA schedule to add
/// one either way. Swipe a weekly class to stop booking it (via the Mac in
/// iCloud mode, or a commit to classes.yml with GitHub).
struct ClassesView: View {
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var snapshot: SnapshotRepository
    @EnvironmentObject var fillStats: FillStatsRepository
    @EnvironmentObject var auth: AuthStore
    @ObservedObject private var cloud = CloudSource.shared

    @State private var deleteTarget: GymClass?
    @State private var deleting = false
    @State private var resultMessage: String?
    @State private var detail: ClassDetail?
    @State private var adding = UserDefaults.standard.bool(forKey: "screenshotAdding")

    /// Adding and single sessions go through the Mac.
    private var viaMac: Bool { auth.isCloud || SampleMode.active }

    var body: some View {
        NavigationStack {
            List {
                if !auth.looksCloud {
                    Section {
                        Label("Edits here change classes.yml in your private repo", systemImage: "doc.text.fill")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(classes.classes) { c in
                        Button { detail = classDetail(c) } label: {
                            ClassInfoRow(gymClass: c, endTime: snapshot.endTime(for: c), fill: fillStats.stats(for: c))
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleteTarget = c } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                    if classes.classes.isEmpty {
                        Text(viaMac ? "None yet. Tap Add a class." : "None yet.").foregroundStyle(.secondary)
                    }
                } header: { Text("Every week") }
                if viaMac, !cloud.oneOffs.isEmpty {
                    Section("Just once") {
                        ForEach(cloud.oneOffs) { p in
                            OneOffRow(pick: p)
                                .swipeActions(edge: .trailing) {
                                    Button("Don't book") { withdraw(p) }.tint(.orange)
                                }
                        }
                    }
                }
                Section {
                    NavigationLink { FillStatsView() } label: {
                        Label("How fast every class fills", systemImage: "chart.bar")
                    }
                } footer: {
                    Text(viaMac ? "Swipe a class to stop booking it. Your Mac makes the change within a minute."
                                : "Swipe a class to stop booking it.")
                }
            }
            .navigationTitle("Classes")
            .toolbar {
                if viaMac {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { adding = true } label: { Label("Add a class", systemImage: "plus") }
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .overlay { if classes.isLoading || deleting { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .refreshable {
                if auth.isCloud { await cloud.refresh() }
                await classes.load(); await fillStats.load()
            }
            .confirmationDialog(
                deleteTarget.map { "Stop booking \($0.name) every \($0.weekday.fullName)?" } ?? "",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Stop booking every week", role: .destructive) {
                    if let c = deleteTarget { remove(c) }
                }
                Button("Keep it", role: .cancel) { deleteTarget = nil }
            } message: {
                Text(viaMac ? "Classes already booked stay booked." : "Removes it from classes.yml in your private repo.")
            }
            .alert("Classes", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
                Button("OK") { resultMessage = nil }
            } message: {
                Text(resultMessage ?? "")
            }
            .sheet(item: $detail) { ClassDetailSheet(detail: $0) }
            .sheet(isPresented: $adding, onDismiss: { Task { await classes.load() } }) { BookView() }
        }
    }

    private func withdraw(_ p: ClassPick) {
        Task {
            do { try await cloud.send(.withdraw, p) }
            catch { resultMessage = "Couldn't reach iCloud: \(error.localizedDescription)" }
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
        if viaMac {
            Task {
                do {
                    try await cloud.sendWeekly(add: false, name: c.name, weekday: c.weekday.rawValue, start: c.start,
                                               branchId: c.locationIds.first ?? 0)
                    await classes.load()
                } catch { resultMessage = "Couldn't reach iCloud: \(error.localizedDescription)" }
            }
            return
        }
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

private struct ClassInfoRow: View {
    let gymClass: GymClass
    let endTime: String?
    let fill: FillStatsRepository.Slot?

    private var timeRange: String {
        if let end = endTime { return "\(gymClass.start)–\(end)" }
        return gymClass.start
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(gymClass.weekday.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(gymClass.name).font(.body.weight(.medium))
                    if gymClass.key.hasPrefix("pending-") { ProgressView().controlSize(.mini) }
                }
                HStack(spacing: 6) {
                    Text(timeRange).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    BranchChip(branch: gymClass.branch)
                }
            }
            Spacer(minLength: 4)
            if let fill {
                Text(fill.filled == 0 ? "Rarely fills" : "Fills in \(FillStatsRepository.duration(fill.median_fill_s))")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((fill.fillsFast ? Color.orange : Color.secondary).opacity(0.16), in: Capsule())
                    .foregroundStyle(fill.fillsFast ? Color.orange : Color.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A single session queued to book once.
private struct OneOffRow: View {
    let pick: ClassPick

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(pick.occursAt.formatted(.dateTime.weekday(.abbreviated))).font(.caption.weight(.bold))
                Text(pick.occursAt.formatted(.dateTime.month(.defaultDigits).day())).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(pick.name).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(pick.occursAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    BranchChip(branch: Branch(pick.branchId))
                }
            }
            Spacer(minLength: 4)
            Text(pick.openAt > Date() ? "Books \(pick.openAt.formatted(.dateTime.weekday()))" : "Booking…")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.weekDivider.opacity(0.16), in: Capsule())
                .foregroundStyle(Theme.weekDivider)
        }
    }
}
#endif
