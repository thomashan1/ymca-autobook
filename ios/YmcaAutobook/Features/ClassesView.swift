import SwiftUI

/// Regulars vs. trials. A toggle here is intended to commit an edit to
/// `classes.yml` (add/remove the entry) + trigger the cron regen — wired to
/// `ClassesRepository.setEnabled` in a follow-up.
struct ClassesView: View {
    @EnvironmentObject var classes: ClassesRepository

    var body: some View {
        NavigationStack {
            List {
                if !classes.regulars.isEmpty {
                    Section("Regulars · \(classes.regulars.count)") {
                        ForEach(classes.regulars) { EnabledRow(gymClass: $0) }
                    }
                }
                if !classes.trials.isEmpty {
                    Section("Trials · \(classes.trials.count)") {
                        ForEach(classes.trials) { EnabledRow(gymClass: $0) }
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
                Text(gymClass.name).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text("\(gymClass.weekday.rawValue) · \(gymClass.start)")
                        .font(.caption).foregroundStyle(.secondary)
                    BranchChip(branch: gymClass.branch)
                }
            }
        }
        .tint(Theme.booked)
    }
}
