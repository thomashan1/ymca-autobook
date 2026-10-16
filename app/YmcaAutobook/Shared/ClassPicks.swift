import CloudKit
import Foundation

/// One specific session to book, outside the weekly lineup: right away if its
/// booking window is already open, otherwise at the second it opens. Picked on
/// the Mac directly, or on the iPhone and sent to the Mac as a `Cloud.Request`.
struct ClassPick: Codable, Hashable, Identifiable, Sendable {
    let occurrenceId: Int
    let name: String
    let occursAt: Date
    /// When booking opens (occurs_at − 167h at this club).
    let openAt: Date
    let branchId: Int
    var room: String = ""
    var trainer: String = ""
    var id: Int { occurrenceId }

    func isOpen(at now: Date = Date()) -> Bool { openAt <= now }
}

/// One upcoming session on the YMCA schedule, as the Mac last saw it. The Mac
/// publishes the whole list so the iPhone can pick from it without signing in
/// to the YMCA itself.
struct ScheduleItem: Codable, Hashable, Identifiable, Sendable {
    let id: Int              // occurrence id
    let name: String
    let occursAt: Date
    let openAt: Date
    let minutes: Int
    let branchId: Int
    let room: String
    let trainer: String
    let capacity: Int
    let full: Bool
    let joined: Bool
    /// In the weekly lineup: the Mac books it at the opening anyway.
    let autoBook: Bool

    var pick: ClassPick {
        ClassPick(occurrenceId: id, name: name, occursAt: occursAt, openAt: openAt, branchId: branchId,
                  room: room, trainer: trainer)
    }
}

extension Cloud {
    // MARK: Picks the Mac has queued (written by the Mac)

    static func fields(_ p: ClassPick) -> [String: CKRecordValue] {
        var f: [String: CKRecordValue] = [
            "occurrenceId": NSNumber(value: p.occurrenceId), "name": p.name as NSString,
            "occursAt": p.occursAt as NSDate, "openAt": p.openAt as NSDate,
            "branchId": NSNumber(value: p.branchId),
        ]
        if !p.room.isEmpty { f["room"] = p.room as NSString }
        if !p.trainer.isEmpty { f["trainer"] = p.trainer as NSString }
        return f
    }

    static func pick(_ r: CKRecord) -> ClassPick? {
        guard let id = r["occurrenceId"] as? Int, let name = r["name"] as? String,
              let at = r["occursAt"] as? Date, let open = r["openAt"] as? Date else { return nil }
        return ClassPick(occurrenceId: id, name: name, occursAt: at, openAt: open,
                         branchId: (r["branchId"] as? Int) ?? 0,
                         room: (r["room"] as? String) ?? "", trainer: (r["trainer"] as? String) ?? "")
    }

    // MARK: The upcoming schedule (written by the Mac, one record)

    static let scheduleRecordName = "Schedule.current"

    static func encodeSchedule(_ items: [ScheduleItem]) -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = .sortedKeys
        return (try? e.encode(items)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    static func schedule(_ r: CKRecord) -> [ScheduleItem]? {
        guard let s = r["items"] as? String else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode([ScheduleItem].self, from: Data(s.utf8))
    }

    // MARK: Requests from the iPhone to the Mac

    /// Something for the Mac to do to one session, written by the iPhone. The
    /// Mac reads it from the zone's change feed within about half a minute, acts
    /// on it and deletes it; the result comes back in its own records.
    struct Request: Codable, Hashable, Identifiable, Sendable {
        enum Action: String, Codable, Sendable {
            /// Book it: now if the window is open, else at the opening second.
            case book
            /// Take a queued pick back off the queue.
            case withdraw
            /// Cancel a booking we hold.
            case cancel
            /// Don't book this week's session of a lineup class / undo that.
            case skip, unskip
        }

        static let recordType = "BookRequest"

        var id: String
        let action: Action
        let pick: ClassPick
        let requestedAt: Date

        init(action: Action, pick: ClassPick, requestedAt: Date = Date(), id: String = UUID().uuidString) {
            self.id = "\(Self.recordType).\(id)"
            self.action = action
            self.pick = pick
            self.requestedAt = requestedAt
        }

        init?(_ r: CKRecord) {
            guard r.recordType == Self.recordType,
                  let a = (r["action"] as? String).flatMap(Action.init(rawValue:)),
                  let p = Cloud.pick(r) else { return nil }
            id = r.recordID.recordName
            action = a
            pick = p
            requestedAt = (r["requestedAt"] as? Date) ?? r.creationDate ?? Date()
        }

        func record() -> CKRecord {
            let r = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: id, zoneID: Cloud.zoneID))
            for (k, v) in Cloud.fields(pick) { r[k] = v }
            r["action"] = action.rawValue as NSString
            r["requestedAt"] = requestedAt as NSDate
            return r
        }
    }
}

/// What to do with the queued picks, given a fresh read of the schedule. Pure,
/// so the tests can drive it.
enum PickTriage {
    struct Result: Equatable {
        /// Still waiting for their window: book at the opening second.
        var atOpening: [Int] = []
        /// Window already open and not booked yet: book now.
        var now: [Int] = []
        /// Done with: booked, already handled by the weekly lineup, or over.
        var drop: [Int] = []
    }

