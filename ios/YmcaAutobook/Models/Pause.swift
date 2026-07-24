import Foundation

/// An away-date range from the private `pauses.yml`.
/// `except` keeps booking specific class keys on an otherwise-paused day.
struct Pause: Identifiable, Codable, Hashable {
    var start: Date
    var end: Date
    var except: [String] = []

    var id: String {
        let f = ISO8601DateFormatter()
        return f.string(from: start) + "_" + f.string(from: end)
    }

    func contains(_ day: Date, calendar: Calendar = .current) -> Bool {
        let d = calendar.startOfDay(for: day)
        return d >= calendar.startOfDay(for: start) && d <= calendar.startOfDay(for: end)
    }
}
