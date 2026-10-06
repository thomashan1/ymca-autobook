import Foundation

/// One record per wake-up — the measurement for #138 Spike 3. Stored as JSON in
/// Application Support with protection that allows writes while locked.
struct WakeEntry: Codable, Identifiable {
    enum Kind: String, Codable { case silentPush, notificationTap, manual }

    var id = UUID()
    let kind: Kind
    let appState: String
    let sentAt: Date?          // from the push payload, when present
    let receivedAt: Date
    var finishedAt: Date?
    var sessionPath: FisikalClient.SessionPath?
    var occurrences: Int?
    var booked: Int?
    var error: String?

    var latency: TimeInterval? { sentAt.map { receivedAt.timeIntervalSince($0) } }
    var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(receivedAt) } }
}

actor WakeLog {
    static let shared = WakeLog()
    static let changed = Notification.Name("WakeLogChanged")

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wake-log.json")
    }()

    func all() -> [WakeEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([WakeEntry].self, from: data)) ?? []
    }

    func append(_ entry: WakeEntry) {
        var entries = all()
        entries.insert(entry, at: 0)
        save(Array(entries.prefix(500)))
    }

    func clear() { save([]) }

    private func save(_ entries: [WakeEntry]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(entries) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        Task { @MainActor in NotificationCenter.default.post(name: WakeLog.changed, object: nil) }
    }
}

/// What every wake-up does in slice 1: make sure we have a session, do one
/// read-only list call (stand-in for booking), and record how it went.
enum WakeRunner {
    static func run(kind: WakeEntry.Kind, payload: [AnyHashable: Any], appState: String) async {
        var entry = WakeEntry(kind: kind, appState: appState,
                              sentAt: (payload["sent"] as? Double).map(Date.init(timeIntervalSince1970:)),
                              receivedAt: Date())
        do {
            // Background wakes respect the quiet window; a tap means the user is present.
            let r = try await FisikalClient.shared.occurrencesEnsuringSession(
                allowReloginInQuietWindow: kind != .silentPush)
            entry.sessionPath = r.path
            entry.occurrences = r.occurrences.count
            entry.booked = r.occurrences.filter(\.isJoined).count
        } catch {
            entry.error = error.localizedDescription
        }
        entry.finishedAt = Date()
        await WakeLog.shared.append(entry)
    }
}
