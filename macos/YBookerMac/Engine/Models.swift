import Foundation

/// A recurring class to book every week — same shape as classes.yml.
struct RecurringClass: Codable, Identifiable, Hashable, Sendable {
    let key: String
    let name: String
    let weekday: String      // "Mon" … "Sun"
    let start: String        // local "HH:mm"
    let locationIds: [Int]   // branch: Southwest 1392, Northwest 1388
    var id: String { key }

    var branch: String {
        switch locationIds.first {
        case 1392: return "Southwest"
        case 1388: return "Northwest"
        default: return "?"
        }
    }

    /// Same rule as the Python engine's find_matches: title (case-insensitive),
    /// local weekday and start time. Room and instructor are ignored on purpose.
    func matches(_ o: Occurrence) -> Bool {
        guard o.title.lowercased() == name.lowercased() else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = FisikalClient.zone
        let c = cal.dateComponents([.weekday, .hour, .minute], from: o.occursAt)
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let parts = start.split(separator: ":").compactMap { Int($0) }
        return c.weekday.map { days[$0 - 1] } == weekday && parts == [c.hour ?? -1, c.minute ?? -1]
    }
}

/// An away range; `except` keeps specific classes bookable on those days.
struct Pause: Codable, Sendable {
    let start: String        // yyyy-MM-dd
    let end: String
    let except: [String]?

    func covers(_ date: Date, key: String) -> Bool {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = FisikalClient.zone
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: date)
        return start <= day && day <= end && !(except ?? []).contains(key)
    }
}

/// A specific upcoming booking moment: this class, this occurrence, opening at this instant.
struct Opening: Identifiable, Hashable, Sendable {
    let klass: RecurringClass
    let occurrence: Occurrence
    let paused: Bool
    var id: String { "\(klass.key)-\(occurrence.id)" }
    var openAt: Date { occurrence.openAt }
}

/// What shadow mode saw at one opening — everything except the final join.
struct ShadowEntry: Codable, Identifiable, Sendable {
    struct Sample: Codable, Sendable {
        let at: Date
        let isFull: Bool
        let isJoined: Bool
        let lockVersion: Int
        let waitlist: Int
    }

    var id = UUID()
    let classKey: String
    let className: String
    let occurrenceId: Int
    let occursAt: Date
    let openAt: Date
    let paused: Bool
    var sessionPath: FisikalClient.SessionPath?
    var sessionReadyAt: Date?
    var firedAt: Date?
    /// The read taken at the opening second — the moment a real join would go out.
    var atOpen: Sample?
    var followUps: [Sample] = []
    var fullGroupAt: Date?
    var capacity: Int?
    var error: String?

    /// Would a real booking have gone out at the opening second?
    var verdict: String {
        if paused { return "paused — would skip" }
        if let error { return "error — \(error)" }
        guard let s = atOpen else { return "pending" }
        if s.isJoined { return "already booked (another trigger won)" }
        if s.isFull { return "already FULL at the opening second" }
        return "would book"
    }

    /// Seconds from the window opening to the class filling, if it filled.
    var fillSeconds: Double? { fullGroupAt.map { $0.timeIntervalSince(openAt) } }
    /// How late the shadow read landed after the true opening instant.
    var fireLag: Double? { firedAt.map { $0.timeIntervalSince(openAt) } }
}
