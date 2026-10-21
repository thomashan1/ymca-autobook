import SwiftUI

/// One class in the two-week calendar, the same on the Mac and the iPhone/iPad:
/// the time (with a ✓ once booked) over the name. Booked is green, waiting is
/// grey, skipped or away is struck through and dimmed, and past is faded.
struct CalendarCell: View {
    let time: String
    let name: String
    var booked = false
    /// Not happening for you that day: skipped, away, or swapped out.
    var dropped = false
    var past = false
    /// A just-once class or a swap's replacement: orange instead of grey.
    var queued = false
    /// An extra symbol after the time (the iPhone's swap arrows).
    var symbol: (name: String, color: Color)? = nil
    var font: CGFloat = 13

    static let booked = Color.green
    static let queued = Color.orange

    private var tint: Color? {
        if dropped { return nil }
        if booked { return Self.booked }
        return queued ? Self.queued : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Text(time).font(.system(size: font, weight: .bold)).monospacedDigit()
                if let symbol {
                    Image(systemName: symbol.name)
                        .font(.system(size: font - 1, weight: .heavy))
                        .foregroundStyle(symbol.color)
                }
                if booked && !dropped {
                    Image(systemName: "checkmark").font(.system(size: font - 1, weight: .heavy))
                        .foregroundStyle(Self.booked)
                }
            }
            nameText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(5)
        .background((tint ?? .secondary).opacity(tint == nil ? 0.10 : 0.18), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tint?.opacity(0.5) ?? .clear, lineWidth: 1))
        .foregroundStyle(dropped ? .secondary : .primary)
        .strikethrough(dropped, color: .secondary)
        .opacity(past ? 0.4 : (dropped ? 0.6 : 1))
    }

    /// Several words wrap; one long word ("BODYBALANCE") shrinks only when it
    /// doesn't fit. (A plain minimumScaleFactor shrank short names like "RPM"
    /// too, depending on how SwiftUI measured the column.)
    @ViewBuilder private var nameText: some View {
        if name.contains(" ") {
            Text(name).font(.system(size: font)).lineLimit(3)
        } else {
            ViewThatFits(in: .horizontal) {
                Text(name).font(.system(size: font)).lineLimit(1)
                Text(name).font(.system(size: font)).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }
}
