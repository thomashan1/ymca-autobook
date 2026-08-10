import Foundation

/// An away-date range from the private `pauses.yml`.
/// `except` keeps booking specific class keys on an otherwise-paused day.
struct Pause: Identifiable, Codable, Hashable {
    var start: Date
    var end: Date
    var except: [String] = []
    /// The inline "# comment" from pauses.yml, if any.
    var note: String? = nil
    /// Standalone "#" lines that sat above this entry in pauses.yml (section
    /// headers hand-written in the repo). Carried so a write-back from the app
    /// re-emits them instead of silently flattening the file.
    var header: [String] = []

    var id: String {
        let f = ISO8601DateFormatter()
        return f.string(from: start) + "_" + f.string(from: end)
    }

    func contains(_ day: Date, calendar: Calendar = .current) -> Bool {
        let d = calendar.startOfDay(for: day)
        return d >= calendar.startOfDay(for: start) && d <= calendar.startOfDay(for: end)
    }
}
