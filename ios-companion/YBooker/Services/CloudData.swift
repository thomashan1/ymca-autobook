import CloudKit
import Foundation

/// Everything the Mac publishes, read from the user's iCloud.
///
/// Uses the zone's change feed: each refresh asks only for what changed since
/// the last one (no CloudKit queries, so no indexes to configure). The decoded
/// records and the change token are cached on disk, so the app opens instantly
/// and works offline with the last copy.
@MainActor
final class CloudData: ObservableObject {
    static let containerId = "iCloud.com.thomashan.ybooker"
    static let shared = CloudData()

    @Published private(set) var classes: [GymClass] = []
    @Published private(set) var pauses: [Pause] = []
    @Published private(set) var swaps: [Swap] = []
    @Published private(set) var openings: [Opening] = []
    @Published private(set) var stats: [SlotStat] = []
    @Published private(set) var mac: MacStatus?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published var error: String?

    private let zoneID = CKRecordZone.ID(zoneName: "YBooker", ownerName: CKCurrentUserDefaultName)
    private var database: CKDatabase { CKContainer(identifier: Self.containerId).privateCloudDatabase }

    // Records by name, so changes and deletions apply in place.
    private var cache = Cache()

    private struct Cache: Codable {
        var classes: [String: GymClass] = [:]
        var pauses: [String: Pause] = [:]
        var swaps: [String: Swap] = [:]
        var openings: [String: Opening] = [:]
        var stats: [String: SlotStat] = [:]
        var mac: MacStatus?
        var token: Data?
        var lastRefresh: Date?
    }

    init() {
        if let d = try? Data(contentsOf: Self.cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: d) {
            cache = c
            publish()
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let status = try await CKContainer(identifier: Self.containerId).accountStatus()
            guard status == .available else {
                error = status == .noAccount ? "Sign in to iCloud in Settings to see your bookings." : "iCloud isn't available right now."
                return
            }
            try await fetchChanges()
            error = nil
        } catch let e as CKError where e.code == .changeTokenExpired {
            cache = Cache()          // start over with a full fetch
            await refresh()
        } catch let e as CKError where e.code == .zoneNotFound {
            error = "Nothing from your Mac yet — open Y Booker on the Mac and sign in to iCloud there."
        } catch let e as CKError where e.code == .badContainer || e.code == .notAuthenticated
                    || (e.code == .partialFailure && "\(e)".contains("bundle ID")) || "\(e)".contains("Invalid bundle ID") {
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
        save()
        publish()
    }

    private func apply(_ r: CKRecord) {
        let name = r.recordID.recordName
        switch r.recordType {
        case "Class": cache.classes[name] = GymClass(r)
        case "Pause": cache.pauses[name] = Pause(r)
        case "Swap": cache.swaps[name] = Swap(r)
        case "Opening": cache.openings[name] = Opening(r)
        case "SlotStat": cache.stats[name] = SlotStat(r)
        case "MacStatus": cache.mac = MacStatus(r) ?? cache.mac
        default: break
        }
    }

    private func remove(_ name: String) {
        cache.classes[name] = nil; cache.pauses[name] = nil; cache.swaps[name] = nil
        cache.openings[name] = nil; cache.stats[name] = nil
    }

    private func publish() {
        classes = cache.classes.values.sorted {
            (Day.order.firstIndex(of: $0.weekday) ?? 9, $0.start) < (Day.order.firstIndex(of: $1.weekday) ?? 9, $1.start)
        }
        pauses = cache.pauses.values.sorted { $0.start < $1.start }
        swaps = cache.swaps.values.sorted { $0.date < $1.date }
        openings = cache.openings.values.sorted { $0.openAt > $1.openAt }
        stats = Array(cache.stats.values)
        mac = cache.mac
        lastRefresh = cache.lastRefresh
    }

    private func save() {
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: Self.cacheURL, options: .atomic) }
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("cloud-cache.json")
    }

    // MARK: Lookups for the views

    func stat(for c: GymClass) -> SlotStat? { stats.first { $0.id == c.slotKey } }

    func isAway(_ c: GymClass, on day: String) -> Pause? { pauses.first { $0.covers(day, key: c.key) } }

    func swap(_ c: GymClass, on day: String) -> Swap? { swaps.first { $0.date == day && $0.skip == c.key } }

    /// The Mac's record of the booking window for this class on this day, if it has opened.
    func opening(_ c: GymClass, on day: String) -> Opening? {
        openings.first { $0.classKey == c.key && Day.string($0.occursAt) == day }
    }

    // MARK: Notifications

    /// Two subscriptions on the private database: a silent one so the app can
    /// refresh in the background, and a visible alert for every new booking
    /// result the Mac records.
    func ensureSubscriptions() async {
        let silent = CKDatabaseSubscription(subscriptionID: "changes")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        silent.notificationInfo = info

        let alerts = CKQuerySubscription(recordType: "Opening", predicate: NSPredicate(value: true),
                                         subscriptionID: "opening-alerts", options: [.firesOnRecordCreation])
        alerts.zoneID = zoneID
        let a = CKSubscription.NotificationInfo()
        a.titleLocalizationKey = "OPENING_TITLE"
        a.titleLocalizationArgs = ["className"]
        a.alertLocalizationKey = "OPENING_BODY"
        a.alertLocalizationArgs = ["verdict"]
        a.soundName = "default"
        a.shouldSendContentAvailable = true
        alerts.notificationInfo = a

        do {
            _ = try await database.modifySubscriptions(saving: [silent, alerts], deleting: [])
        } catch {
            self.error = "Couldn't set up notifications: \(error.localizedDescription)"
        }
    }
}
