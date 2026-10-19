#if os(macOS)
import CloudKit
import CryptoKit
import Foundation
import os

/// Mirrors the Mac's state into the user's own iCloud (CloudKit private
/// database), for the iPhone and iPad to read (#147, #149). Record shapes are decoded by
/// Shared/CloudRecords.swift; CloudRecordsTests keeps the two in step.
///
/// The Mac is the only writer, and the local files stay the source of truth for
/// booking: nothing on the booking path ever waits on iCloud. A push that fails
/// is simply retried with the next one.
///
/// Records have stable names, and a content hash per record is kept locally, so
/// a push sends only what changed and deletes what's gone — no CloudKit queries
/// (which would need indexes set up in the CloudKit console).
actor CloudStore {
    static let shared = CloudStore()
    static let containerId = Cloud.containerId

    /// Everything the companion shows, captured on the main actor.
    struct Snapshot: Sendable {
        var classes: [RecurringClass]
        var awayRanges: [AwayRange]
        var swaps: [Swap]
        var log: [ShadowEntry]
        var stats: [SlotStats]
        /// nil until the first plan since launch: keep what iCloud has rather than wipe it.
        var bookings: [Booking]?
        /// Sessions picked to book outside the lineup, waiting for their window.
        var picks: [ClassPick] = []
        /// Lineup sessions not to book this time.
        var skips: [ClassPick] = []
        /// Upcoming sessions at both branches, for picking on the iPhone. nil
        /// until the first plan since launch, like `bookings`.
        var schedule: [ScheduleItem]? = nil
        var status: MacStatus
    }

    /// A class the YMCA has us joined to, as of the last plan — the real list,
    /// so the phone shows bookings made by any trigger and drops cancelled ones.
    struct Booking: Sendable {
        var occurrenceId: Int
        var name: String
        var occursAt: Date
        var minutes: Int
        var branchId: Int
        var room: String
        var trainer: String
    }

    /// A heartbeat so the companion can tell whether the Mac is up.
    struct MacStatus: Sendable {
        var updatedAt: Date
        var status: String
        var signedInAs: String?
        var liveClasses: Int
        var nextOpening: Date?
        var nextOpeningClasses: [String]
        var lastSynced: Date?
        var syncError: String?
    }

    private let logger = Logger(subsystem: "com.thomashan.ymcaautobook", category: "cloud")

    enum Failure: LocalizedError {
        case account(CKAccountStatus)
        case records(Int, String)
        var errorDescription: String? {
            switch self {
            case .account(.noAccount): return "Not signed in to iCloud on this Mac"
            case .account(.restricted): return "iCloud is restricted on this Mac"
            case .account(.temporarilyUnavailable): return "iCloud is temporarily unavailable"
            case .account: return "iCloud account status unknown"
            case .records(let n, let first): return "iCloud rejected \(n) record(s): \(first)"
            }
        }
    }

    private nonisolated let zoneID = Cloud.zoneID
    private var zoneReady = false
    /// recordName -> content hash of what's in iCloud now.
    private var pushed: [String: String] = CloudStore.loadPushed()
    /// Booking log kept in iCloud for this long.
    private nonisolated let logDays: TimeInterval = 120 * 86400

    private var database: CKDatabase { CKContainer(identifier: Self.containerId).privateCloudDatabase }

    /// Push everything that changed since the last push. Returns how many records
    /// were saved and deleted.
    func push(_ s: Snapshot) async throws -> (saved: Int, deleted: Int) {
        let status = try await CKContainer(identifier: Self.containerId).accountStatus()
        guard status == .available else { throw Failure.account(status) }
        if !zoneReady {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            zoneReady = true
        }

        let records = build(s)
        let wanted = Dictionary(records.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let toSave = wanted.values.filter { pushed[$0.name] != $0.hash }
        let toDelete = pushed.keys.filter {
            wanted[$0] == nil && (s.bookings != nil || !$0.hasPrefix("Booking."))
                && (s.schedule != nil || !$0.hasPrefix(Cloud.schedulePrefix))
        }

        var saved = 0, deleted = 0
        var failures: [String] = []
        // CloudKit takes at most 400 records per request.
        for chunk in toSave.chunked(400) {
            let (results, _) = try await database.modifyRecords(
                saving: chunk.map(\.record), deleting: [], savePolicy: .allKeys, atomically: false)
            for (id, r) in results {
                switch r {
                case .success:
                    if let h = wanted[id.recordName]?.hash { pushed[id.recordName] = h; saved += 1 }
                case .failure(let e):
                    failures.append("\(id.recordName): \(e)")
                    logger.error("save \(id.recordName, privacy: .public) failed: \(String(describing: e), privacy: .public)")
                }
            }
            savePushed()
        }
        for chunk in toDelete.chunked(400) {
            let ids = chunk.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
            let (_, results) = try await database.modifyRecords(
                saving: [], deleting: ids, savePolicy: .allKeys, atomically: false)
            for (id, r) in results {
                // Already gone counts as deleted.
                switch r {
                case .success: pushed[id.recordName] = nil; deleted += 1
                case .failure(let e as CKError) where e.code == .unknownItem: pushed[id.recordName] = nil
                case .failure: break
                }
            }
            savePushed()
        }
        logger.info("push: saved \(saved), deleted \(deleted), failed \(failures.count)")
        if let first = failures.first { throw Failure.records(failures.count, first) }
        return (saved, deleted)
    }

    // MARK: Requests from the iPhone

    /// New "book this" / "never mind" requests since the last look, read from the
    /// zone's change feed (no queries, so no indexes to set up). The feed also
    /// carries this Mac's own writes; only requests are kept.
    func inbox() async throws -> (requests: [Cloud.Request], away: [Cloud.AwayRequest]) {
        let status = try await CKContainer(identifier: Self.containerId).accountStatus()
        guard status == .available else { throw Failure.account(status) }
        var token = (try? Data(contentsOf: Self.inboxURL)).flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        var found: [Cloud.Request] = []
        var away: [Cloud.AwayRequest] = []
        var more = true
        do {
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (_, result) in changes.modificationResultsByID {
                    guard case .success(let m) = result else { continue }
                    if let q = Cloud.Request(m.record) { found.append(q) }
                    if let q = Cloud.AwayRequest(m.record) { away.append(q) }
                }
                token = changes.changeToken
                more = changes.moreComing
            }
        } catch let e as CKError where e.code == .changeTokenExpired {
            try? FileManager.default.removeItem(at: Self.inboxURL)
            return try await inbox()
        } catch let e as CKError where e.code == .zoneNotFound {
            return ([], [])   // nothing pushed yet, so nothing can have been asked for
        }
        if let t = token, let d = try? NSKeyedArchiver.archivedData(withRootObject: t, requiringSecureCoding: true) {
            try? d.write(to: Self.inboxURL, options: .atomic)
        }
        return (found, away)
    }

    /// Requests are one-shot: once acted on they're removed, which also tells
    /// the iPhone the Mac has them.
    func delete(requests names: [String]) async {
        guard !names.isEmpty else { return }
        let ids = names.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        _ = try? await database.modifyRecords(saving: [], deleting: ids, savePolicy: .allKeys, atomically: false)
    }

    private static var inboxURL: URL { Store.dir.appendingPathComponent("cloud-inbox-token") }

    /// Forget what was pushed, so the next push resends everything (e.g. after
    /// records were wiped in the CloudKit console).
    func resetPushState() {
        pushed = [:]
        zoneReady = false
        savePushed()
    }

    // MARK: Records

    struct Built {
        let name: String
        let hash: String
        let record: CKRecord
    }

    /// The records for a snapshot, with stable names and content hashes. Pure, so
    /// the tests can check them against the phone's decoders.
    nonisolated func build(_ s: Snapshot) -> [Built] {
        var out: [Built] = []
        func add(_ type: String, _ name: String, _ fields: [String: CKRecordValue?]) {
            // Schedule names are the plain branch id, which the phone also builds.
            let recordName = type == "Schedule" ? Cloud.schedulePrefix + name : "\(type).\(Self.safe(name))"
            let rec = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
            var digest = type
            for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
                // Leave empty lists out: iCloud can't infer a new field's type from one.
                let v = (v as? NSArray)?.count == 0 ? nil : v
                rec[k] = v
                digest += "|\(k)=\(v.map { "\($0)" } ?? "nil")"
            }
            out.append(Built(name: recordName, hash: Self.sha(digest), record: rec))
        }

        for c in s.classes {
            add("Class", c.key, [
                "key": c.key as NSString, "name": c.name as NSString, "weekday": c.weekday as NSString,
                "start": c.start as NSString, "locationIds": c.locationIds.map { NSNumber(value: $0) } as NSArray,
            ])
        }
        for p in s.awayRanges {
            add("AwayRange", p.id, [
                "start": p.start as NSString, "end": p.end as NSString,
                "except": (p.except ?? []) as NSArray, "note": p.note as NSString?,
            ])
        }
        for w in s.swaps {
            add("Swap", w.id, [
                "date": w.date as NSString, "skip": w.skip as NSString?, "bookName": w.bookName as NSString?,
                "bookStart": w.bookStart as NSString?,
                "bookLocationIds": (w.bookLocationIds ?? []).map { NSNumber(value: $0) } as NSArray,
                "note": w.note as NSString?,
            ])
        }
        let cutoff = Date().addingTimeInterval(-logDays)
        for e in s.log where e.openAt >= cutoff {
            var f: [String: CKRecordValue?] = [:]
            f["classKey"] = e.classKey as NSString
            f["className"] = e.className as NSString
            f["occurrenceId"] = NSNumber(value: e.occurrenceId)
            f["occursAt"] = e.occursAt as NSDate
            f["openAt"] = e.openAt as NSDate
            f["away"] = NSNumber(value: e.away)
            f["live"] = NSNumber(value: e.booking != nil)
            f["booked"] = NSNumber(value: e.booking?.booked ?? e.atOpen?.isJoined ?? false)
            f["verdict"] = e.verdict as NSString
            f["sendLagMs"] = e.sendLag.map { NSNumber(value: Int(($0 * 1000).rounded())) }
            f["fillSeconds"] = e.fillSeconds.map { NSNumber(value: $0) }
            f["capacity"] = e.capacity.map { NSNumber(value: $0) }
            // The full entry (every sample and attempt) for a detail view.
            f["detail"] = Self.json(e).map { $0 as NSString }
            // The phone's alert collapses on this, so one booking is one banner
            // even when iCloud delivers the push twice.
            f["alertId"] = e.id.uuidString as NSString
            add("Opening", e.id.uuidString, f)
        }
        for st in s.stats {
            var f: [String: CKRecordValue?] = [:]
            f["name"] = st.name as NSString
            f["weekday"] = st.weekday as NSString
            f["start"] = st.start as NSString
            f["branchId"] = NSNumber(value: st.branchId)
            f["weeks"] = NSNumber(value: st.weeks)
            f["filledWeeks"] = NSNumber(value: st.filledWeeks)
            f["medianFill"] = st.medianFill.map { NSNumber(value: $0) }
            f["fastestFill"] = st.fastestFill.map { NSNumber(value: $0) }
            f["filledWithinMinute"] = NSNumber(value: st.filledWithinMinute)
            f["medianWaitlist"] = st.medianWaitlist.map { NSNumber(value: $0) }
            let curve = Dictionary(uniqueKeysWithValues: st.signupsBy.map { ("\($0.key)", $0.value) })
            f["signupsBy"] = Self.json(curve).map { $0 as NSString }
            f["curveWeeks"] = NSNumber(value: st.curveWeeks)
            add("SlotStat", st.id, f)
        }
        for b in s.bookings ?? [] {
            add("Booking", "\(b.occurrenceId)", [
                "occurrenceId": NSNumber(value: b.occurrenceId), "name": b.name as NSString,
                "occursAt": b.occursAt as NSDate, "minutes": NSNumber(value: b.minutes),
                "branchId": NSNumber(value: b.branchId),
                "room": b.room.isEmpty ? nil : b.room as NSString,
                "trainer": b.trainer.isEmpty ? nil : b.trainer as NSString,
            ])
        }
        for p in s.picks {
            add("OneOff", "\(p.occurrenceId)", Cloud.fields(p))
        }
        for p in s.skips {
            add("Skip", "\(p.occurrenceId)", Cloud.fields(p))
        }
        if let items = s.schedule {
            for (branch, part) in Dictionary(grouping: items, by: \.branchId) {
                add("Schedule", "\(branch)", ["items": Cloud.encodeSchedule(part) as NSString])
            }
        }
        let m = s.status
        add("MacStatus", "current", [
            "updatedAt": m.updatedAt as NSDate, "status": m.status as NSString,
            "signedInAs": m.signedInAs as NSString?, "liveClasses": NSNumber(value: m.liveClasses),
            "nextOpening": m.nextOpening as NSDate?, "nextOpeningClasses": m.nextOpeningClasses as NSArray,
            "lastSynced": m.lastSynced as NSDate?, "syncError": m.syncError as NSString?,
        ])
        return out
    }

    // MARK: Helpers

    /// Record names allow only a limited character set; keep them readable and
    /// make them unique with a short hash of the original.
    private static func safe(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let readable = String(s.map { allowed.contains($0) ? $0 : "_" }.prefix(80))
        return "\(readable)-\(sha(s).prefix(10))"
    }

    private static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func json<T: Encodable>(_ v: T) -> String? {
        let e = JSONEncoder()
        // Milliseconds matter: the detail view shows send/reply times vs the opening.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        e.dateEncodingStrategy = .custom { d, enc in
            var c = enc.singleValueContainer()
            try c.encode(f.string(from: d))
        }
        e.outputFormatting = .sortedKeys
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static var stateURL: URL { Store.dir.appendingPathComponent("cloud-state.json") }

    private static func loadPushed() -> [String: String] {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    private func savePushed() {
        if let d = try? JSONEncoder().encode(pushed) { try? d.write(to: Self.stateURL, options: .atomic) }
    }
}

private extension Array {
    func chunked(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}
#endif
