import SwiftUI

/// Design tokens mirroring the concept mockup. Semantic colors (booked/queued/
/// away) are kept separate from the accent so state reads at a glance.
enum Theme {
    static let accent = Color(red: 0.88, green: 0.21, blue: 0.16)   // YMCA-nod red
    static let southwest = Color(red: 0.15, green: 0.39, blue: 0.79)
    static let northwest = Color(red: 0.48, green: 0.29, blue: 0.84)

    static let booked = Color.green
    static let queued = Color.orange
    static let away = Color.secondary

    static func color(for branch: Branch) -> Color {
        branch == .southwest ? southwest : northwest
    }
}

/// SW / NW branch chip.
struct BranchChip: View {
    let branch: Branch
    var body: some View {
        Text(branch.short)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(Theme.color(for: branch).opacity(0.15), in: Capsule())
            .foregroundStyle(Theme.color(for: branch))
    }
}
