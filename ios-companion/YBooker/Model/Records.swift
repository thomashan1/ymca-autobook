import CloudKit
import Foundation

// What the Mac writes to iCloud (macos/YBookerMac/Engine/CloudStore.swift), read
// back on the phone. The Mac is the only writer; the companion only reads.

struct GymClass: Codable, Identifiable, Hashable {
    let key: String
    let name: String
    let weekday: String      // "Mon" … "Sun"
    let start: String        // "HH:mm"
    let locationIds: [Int]
    let liveBooking: Bool
    var id: String { key }
    var branch: String { Branch.name(locationIds.first ?? 0) }
    var slotKey: String { "\(name.lowercased())|\(weekday)|\(start)|\(locationIds.first ?? 0)" }

    init?(_ r: CKRecord) {
        guard let key = r["key"] as? String, let name = r["name"] as? String,
              let weekday = r["weekday"] as? String, let start = r["start"] as? String else { return nil }
        self.key = key; self.name = name; self.weekday = weekday; self.start = start
        locationIds = (r["locationIds"] as? [Int]) ?? []
        liveBooking = (r["liveBooking"] as? Bool) ?? false
    }
}

struct Pause: Codable, Identifiable, Hashable {
    let start: String        // yyyy-MM-dd
    let end: String
    let except: [String]
    let note: String?
    var id: String { "\(start)…\(end)…\(except.joined(separator: ","))" }
    var isPast: Bool { end < Day.string(Date()) }

    func covers(_ day: String, key: String) -> Bool { start <= day && day <= end && !except.contains(key) }

    init?(_ r: CKRecord) {
        guard let s = r["start"] as? String, let e = r["end"] as? String else { return nil }
        start = s; end = e
        except = (r["except"] as? [String]) ?? []
        note = r["note"] as? String
    }
}

struct Swap: Codable, Identifiable, Hashable {
    let date: String
    let skip: String?
    let bookName: String?
    let bookStart: String?
    let bookLocationIds: [Int]
    let note: String?
    var id: String { "\(date)|\(skip ?? "")|\(bookName ?? "")" }
    var isPast: Bool { date < Day.string(Date()) }

    init?(_ r: CKRecord) {
        guard let d = r["date"] as? String else { return nil }
        date = d
        skip = r["skip"] as? String
        bookName = r["bookName"] as? String
        bookStart = r["bookStart"] as? String
        bookLocationIds = (r["bookLocationIds"] as? [Int]) ?? []
        note = r["note"] as? String
    }
}

/// One booking window the Mac handled: what it sent, and how it went.
struct Opening: Codable, Identifiable, Hashable {
    let id: String               // record name
    let classKey: String
    let className: String
    let occurrenceId: Int
    let occursAt: Date
    let openAt: Date
    let paused: Bool
    let live: Bool               // a real booking went out (not shadow-only)
    let booked: Bool
    let verdict: String
    let sendLagMs: Int?
    let fillSeconds: Double?
    let capacity: Int?

    var failed: Bool { live && !booked && !paused }

    init?(_ r: CKRecord) {
        guard let key = r["classKey"] as? String, let name = r["className"] as? String,
              let occ = r["occursAt"] as? Date, let open = r["openAt"] as? Date else { return nil }
        id = r.recordID.recordName
        classKey = key; className = name; occursAt = occ; openAt = open
        occurrenceId = (r["occurrenceId"] as? Int) ?? 0
        paused = (r["paused"] as? Bool) ?? false
        live = (r["live"] as? Bool) ?? false
        booked = (r["booked"] as? Bool) ?? false
        verdict = (r["verdict"] as? String) ?? ""
        sendLagMs = r["sendLagMs"] as? Int
        fillSeconds = r["fillSeconds"] as? Double
        capacity = r["capacity"] as? Int
    }
}

/// How fast one weekly class slot fills, from the Mac's fill history.
struct SlotStat: Codable, Identifiable, Hashable {
    let id: String               // "name|Wkd|HH:mm|branch"
    let name: String
    let weekday: String
    let start: String
    let branchId: Int
    let weeks: Int
    let filledWeeks: Int
    let medianFill: Double?
    let fastestFill: Double?
    let filledWithinMinute: Int
    let medianWaitlist: Int?
    var branch: String { Branch.name(branchId) }
    var fillsFast: Bool { (medianFill ?? .infinity) <= 300 }

    init?(_ r: CKRecord) {
        guard let name = r["name"] as? String, let wd = r["weekday"] as? String,
              let start = r["start"] as? String, let b = r["branchId"] as? Int else { return nil }
        self.name = name; weekday = wd; self.start = start; branchId = b
        id = "\(name.lowercased())|\(wd)|\(start)|\(b)"
        weeks = (r["weeks"] as? Int) ?? 0
        filledWeeks = (r["filledWeeks"] as? Int) ?? 0
        medianFill = r["medianFill"] as? Double
        fastestFill = r["fastestFill"] as? Double
        filledWithinMinute = (r["filledWithinMinute"] as? Int) ?? 0
        medianWaitlist = r["medianWaitlist"] as? Int
    }
}

/// The Mac's heartbeat: is it up, and what's next.
struct MacStatus: Codable, Hashable {
    let updatedAt: Date
    let status: String
    let signedInAs: String?
    let liveClasses: Int
    let nextOpening: Date?
    let nextOpeningClasses: [String]
    let lastSynced: Date?
    let syncError: String?

    /// The Mac re-plans every 3 hours, and each plan updates this record.
    var looksDown: Bool { Date().timeIntervalSince(updatedAt) > 4 * 3600 }

    init?(_ r: CKRecord) {
        guard let u = r["updatedAt"] as? Date else { return nil }
        updatedAt = u
        status = (r["status"] as? String) ?? ""
        signedInAs = r["signedInAs"] as? String
        liveClasses = (r["liveClasses"] as? Int) ?? 0
        nextOpening = r["nextOpening"] as? Date
        nextOpeningClasses = (r["nextOpeningClasses"] as? [String]) ?? []
        lastSynced = r["lastSynced"] as? Date
        syncError = r["syncError"] as? String
    }
}

// MARK: Helpers

enum Branch {
    // Silicon Valley YMCA. Should come from the YMCA's branch list (#150).
    static func name(_ id: Int) -> String { id == 1392 ? "Southwest" : id == 1388 ? "Northwest" : "Branch \(id)" }
}

enum Day {
    static let zone = TimeZone(identifier: "America/Los_Angeles")!
    static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }()
    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let order = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    static func string(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    static func date(_ s: String) -> Date? {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
    static func weekday(_ d: Date) -> String { weekdays[calendar.component(.weekday, from: d) - 1] }
    /// "Fri 10/23"
    static func short(_ s: String) -> String {
        guard let d = date(s) else { return s }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = zone; f.dateFormat = "EEE M/d"
        return f.string(from: d)
    }
    /// "37s", "4 min", "2 h", "3 d"
    static func duration(_ seconds: Double?) -> String {
        guard let s = seconds else { return "—" }
        if s < 120 { return "\(Int(s.rounded()))s" }
        if s < 7200 { return "\(Int(s / 60)) min" }
        if s < 2 * 86400 { return "\(Int((s / 3600).rounded())) h" }
        return "\(Int((s / 86400).rounded())) d"
    }
}
