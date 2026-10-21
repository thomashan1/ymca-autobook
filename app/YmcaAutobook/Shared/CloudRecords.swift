import CloudKit
import Foundation

/// The iCloud record shapes shared by both sides: the Mac writes them
/// (macOS/Engine/CloudStore.swift) and the iPhone and iPad read them
/// (iOS/Services/CloudSource.swift). CloudRecordsTests checks that what the
/// Mac writes decodes here.
enum Cloud {
    static let containerId = "iCloud.com.thomashan.ybooker"
    static let zoneName = "YBooker"

    static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName) }

    struct Class: Codable, Hashable {
        let key, name, weekday, start: String
        let locationIds: [Int]
        init?(_ r: CKRecord) {
            guard let key = r["key"] as? String, let name = r["name"] as? String,
                  let wd = r["weekday"] as? String, let start = r["start"] as? String else { return nil }
            self.key = key; self.name = name; weekday = wd; self.start = start
            locationIds = (r["locationIds"] as? [Int]) ?? []
        }
    }

    struct AwayRange: Codable, Hashable {
        let start, end: String
        let except: [String]
        let note: String?
        init?(_ r: CKRecord) {
            guard let s = r["start"] as? String, let e = r["end"] as? String else { return nil }
            start = s; end = e
            except = (r["except"] as? [String]) ?? []
            note = r["note"] as? String
        }
    }

    struct Swap: Codable, Hashable {
        let date: String
        let skip, bookName, bookStart, note: String?
        let bookLocationIds: [Int]
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

    struct Booking: Codable, Hashable {
        let name: String
        let occursAt: Date
        let minutes, branchId: Int
        let room, trainer: String?
        init?(_ r: CKRecord) {
            guard let name = r["name"] as? String, let at = r["occursAt"] as? Date else { return nil }
            self.name = name; occursAt = at
            minutes = (r["minutes"] as? Int) ?? 60
            branchId = (r["branchId"] as? Int) ?? 0
            room = r["room"] as? String
            trainer = r["trainer"] as? String
        }
    }

    struct Slot: Codable, Hashable {
        let name, weekday, start: String
        let branchId, weeks, filledWeeks, filledWithinMinute: Int
        let medianFill, fastestFill: Double?
        let medianWaitlist: Int?
        init?(_ r: CKRecord) {
            guard let name = r["name"] as? String, let wd = r["weekday"] as? String,
                  let start = r["start"] as? String, let b = r["branchId"] as? Int else { return nil }
            self.name = name; weekday = wd; self.start = start; branchId = b
            weeks = (r["weeks"] as? Int) ?? 0
            filledWeeks = (r["filledWeeks"] as? Int) ?? 0
            filledWithinMinute = (r["filledWithinMinute"] as? Int) ?? 0
            medianFill = r["medianFill"] as? Double
            fastestFill = r["fastestFill"] as? Double
            medianWaitlist = r["medianWaitlist"] as? Int
        }
    }

    /// One booking window the Mac handled: what it sent, and how it went.
    struct Opening: Codable, Identifiable, Hashable {
        let id: String
        let classKey: String
        let className: String
        let occursAt: Date
        let openAt: Date
        let away: Bool
        let live: Bool          // a real booking went out (not shadow-only)
        let booked: Bool
        let verdict: String
        let sendLagMs: Int?
        let fillSeconds: Double?

        var failed: Bool { live && !booked && !away }

        init?(_ r: CKRecord) {
            guard let key = r["classKey"] as? String, let name = r["className"] as? String,
                  let occ = r["occursAt"] as? Date, let open = r["openAt"] as? Date else { return nil }
            id = r.recordID.recordName
            classKey = key; className = name; occursAt = occ; openAt = open
            away = (r["away"] as? Bool) ?? false
            live = (r["live"] as? Bool) ?? false
            booked = (r["booked"] as? Bool) ?? false
            verdict = (r["verdict"] as? String) ?? ""
            sendLagMs = r["sendLagMs"] as? Int
            fillSeconds = r["fillSeconds"] as? Double
        }
    }

    /// The Mac's heartbeat: is it up, and what's next.
    struct MacStatus: Codable, Hashable {
        let updatedAt: Date
        let liveClasses: Int
        let nextOpening: Date?
        let nextOpeningClasses: [String]
        let syncError: String?

        /// The Mac re-plans every 3 hours, and each plan updates this record.
        var looksDown: Bool { Date().timeIntervalSince(updatedAt) > 4 * 3600 }

        init?(_ r: CKRecord) {
            guard let u = r["updatedAt"] as? Date else { return nil }
            updatedAt = u
            liveClasses = (r["liveClasses"] as? Int) ?? 0
            nextOpening = r["nextOpening"] as? Date
            nextOpeningClasses = (r["nextOpeningClasses"] as? [String]) ?? []
            syncError = r["syncError"] as? String
        }
    }

    /// One Mac with the app, booking or just watching. Every Mac writes its own
    /// (the booking Mac's heartbeat above is a single record only it writes).
    ///
    /// Stored as a MacStatus record named "mac-<install id>" in fields the
    /// production schema already has (`lastSynced`, `status`), so no schema
    /// deploy. It leaves `updatedAt` empty on purpose: iPhone builds before
    /// 1.2 read every MacStatus record as the heartbeat and skip ones without it.
    struct MacDevice: Codable, Hashable, Identifiable {
        static let prefix = "mac-"

        let id: String          // the record name
        let name: String        // "Thomas's Mac mini"
        let booking: Bool       // false: "Don't book on this Mac"
        let version: String     // "1.2 (20261021.1)"
        let checkedIn: Date
        /// Has a built-in battery (a MacBook); nil from 1.2 (20261021.1), which didn't say.
        var laptop: Bool? = nil

        /// Each Mac checks in at every plan (at least every 3 hours) while awake.
        var looksAsleep: Bool { Date().timeIntervalSince(checkedIn) > 6 * 3600 }
        /// Not seen for a month: probably wiped or sold; no longer listed.
        var gone: Bool { Date().timeIntervalSince(checkedIn) > 30 * 86400 }

        private struct Info: Codable { let name: String; let booking: Bool; let version: String; var laptop: Bool? }

        init(id: String, name: String, booking: Bool, version: String, checkedIn: Date, laptop: Bool? = nil) {
            self.id = id; self.name = name; self.booking = booking; self.version = version; self.checkedIn = checkedIn
            self.laptop = laptop
        }

        init?(_ r: CKRecord) {
            guard r.recordType == "MacStatus", r.recordID.recordName.hasPrefix(Self.prefix),
                  let at = r["lastSynced"] as? Date, let json = (r["status"] as? String)?.data(using: .utf8),
                  let info = try? JSONDecoder().decode(Info.self, from: json) else { return nil }
            self.init(id: r.recordID.recordName, name: info.name, booking: info.booking, version: info.version, checkedIn: at,
                      laptop: info.laptop)
        }

        var fields: [String: CKRecordValue] {
            let info = (try? JSONEncoder().encode(Info(name: name, booking: booking, version: version, laptop: laptop)))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return ["lastSynced": checkedIn as NSDate, "status": info as NSString]
        }

        /// What's worth warning about across all your Macs, if anything. Says
        /// nothing until some Mac has checked in this way (older versions don't).
        static func warning(_ macs: [MacDevice]) -> String? {
            let listed = macs.filter { !$0.gone }
            guard !listed.isEmpty else { return nil }
            // A booking Mac that's gone quiet is the heartbeat's warning already.
            if !listed.contains(where: \.booking) {
                return "No Mac is booking: every Mac is set to \u{201C}Don't book on this Mac\u{201D}."
            }
            let booking = listed.filter { $0.booking && !$0.looksAsleep }
            if booking.count > 1 {
                return "\(booking.count) Macs are booking (\(booking.map(\.name).joined(separator: ", "))). One is enough; set the others to \u{201C}Don't book on this Mac\u{201D}."
            }
            return nil
        }

        /// The Mac that books, when exactly one does: its name stands in for "Mac".
        static func booker(_ macs: [MacDevice]) -> MacDevice? {
            let booking = macs.filter { $0.booking && !$0.gone }
            return booking.count == 1 ? booking[0] : nil
        }

        /// Booking first, then by name.
        static func sorted(_ macs: [MacDevice]) -> [MacDevice] {
            macs.filter { !$0.gone }.sorted { ($0.booking ? 0 : 1, $0.name) < ($1.booking ? 0 : 1, $1.name) }
        }
    }
}
