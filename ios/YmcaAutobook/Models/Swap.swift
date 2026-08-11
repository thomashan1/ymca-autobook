import Foundation

/// How a one-off swap touches a particular occurrence on the Week screen.
enum SwapRole {
    /// The one-off class taking the slot — booked only this once.
    case replacement
    /// The recurring class the swap displaces on this date.
    case displaced
}

/// A one-off schedule exception from the private `swaps.yml`: on a single date,
/// drop a recurring class and take a different one instead.
///
/// Either half may be absent — `skipKey` alone is a one-day skip, `bookName`
/// alone adds a class without displacing anything.
struct Swap: Identifiable, Hashable {
    var date: Date
    var skipKey: String?
    var bookName: String?
    var bookStart: String?
    var bookLocationIDs: [Int] = []
    var note: String?

    var id: String {
        let f = ISO8601DateFormatter()
        return f.string(from: date) + "_" + (skipKey ?? "") + "_" + (bookName ?? "")
    }

    /// Branch name for the replacement, matching the ids used in classes.yml.
    var bookBranch: String? {
        guard let first = bookLocationIDs.first else { return nil }
        switch first {
        case 1392: return "Southwest"
        case 1388: return "Northwest"
        default: return nil
        }
    }

    /// "Cycle → BODYCOMBAT 9:50", with an em dash standing in for a missing half.
    var summary: String {
        let left = skipKey ?? "—"
        let right = [bookName, bookStart].compactMap { $0 }.joined(separator: " ")
        return "\(left) → \(right.isEmpty ? "—" : right)"
    }

    func matches(_ day: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(day, inSameDayAs: date)
    }
}
