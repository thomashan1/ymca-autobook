#if os(iOS)
import SwiftUI

/// The left column of a list grouped by day (Schedule, Classes): the day on a
/// day's first row, and a bar running down beside the rest of that day's rows so
/// they read as one block. Pair it with a list separator only after a day's last
/// row (`dayGroupSeparator`).
struct DayColumn: View {
    /// "Mon", or nil on a day's later rows.
    let title: String?
    var subtitle: String? = nil
    var highlight = false
    /// Not the day's first row / not its last.
    var continued = false
    var more = false

    var body: some View {
        VStack(spacing: 1) {
            if let title {
                Text(title)
                    .font(.headline.weight(.heavy)).foregroundStyle(highlight ? Theme.accent : .primary)
                    .lineLimit(1).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary.opacity(0.75))
                        .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                }
            }
            if continued || more {
                // Runs past the row's top and bottom insets so the bars of one day join.
                Capsule().fill(Theme.weekDivider.opacity(0.45)).frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .padding(.top, title != nil ? 6 : -20)
                    .padding(.bottom, more ? -20 : 4)
            }
        }
        // Pinned to the top so the day lines up with the first class name.
        .frame(width: 52)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

extension View {
    /// A full-width line only after a day's last row; none between rows of one day.
    func dayGroupSeparator(last: Bool) -> some View {
        listRowSeparator(last ? .visible : .hidden, edges: .bottom)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
}
#endif
