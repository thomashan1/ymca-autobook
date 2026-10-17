#if os(macOS)
import Foundation

/// A recurring class to book every week — same shape as classes.yml.
struct RecurringClass: Codable, Identifiable, Hashable, Sendable {
    let key: String
    let name: String
    let weekday: String      // "Mon" … "Sun"
    let start: String        // local "HH:mm"
    let locationIds: [Int]   // the branch, by Fisikal location id (see Branch)
    /// Extra GitHub trigger leads (minutes before the opening) for classes that
    /// fill in seconds; only carried through to classes.yml for the backup.
    var extraLeads: [Int]? = nil
    var id: String { key }

    var branch: String { locationIds.first.map(Branch.name) ?? "?" }

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

extension RecurringClass {
    static let oneOffPrefix = "oneoff-"

    /// A picked session dressed as a class, so it rides the same opening-second
    /// path as the weekly lineup. Away dates and swaps never apply to it.
    static func oneOff(_ p: ClassPick) -> RecurringClass {
        RecurringClass(key: "\(oneOffPrefix)\(p.occurrenceId)", name: p.name, weekday: Slot.weekday(p.occursAt),
                       start: Slot.hhmm(p.occursAt), locationIds: [p.branchId])
    }

    var isOneOff: Bool { key.hasPrefix(Self.oneOffPrefix) }
}

/// An away range; `except` keeps specific classes bookable on those days.
struct AwayRange: Codable, Hashable, Identifiable, Sendable {
    let start: String        // yyyy-MM-dd
    let end: String
    let except: [String]?
    /// The inline `# comment` from away.yml, if any.
    var note: String? = nil
    var id: String { "\(start)…\(end)…\((except ?? []).joined(separator: ","))" }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = FisikalClient.zone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    var isPast: Bool { end < AwayRange.day(Date()) }

    func covers(_ date: Date, key: String) -> Bool {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = FisikalClient.zone
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: date)
        return start <= day && day <= end && !(except ?? []).contains(key)
    }
}

/// A hand-written one-off swap, carried over from swaps.yml before 10/14: on
/// `date`, skip a recurring class and/or book a different one. GitHub's
/// swap-check carries out a replacement; the Mac only honors a skip.
struct Swap: Codable, Hashable, Identifiable, Sendable {
    var date: String             // yyyy-MM-dd, the class date
    var skip: String? = nil      // a class key
    var bookName: String? = nil
    var bookStart: String? = nil
    var bookLocationIds: [Int]? = nil
    var note: String? = nil
    var id: String { "\(date)|\(skip ?? "")|\(bookName ?? "")" }

    var isPast: Bool { date < AwayRange.day(Date()) }
    /// A skip with no replacement: nothing to wait for, so the class just isn't booked.
    /// With a replacement the original stays booked until GitHub's swap-check has
    /// secured the replacement and released it — never an empty slot.
    var isSkipOnly: Bool { skip != nil && bookName == nil }
}

/// One weekly slot in the YMCA's schedule — a class at the same day, time and
/// branch — summarised from the occurrences in the next two weeks.
struct CatalogSlot: Identifiable, Hashable, Sendable {
    let name: String
    let weekday: String
    let start: String            // "HH:mm"
    let end: String
    let branchId: Int
    let rooms: [String]
    let trainers: [String]
    let capacity: Int
    /// Quickest observed fill, seconds after its booking window opened.
    let fastestFill: Double?
    let nextSession: Date
    var id: String { "\(name.lowercased())|\(weekday)|\(start)|\(branchId)" }
    var branch: String { Branch.name(branchId) }
    var hour: Int { Int(start.prefix(2)) ?? 0 }

    func isSame(as k: RecurringClass) -> Bool {
        k.name.lowercased() == name.lowercased() && k.weekday == weekday && k.start == start
            && k.locationIds.contains(branchId)
    }
}

/// A specific upcoming booking moment: this class, this occurrence, opening at this instant.
struct Opening: Identifiable, Hashable, Sendable {
    let klass: RecurringClass
    let occurrence: Occurrence
    let away: Bool
    var id: String { "\(klass.key)-\(occurrence.id)" }
    var openAt: Date { occurrence.openAt }
}

