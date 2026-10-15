#if os(iOS)
import CloudKit
import Foundation
import UIKit
import UserNotifications

/// Where the app reads its data from.
///
/// `.icloud` (the default) reads what the YMCA Booker Mac app publishes to the
/// user's own iCloud — no GitHub account or token needed — and is read-only
/// here: the Mac is the booker and the only writer. `.github` is the advanced
/// setup: classes.yml, pauses.yml and the snapshots in the two repos, with
/// GitHub Actions doing the booking.
enum DataSource: String {
    case github, icloud

    private static let key = "dataSource"

    static var current: DataSource {
        get { resolve(UserDefaults.standard.string(forKey: key)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    static var isCloud: Bool { current == .icloud && !SampleMode.active }

    /// iCloud unless GitHub was explicitly chosen (Settings → Advanced).
    static func resolve(_ raw: String?) -> DataSource { raw.flatMap(DataSource.init(rawValue:)) ?? .icloud }
}

/// Everything the Mac app publishes to iCloud, mapped onto the app's own models
/// so the repositories can serve it in place of the GitHub files.
///
/// Uses the zone's change feed: each refresh asks only for what changed since
/// the last one (no CloudKit queries, so no indexes to configure). The records
/// and the change token are cached on disk, so the app opens instantly and works
/// offline with the last copy. Record shapes are defined by the Mac app's
/// macOS/Engine/CloudStore.swift, decoded by Shared/CloudRecords.swift.
@MainActor
final class CloudSource: ObservableObject {
    typealias Opening = Cloud.Opening
    typealias MacStatus = Cloud.MacStatus

    static let containerId = Cloud.containerId
    static let shared = CloudSource()

    @Published private(set) var mac: MacStatus?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var error: String?
    /// Bumped whenever the cached records change, so views that read the
    /// schedule and picks redraw.
    @Published private(set) var version = 0

    private var cache = Cache()
    private var inflight: Task<Void, Never>?
    private var subscribed = false

    private let zoneID = Cloud.zoneID
    private var container: CKContainer { CKContainer(identifier: Self.containerId) }
    private var database: CKDatabase { container.privateCloudDatabase }

    init() {
        if let d = try? Data(contentsOf: Self.cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: d) {
            cache = c
            mac = c.mac
            lastRefresh = c.lastRefresh
        }
    }

    // MARK: Fetch

    /// Every repository's load() calls this, one after another; the first does
    /// the fetch and the rest reuse it.
    func ensureFresh() async {
        if error == nil, let t = lastRefresh, Date().timeIntervalSince(t) < 15 { return }
        await refresh()
    }

    func refresh() async {
        if let inflight { await inflight.value; return }
        let t = Task { await fetch() }
        inflight = t
        await t.value
        inflight = nil
    }

    private func fetch() async {
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                error = status == .noAccount ? "Sign in to iCloud in Settings to see your bookings."
                                             : "iCloud isn't available right now."
                return
            }
            try await fetchChanges()
            error = nil
            if !subscribed { await ensureAlerts() }
        } catch let e as CKError where e.code == .changeTokenExpired {
            cache = Cache()   // start over with a full fetch
            await fetch()
        } catch let e as CKError where e.code == .zoneNotFound {
            error = "Nothing from your Mac yet — open YMCA Booker on the Mac, signed in to the same iCloud account."
        } catch let e as CKError where e.code == .badContainer || e.code == .notAuthenticated
                    || "\(e)".contains("Invalid bundle ID") {
            // New installs: Apple's servers take a few minutes to learn the app may use the container.
            error = "iCloud is still setting up for this app — pull to refresh in a few minutes."
        } catch let e as CKError where e.code == .networkUnavailable || e.code == .networkFailure {
            error = "Offline — showing the last copy."
        } catch {
            self.error = "Couldn't reach iCloud: \(error.localizedDescription)"
        }
    }

    private func fetchChanges() async throws {
        var token = cache.token.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (_, result) in changes.modificationResultsByID {
                if case .success(let m) = result { apply(m.record) }
            }
            for d in changes.deletions { remove(d.recordID.recordName) }
            token = changes.changeToken
            more = changes.moreComing
        }
        cache.token = token.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        cache.lastRefresh = Date()
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: Self.cacheURL, options: .atomic) }
        mac = cache.mac
        lastRefresh = cache.lastRefresh
        version += 1
    }

    private func apply(_ r: CKRecord) {
        let name = r.recordID.recordName
        switch r.recordType {
        case "Class": cache.classes[name] = Cloud.Class(r)
        case "Pause": cache.pauses[name] = Cloud.Pause(r)
        case "Swap": cache.swaps[name] = Cloud.Swap(r)
        case "Opening": cache.openings[name] = Opening(r)
        case "SlotStat": cache.stats[name] = Cloud.Slot(r)
        case "Booking": cache.bookings[name] = Cloud.Booking(r)
        case "MacStatus": cache.mac = MacStatus(r) ?? cache.mac
        case "Schedule": cache.schedule = Cloud.schedule(r) ?? cache.schedule
        case "OneOff": cache.picks[name] = Cloud.pick(r)
        case "Skip": cache.skips[name] = Cloud.pick(r)
        case Cloud.Request.recordType: cache.requests[name] = Cloud.Request(r)
        default: break
        }
    }

    private func remove(_ name: String) {
        cache.classes[name] = nil; cache.pauses[name] = nil; cache.swaps[name] = nil
        cache.openings[name] = nil; cache.stats[name] = nil; cache.bookings[name] = nil
        cache.picks[name] = nil; cache.skips[name] = nil; cache.requests[name] = nil
        if name == Cloud.scheduleRecordName { cache.schedule = nil }
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("icloud-cache.json")
    }

    // MARK: As the app's models

    var classes: [GymClass] {
        cache.classes.values.compactMap { c in
            Weekday(rawValue: c.weekday).map {
                GymClass(key: c.key, name: c.name, weekday: $0, start: c.start, locationIds: c.locationIds, firstLive: nil)
            }
        }
        .sorted { ($0.weekday, $0.start) < ($1.weekday, $1.start) }
    }

    var pauses: [Pause] {
        cache.pauses.values.compactMap { p in
            guard let s = Self.day.date(from: p.start), let e = Self.day.date(from: p.end) else { return nil }
            return Pause(start: s, end: e, except: p.except, note: p.note)
        }
        .sorted { $0.start < $1.start }
    }

    var swaps: [Swap] {
        cache.swaps.values.compactMap { w in
            guard let d = Self.day.date(from: w.date) else { return nil }
            return Swap(date: d, skipKey: w.skip, bookName: w.bookName, bookStart: w.bookStart,
                        bookLocationIDs: w.bookLocationIds, note: w.note)
        }
        .sorted { $0.date < $1.date }
    }

    var fillSlots: [FillStatsRepository.Slot] {
        cache.stats.values.map { s in
            FillStatsRepository.Slot(
                key: FillStatsRepository.key(name: s.name, weekday: s.weekday, start: s.start, branchId: s.branchId),
                name: s.name, weekday: s.weekday, start: s.start, branch_id: s.branchId,
                branch: Branch(rawValue: s.branchId)?.name ?? "Branch \(s.branchId)",
                capacity: 0, weeks: s.weeks, filled: s.filledWeeks,
                median_fill_s: s.medianFill, fastest_fill_s: s.fastestFill,
                within_60s: s.filledWithinMinute, median_waitlist: s.medianWaitlist ?? 0)
        }
    }

    /// What the YMCA has us booked into, as of the Mac's last plan (every few
    /// hours, and right after each opening) — whichever trigger made the booking.
    var bookings: [BookingsRepository.Booking] {
        let today = Self.day.string(from: Date())
        if !cache.bookings.isEmpty {
            return cache.bookings.values.compactMap { b in
                let date = Self.day.string(from: b.occursAt)
                guard date >= today else { return nil }
                return BookingsRepository.Booking(
                    date: date, start: Self.time.string(from: b.occursAt),
                    end: Self.time.string(from: b.occursAt.addingTimeInterval(Double(b.minutes) * 60)),
                    name: b.name, location_id: b.branchId, room: b.room, instructor: b.trainer)
            }
        }
        // Older Mac builds publish no Booking records: fall back to what each
        // opening saw, which misses bookings made after it and cancellations.
        let branchOf = Dictionary(cache.classes.values.map { ($0.key, $0.locationIds.first) }, uniquingKeysWith: { a, _ in a })
        return cache.openings.values.compactMap { o in
            let date = Self.day.string(from: o.occursAt)
            guard o.booked, date >= today else { return nil }
            return BookingsRepository.Booking(date: date, start: Self.time.string(from: o.occursAt), end: nil,
                                              name: o.className, location_id: branchOf[o.classKey] ?? nil,
                                              room: nil, instructor: nil)
        }
    }

    /// Classes that filled before we got a seat — the "not bookable" case.
    var full: [FullRepository.FullClass] {
        cache.openings.values.compactMap { o in
            guard !o.booked, !o.paused, o.fillSeconds != nil else { return nil }
            return FullRepository.FullClass(class_key: o.classKey, name: o.className,
                                            date: Self.day.string(from: o.occursAt),
                                            start: Self.time.string(from: o.occursAt),
                                            location: nil, first_seen: nil)
        }
    }

    /// Booking windows the Mac handled, newest first.
    var openings: [Opening] { cache.openings.values.sorted { $0.openAt > $1.openAt } }

    private static let day: DateFormatter = formatter("yyyy-MM-dd")
    private static let time: DateFormatter = formatter("HH:mm")
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Config.timeZone
        f.dateFormat = format
        return f
    }

    // MARK: Booking and cancelling, via the Mac

    /// Every upcoming session the Mac last saw at both branches (nil before
    /// a Mac that publishes it has run).
    var schedule: [ScheduleItem]? {
        if SampleMode.active { return SampleData.schedule }
        return cache.schedule.map { $0.filter { $0.occursAt > Date() } }
    }

    /// Requests sent from here (or another device) that the Mac hasn't picked up yet.
    var pending: [Cloud.Request] { cache.requests.values.sorted { $0.requestedAt < $1.requestedAt } }

    /// Where a session stands, counting requests still on their way to the Mac.
    func state(of i: ScheduleItem) -> SessionState {
        if SampleMode.active { return SessionState(i, picked: SampleData.pickedIds.contains(i.id), skipped: false) }
        let last = cache.requests.values.filter { $0.pick.id == i.id }.max { $0.requestedAt < $1.requestedAt }
        let picked = cache.picks.values.contains { $0.id == i.id }
        let skipped = cache.skips.values.contains { $0.id == i.id }
        switch last?.action {
        case .book?: return SessionState(i, picked: true, skipped: false)
        case .withdraw?: return SessionState(i, picked: false, skipped: skipped)
        case .skip?: return SessionState(i, picked: false, skipped: true)
        case .unskip?: return SessionState(i, picked: picked, skipped: false)
        case .cancel?: return i.joined ? .booking : SessionState(i, picked: picked, skipped: skipped)
        case nil: return SessionState(i, picked: picked, skipped: skipped)
        }
    }

    /// Ask the Mac to do something to one session. It acts within about half a
    /// minute; the change comes back through the usual records.
    func send(_ action: Cloud.Request.Action, _ pick: ClassPick) async throws {
        if SampleMode.active { return }
        let q = Cloud.Request(action: action, pick: pick)
        _ = try await database.save(q.record())
        cache.requests[q.id] = q
        version += 1
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: Self.cacheURL, options: .atomic) }
        // Pick up the Mac's response without waiting for a pull to refresh.
        Task {
            for delay in [20, 40, 60, 90] {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                await refresh()
                if cache.requests[q.id] == nil { break }
            }
        }
    }

    // MARK: Alerts

    private static let alertsID = "ymca-booker-opening-alerts"

    /// A visible notification for every booking result the Mac records. The
    /// title and body are filled in on the device from the record's className
    /// and verdict, via Localizable.strings.
    func ensureAlerts() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { subscribed = true; return }
        UIApplication.shared.registerForRemoteNotifications()

        let sub = CKQuerySubscription(recordType: "Opening", predicate: NSPredicate(value: true),
                                      subscriptionID: Self.alertsID, options: [.firesOnRecordCreation])
        sub.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = "OPENING_TITLE"
        info.titleLocalizationArgs = ["className"]
        info.alertLocalizationKey = "OPENING_BODY"
        info.alertLocalizationArgs = ["verdict"]
        info.soundName = "default"
        sub.notificationInfo = info
        do {
            _ = try await database.modifySubscriptions(saving: [sub], deleting: [])
            subscribed = true
        } catch {
            // Not worth a banner over the data; it's retried on the next refresh.
        }
    }

    /// Back on GitHub, the Mac's alerts no longer belong to this app.
    func removeAlerts() async {
        _ = try? await database.modifySubscriptions(saving: [], deleting: [Self.alertsID])
        subscribed = false
    }

    // MARK: Records (as the Mac writes them)

    private struct Cache: Codable {
        var classes: [String: Cloud.Class] = [:]
        var pauses: [String: Cloud.Pause] = [:]
        var swaps: [String: Cloud.Swap] = [:]
        var openings: [String: Cloud.Opening] = [:]
        var stats: [String: Cloud.Slot] = [:]
        var bookings: [String: Cloud.Booking] = [:]
        var mac: Cloud.MacStatus?
        var schedule: [ScheduleItem]?
        var picks: [String: ClassPick] = [:]
        var skips: [String: ClassPick] = [:]
        var requests: [String: Cloud.Request] = [:]
        var token: Data?
        var lastRefresh: Date?
    }

}

private func < (l: (Weekday, String), r: (Weekday, String)) -> Bool {
    l.0 == r.0 ? l.1 < r.1 : l.0 < r.0
}
#endif
