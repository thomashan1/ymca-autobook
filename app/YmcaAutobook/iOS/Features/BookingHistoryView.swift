#if os(iOS)
import SwiftUI

/// Every booking window the Mac handled in the last two weeks: what it sent,
/// how fast the reply came and how it went. Settings → Booking history.
struct BookingHistoryView: View {
    @ObservedObject private var cloud = CloudSource.shared

    var body: some View {
        let recent = cloud.openings.filter { $0.openAt > Date().addingTimeInterval(-14 * 86400) }
        List {
            Section { MacStatusRow() }
            Section {
                if recent.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(recent) { OpeningRow(o: $0) }
            } footer: {
                Text("The time is how long after the opening second your Mac's booking went out.")
            }
        }
        .navigationTitle("Booking history")
        .refreshable { await cloud.refresh() }
    }
}

/// The Mac app's heartbeat from iCloud: is it up, and which window opens next.
struct MacStatusRow: View {
    @ObservedObject private var cloud = CloudSource.shared

    var body: some View {
        if let m = cloud.mac {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: m.looksDown ? "desktopcomputer.trianglebadge.exclamationmark" : "desktopcomputer")
                        .foregroundStyle(m.looksDown ? Theme.accent : Theme.booked)
                    Text(m.looksDown ? "Mac hasn't checked in"
                         : "Mac is booking \(m.liveClasses) class\(m.liveClasses == 1 ? "" : "es")")
                        .font(.body.weight(.medium))
                }
                Text("Last heard from \(m.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(m.looksDown ? Theme.accent : .secondary)
                if let next = m.nextOpening, next > Date() {
                    Text("Next: \(m.nextOpeningClasses.joined(separator: " + ")) opens \(next.formatted(.dateTime.weekday().hour().minute()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let e = m.syncError {
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.queued)
                }
            }
        } else {
            Text(cloud.error ?? "Waiting for your Mac — open YMCA Booker on it, signed in to the same iCloud account.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// One booking window the Mac handled.
private struct OpeningRow: View {
    let o: CloudSource.Opening

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: o.away ? "airplane" : o.booked ? "checkmark.circle.fill" : o.live ? "xmark.circle.fill" : "eye")
                .foregroundStyle(o.away ? Color.secondary : o.booked ? Theme.booked : o.live ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(o.className).font(.body.weight(.medium))
                Text("for \(o.occursAt.formatted(.dateTime.weekday().month().day().hour().minute()))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(o.verdict).font(.caption).foregroundStyle(o.failed ? Theme.accent : .secondary)
            }
            Spacer()
            if let ms = o.sendLagMs {
                Text("+\(ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
