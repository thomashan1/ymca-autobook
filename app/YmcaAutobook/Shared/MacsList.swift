import SwiftUI

/// Every Mac with the app on your iCloud account, which one books and which
/// only watch, for Settings on the Mac, iPhone and iPad.
struct MacsList: View {
    let macs: [Cloud.MacDevice]
    /// This Mac's id, on a Mac, to mark it "this Mac".
    var thisMac: String? = nil

    var body: some View {
        if let w = Cloud.MacDevice.warning(macs) {
            Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        let listed = Cloud.MacDevice.sorted(macs)
        if listed.isEmpty {
            Text("No Mac has checked in yet. Each Mac shows up here once it runs YMCA Booker 1.2 or later.")
                .foregroundStyle(.secondary)
        }
        ForEach(listed) { m in
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer").foregroundStyle(m.booking ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.id == thisMac ? "\(m.name) (this Mac)" : m.name)
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text("\(m.version) · checked in \(m.checkedIn.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(m.looksAsleep ? .orange : .secondary)
                    }
                }
                Spacer()
                Text(m.booking ? "Booking" : "Watching")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background((m.booking ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
                    .foregroundStyle(m.booking ? Color.green : Color.secondary)
            }
        }
    }
}
