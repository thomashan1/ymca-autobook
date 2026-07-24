import SwiftUI

/// Away dates synced to the private repo's `pauses.yml`. Add/remove ranges;
/// paused days grey out on the Week screen and skip their jobs.
struct AwayView: View {
    @EnvironmentObject var pauses: PausesRepository
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if pauses.pauses.isEmpty {
                        Text("No away dates set.").foregroundStyle(.secondary)
                    }
                    ForEach(pauses.pauses) { PauseRow(pause: $0) }
                } header: {
                    Text("Upcoming pauses")
                } footer: {
                    Text("Synced to ymca-private/pauses.yml")
                }
            }
            .navigationTitle("Away Dates")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await pauses.load() }
            .sheet(isPresented: $showAdd) { AddPauseSheet() }
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

/// Placeholder add-range editor; commits to pauses.yml via PausesRepository
/// in a follow-up.
private struct AddPauseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var end = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Start", selection: $start, displayedComponents: .date)
                DatePicker("End", selection: $end, displayedComponents: .date)
            }
            .navigationTitle("Add pause")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { dismiss() } }
            }
        }
    }
}