/// What shadow mode saw at one opening — everything except the final join.
struct ShadowEntry: Codable, Identifiable, Sendable {
    struct Sample: Codable, Sendable {
        let at: Date          // when the reply arrived
        var sentAt: Date?     // when the request went out (absent in entries before 10/8)
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
    let away: Bool
    var sessionPath: FisikalClient.SessionPath?
    var sessionReadyAt: Date?
    var firedAt: Date?
    /// The read taken at the opening second — the moment a real join would go out.
    var atOpen: Sample?
    var followUps: [Sample] = []
    var fullGroupAt: Date?
    var capacity: Int?
    var error: String?
    /// Present when this opening was booked for real, not just shadowed.
    var booking: BookingLog?

    struct BookingLog: Codable, Sendable {
        struct Attempt: Codable, Sendable {
            let sentAt: Date
            let repliedAt: Date?
            let result: String
        }
        var attempts: [Attempt] = []
        var outcome = "pending"
        var booked = false
    }

    /// Would a real booking have gone out at the opening second?
    var verdict: String {
        if let b = booking { return b.outcome }
        if away { return "away — would skip" }
        if let error { return "error — \(error)" }
        guard let s = atOpen else { return "pending" }
        if s.isJoined { return "already booked (another trigger won)" }
        if s.isFull { return "already FULL at the opening second" }
        return "would book"
    }

    /// Seconds from the window opening to the class filling, if it filled.
    var fillSeconds: Double? { fullGroupAt.map { $0.timeIntervalSince(openAt) } }
    /// When the reply to the opening-second read arrived, relative to the opening.
    var fireLag: Double? { firedAt.map { $0.timeIntervalSince(openAt) } }
    /// When that read was sent — the moment a real join would have gone out.
    var sendLag: Double? {
        (booking?.attempts.first?.sentAt ?? atOpen?.sentAt).map { $0.timeIntervalSince(openAt) }
    }
}

// MARK: - Fill statistics

/// Identifies a weekly class slot (same class, weekday, start time and branch).
enum Slot {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = FisikalClient.zone
        return c
    }()
    static let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func weekday(_ d: Date) -> String { days[calendar.component(.weekday, from: d) - 1] }
    static func hhmm(_ d: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
    static func key(name: String, weekday: String, start: String, branchId: Int) -> String {
        "\(name.lowercased())|\(weekday)|\(start)|\(branchId)"
    }
    static func branchName(_ id: Int) -> String { Branch.name(id) }
}

extension RecurringClass {
    var slotKey: String { Slot.key(name: name, weekday: weekday, start: start, branchId: locationIds.first ?? 0) }
}

/// One past or open occurrence of any class, kept to build fill history.
/// Fisikal stamps `full_group_at` when a class fills, so this costs no extra requests.
struct FillRecord: Codable, Identifiable, Sendable {
    let id: Int                 // occurrence id
    let name: String
    let weekday: String
    let start: String
    let branchId: Int
    let occursAt: Date
    let openAt: Date
    let capacity: Int
    var fullGroupAt: Date?
    var waitlist: Int
    var lastSeen: Date

    var slotKey: String { Slot.key(name: name, weekday: weekday, start: start, branchId: branchId) }
    /// Seconds from the booking window opening to the class filling.
    var fillSeconds: Double? { fullGroupAt.map { $0.timeIntervalSince(openAt) }.flatMap { $0 >= 0 ? $0 : nil } }
}

/// Aggregated history for one weekly slot.
struct SlotStats: Identifiable, Sendable {
    let id: String
    let name: String
    let weekday: String
    let start: String
    let branchId: Int
    let weeks: Int              // occurrences whose window has opened
    let filledWeeks: Int
    let medianFill: Double?
    let fastestFill: Double?
    let filledWithinMinute: Int
    let medianWaitlist: Int?
    /// From the Mac's own sampling of your classes: median signups by 10/20/30/60 s.
    let signupsBy: [Int: Int]
    let curveWeeks: Int
    var branch: String { Slot.branchName(branchId) }
}

func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

extension ShadowEntry {
    /// Signups since the opening, as of `seconds` after it — from the sampled
    /// signup counter (`lock_version` goes up by one per booking).
    func signups(by seconds: Double) -> Int? {
        guard let first = atOpen else { return nil }
        let all = [first] + followUps
        guard let last = all.filter({ $0.at.timeIntervalSince(openAt) <= seconds }).max(by: { $0.at < $1.at })
        else { return nil }
        // Only trust a count if we sampled close to that moment — or the class
        // was already full, in which case nothing changes after.
        let sampledNear = all.contains { $0.at.timeIntervalSince(openAt) >= seconds - 3 }
        guard sampledNear || last.isFull else { return nil }
        return max(0, last.lockVersion - first.lockVersion)
    }
}
#endif
