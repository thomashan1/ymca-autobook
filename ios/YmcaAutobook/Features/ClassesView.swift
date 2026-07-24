import SwiftUI

/// The recurring lineup, grouped by weekday (like the Week view). A toggle here
/// is intended to commit an edit to `classes.yml` (add/remove the entry) +
/// trigger the cron regen — wired to `ClassesRepository` in a follow-up.
struct ClassesView: View {
    @EnvironmentObject var classes: ClassesRepository

    private let weekdays: [Weekday] = [.mon, .tue, .wed, .thu, .fri]

    private func items(on day: Weekday) -> [GymClass] {
        classes.classes.filter { $0.weekday == day }.sorted { $0.start < $1.start }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
                        Text("A switch turns a class's weekly auto-booking on or off — off keeps it listed here but tells the bot to stop booking it. **Preview: changes aren't saved to the schedule yet.**")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(weekdays, id: \.self) { day in
                    let dayItems = items(on: day)
                    if !dayItems.isEmpty {
                        Section(day.fullName) {
                            ForEach(dayItems) { EnabledRow(gymClass: $0) }
                        }
                    }
                }
            }
            .navigationTitle("My Classes")
            .overlay { if classes.isLoading { ProgressView() } }
            .refreshable { await classes.load() }
        }
    }
}

private struct EnabledRow: View {
    let gymClass: GymClass
    @State private var enabled = true

    var body: some View {
        Toggle(isOn: $enabled) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(gymClass.name).font(.body.weight(.medium))
                    if gymClass.isTrial {
                        Text("Trial").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.queued.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.queued)
                    }
                }
                HStack(spacing: 6) {
                    Text(gymClass.start).font(.caption).foregroundStyle(.secondary)
                    BranchChip(branch: gymClass.branch)
                }
            }
        }
        .tint(Theme.booked)
    }
}
