import SwiftUI

/// Design tokens, the same on the Mac and the iPhone/iPad. Semantic colors (booked/queued/
/// away) are kept separate from the accent so state reads at a glance.
enum Theme {
    static let accent = Color(red: 0.88, green: 0.21, blue: 0.16)   // YMCA-nod red

    static let booked = Color.green
    static let queued = Color.orange
    static let away = Color.secondary
    static let weekDivider = Color(red: 0.13, green: 0.45, blue: 0.82)  // blue week separators

    /// One color per branch, so two branches side by side never look alike.
    /// Southwest blue and Northwest purple are the colors they always had.
    static func color(for branch: Branch) -> Color {
        switch branch.id {
        case 1392: return Color(red: 0.15, green: 0.39, blue: 0.79)
        case 1388: return Color(red: 0.48, green: 0.29, blue: 0.84)
        case 1384: return Color(red: 0.80, green: 0.42, blue: 0.05)
        case 1385: return Color(red: 0.05, green: 0.55, blue: 0.50)
        case 1386: return Color(red: 0.70, green: 0.20, blue: 0.50)
        case 1387: return Color(red: 0.35, green: 0.55, blue: 0.15)
        case 1389: return Color(red: 0.10, green: 0.60, blue: 0.80)
        case 1390: return Color(red: 0.55, green: 0.40, blue: 0.25)
        case 1391: return Color(red: 0.85, green: 0.30, blue: 0.35)
        default: return .gray
        }
    }
}

/// Blue "THIS WEEK" / "NEXT WEEK" band that separates weeks in a List. Shared
/// by the Week and Jobs screens so a week boundary looks the same on both.
/// Must be placed as a direct child of a `List` — it is a `Section`.
struct WeekDivider: View {
    let title: String
    var body: some View {
        Section {
            Text(title.uppercased())
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Theme.weekDivider)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(Theme.weekDivider.opacity(0.14))
        }
    }
}

/// Branch chip: SW, NW, PA…
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

/// How fast a class fills, worded the same everywhere: "Fills in 43 sec".
enum FillSpeed {
    static func duration(_ seconds: Double?) -> String {
        guard let s = seconds else { return "\u{2014}" }
        if s < 120 { return "\(Int(s.rounded())) sec" }
        if s < 7200 { return "\(Int(s / 60)) min" }
        if s < 2 * 86400 { return "\(Int((s / 3600).rounded())) hrs" }
        return "\(Int((s / 86400).rounded())) days"
    }

    /// One class that filled: "Filled in 43 sec".
    static func filled(_ seconds: Double) -> String { "Filled in \(duration(seconds))" }

    static func label(filledWeeks: Int, median: Double?) -> String {
        filledWeeks == 0 ? "Rarely fills" : "Fills in \(duration(median))"
    }
}