    /// `seen` maps occurrence id to (isJoined, openAt) for every occurrence in
    /// the fetched range; `lineup` is the ids the weekly lineup will book itself.
    static func run(_ picks: [ClassPick], seen: [Int: (joined: Bool, openAt: Date)],
                    lineup: Set<Int>, now: Date) -> Result {
        var r = Result()
        for p in picks {
            if p.occursAt <= now { r.drop.append(p.id); continue }
            guard let s = seen[p.id] else {
                // Not on the schedule any more (cancelled or moved). Keep it until it
                // would have happened, in case it was just outside the fetched range.
                continue
            }
            if s.joined || lineup.contains(p.id) { r.drop.append(p.id) }
            else if s.openAt > now { r.atOpening.append(p.id) }
            else { r.now.append(p.id) }
        }
        return r
    }

    /// The pick queue and skip list after applying requests from the iPhone,
    /// oldest first. Cancels aren't list changes; the caller carries them out.
    static func apply(_ requests: [Cloud.Request], picks: [ClassPick], skips: [ClassPick])
        -> (picks: [ClassPick], skips: [ClassPick]) {
        var p = picks, k = skips
        for q in requests.sorted(by: { $0.requestedAt < $1.requestedAt }) {
            switch q.action {
            case .book: p.removeAll { $0.id == q.pick.id }; p.append(q.pick); k.removeAll { $0.id == q.pick.id }
            case .withdraw: p.removeAll { $0.id == q.pick.id }
            case .skip: k.removeAll { $0.id == q.pick.id }; k.append(q.pick); p.removeAll { $0.id == q.pick.id }
            case .unskip: k.removeAll { $0.id == q.pick.id }
            case .cancel: break
            }
        }
        return (p.sorted { $0.openAt < $1.openAt }, k.sorted { $0.occursAt < $1.occursAt })
    }
}

/// Where one session stands for us, and so what can be done to it. Shared so
/// the Mac and the iPhone show the same thing and offer the same actions.
enum SessionState: Equatable {
    case booked            // ours → cancel
    case queued            // picked, waiting for its window → withdraw
    case booking           // picked, window open, the Mac is on it
    case lineup            // weekly lineup, window not open yet → skip
    case skipped           // lineup session we said no to → unskip
    case future            // window not open yet → book when it opens
    case open              // window open, seats left → book now
    case full              // window open, no seats
    case started           // too late

    init(_ i: ScheduleItem, picked: Bool, skipped: Bool, now: Date = Date()) {
        if i.joined { self = .booked; return }
        if i.occursAt <= now { self = .started; return }
        if picked { self = i.openAt <= now ? .booking : .queued; return }
        if i.openAt > now {
            self = skipped ? .skipped : i.autoBook ? .lineup : .future
        } else {
            self = i.full ? .full : .open
        }
    }

    /// The one action this state offers, if any.
    var action: Cloud.Request.Action? {
        switch self {
        case .booked: return .cancel
        case .queued: return .withdraw
        case .lineup: return .skip
        case .skipped: return .unskip
        case .future, .open: return .book
        case .booking, .full, .started: return nil
        }
    }

    var label: String {
        switch self {
        case .booked: return "Booked"
        case .queued: return "Queued"
        case .booking: return "Booking…"
        case .lineup: return "Weekly"
        case .skipped: return "Skipped"
        case .future: return "Not open yet"
        case .open: return "Open"
        case .full: return "Full"
        case .started: return "Started"
        }
    }
}

extension Cloud.Request.Action {
    var buttonTitle: String {
        switch self {
        case .book: return "Book"
        case .withdraw: return "Don't book"
        case .cancel: return "Cancel booking"
        case .skip: return "Skip this one"
        case .unskip: return "Book it after all"
        }
    }
}

/// Book-screen filters shared by the Mac and the iPhone.
enum ClassFilter {
    /// Pool sessions (lap swim, aqua classes, lessons…), which most people
    /// browsing for a class want out of the way. Matched on the name and room
    /// because the YMCA has no category field for them.
    static func isPool(name: String, room: String) -> Bool {
        let text = (name + " " + room).lowercased()
        return ["swim", "aqua", "lap", "pool", "water"].contains { text.contains($0) }
    }

    /// Start-time choices for the From / Until filters, every half hour,
    /// as minutes after midnight. -1 means no limit.
    static let timeChoices: [Int] = Array(stride(from: 5 * 60, through: 21 * 60, by: 30))

    static func timeLabel(_ m: Int) -> String {
        let h = m / 60, mm = m % 60
        return "\(h % 12 == 0 ? 12 : h % 12)\(mm == 0 ? "" : String(format: ":%02d", mm)) \(h < 12 ? "AM" : "PM")"
    }

    /// Keeps a class that starts at or after `from` and before `until`
    /// (minutes after midnight, -1 = no limit).
    static func matches(_ i: ScheduleItem, hidePool: Bool, from: Int, until: Int, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: i.occursAt)
        let start = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return (!hidePool || !isPool(name: i.name, room: i.room))
            && (from < 0 || start >= from) && (until < 0 || start < until)
    }
}
