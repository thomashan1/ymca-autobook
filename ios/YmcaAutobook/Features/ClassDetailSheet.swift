import SwiftUI

/// Large-font detail popup shown when a class is tapped in Week or Classes.
struct ClassDetail: Identifiable {
    let name: String
    let whenLabel: String        // "Friday, Jul 24" or "Every Monday"
    let time: String             // "9:45 AM – 10:15 AM" or "9:45"
    let branch: Branch
    let booked: Bool
    let room: String?
    let instructor: String?
    let isTrial: Bool
    var showStatus: Bool = true   // false in the recurring Classes list (no single date)

    var id: String { name + "|" + whenLabel + "|" + time }
}

struct ClassDetailSheet: View {
    let detail: ClassDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(detail.name)
                            .font(.largeTitle.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            if detail.showStatus { statusPill }
                            if detail.isTrial {
                                Text("TRIAL").font(.subheadline.weight(.bold))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Theme.queued.opacity(0.18), in: Capsule())
                                    .foregroundStyle(Theme.queued)
                            }
                        }
                    }

                    detailRow("clock", "When", detail.whenLabel)
                    detailRow("timer", "Time", detail.time)
                    detailRow("building.2", "Branch", "\(detail.branch.name) YMCA")
                    detailRow("mappin.and.ellipse", "Room", value(detail.room))
                    detailRow("person", "Instructor", value(detail.instructor))
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Class")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private var statusPill: some View {
        Text(detail.booked ? "BOOKED" : "NOT BOOKED")
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background((detail.booked ? Theme.booked : Theme.away).opacity(0.18), in: Capsule())
            .foregroundStyle(detail.booked ? Theme.booked : Theme.away)
    }

    private func value(_ s: String?) -> String {
        if let s, !s.isEmpty { return s }
        if !detail.showStatus { return "Varies weekly" }
        return detail.booked ? "—" : "Assigned when booked (varies weekly)"
    }

    private func detailRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.southwest).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Text(value).font(.title3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}
