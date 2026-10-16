#if os(iOS)
import Foundation

/// Reads `fill_stats.json` from the private repo — how fast each weekly class
/// slot fills once its booking window opens, published daily by
/// scripts/update_fill_history.py from Fisikal's own `full_group_at` stamps.
/// Absent until that script's first run, which reads as "no stats yet".
@MainActor
final class FillStatsRepository: ObservableObject {
    struct Slot: Decodable, Identifiable, Hashable {
        let key: String
        let name: String
        let weekday: String
        let start: String
        let branch_id: Int
        let branch: String
        let capacity: Int
        let weeks: Int
        let filled: Int
        let median_fill_s: Double?
        let fastest_fill_s: Double?
        let within_60s: Int
        let median_waitlist: Int
        var id: String { key }

        var fillsFast: Bool { (median_fill_s ?? .infinity) <= 300 }
    }
    private struct Payload: Decodable { let updated_at: String; let weeks: Int; let slots: [Slot] }

    @Published private(set) var slots: [Slot] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var windowWeeks = 12
    @Published var error: String?

    private let client: GitHubClient
    private var byKey: [String: Slot] = [:]

    init(client: GitHubClient = GitHubClient()) { self.client = client }

    static func key(name: String, weekday: String, start: String, branchId: Int) -> String {
        "\(name.lowercased())|\(weekday)|\(start)|\(branchId)"
    }

    func load() async {
        if SampleMode.active { apply(Self.sample, updated: Date()); return }
        if DataSource.isCloud {
            await CloudSource.shared.ensureFresh()
            let s = CloudSource.shared.fillSlots
            windowWeeks = s.map(\.weeks).max() ?? windowWeeks
            apply(s, updated: CloudSource.shared.lastRefresh)
            return
        }
        do {
            let (text, _) = try await client.readFile(repo: Config.privateRepo, path: "fill_stats.json")
            let p = try JSONDecoder().decode(Payload.self, from: Data(text.utf8))
            windowWeeks = p.weeks
            apply(p.slots, updated: ISO8601DateFormatter().date(from: p.updated_at))
            error = nil
        } catch {
            // Absent until the first daily run — not worth an error banner.
            self.error = String(describing: error).contains("404") ? nil : String(describing: error)
        }
    }

    private func apply(_ s: [Slot], updated: Date?) {
        slots = s
        byKey = Dictionary(s.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        updatedAt = updated
    }

    func stats(for c: GymClass) -> Slot? {
        byKey[Self.key(name: c.name, weekday: c.weekday.rawValue, start: c.start,
                       branchId: c.locationIds.first ?? 1392)]
    }

    /// "37s", "4 min", "2 h", "3 d"
    static func duration(_ seconds: Double?) -> String {
        guard let s = seconds else { return "—" }
        if s < 120 { return "\(Int(s.rounded()))s" }
        if s < 7200 { return "\(Int(s / 60)) min" }
        if s < 2 * 86400 { return "\(Int((s / 3600).rounded())) h" }
        return "\(Int((s / 86400).rounded())) d"
    }

    /// Simulator sample: real stats (10/10) for the made-up sample lineup and a
    /// few other classes, plus every class that fills within five minutes.
    private static let sample: [Slot] = [
        .init(key: "aqua fitness|Mon|09:00|1392", name: "Aqua Fitness", weekday: "Mon", start: "09:00", branch_id: 1392,
              branch: "Southwest", capacity: 50, weeks: 4, filled: 4, median_fill_s: 135.5, fastest_fill_s: 78,
              within_60s: 0, median_waitlist: 4),
        .init(key: "pilates|Mon|09:00|1392", name: "Pilates", weekday: "Mon", start: "09:00", branch_id: 1392,
              branch: "Southwest", capacity: 28, weeks: 5, filled: 5, median_fill_s: 149, fastest_fill_s: 52,
              within_60s: 1, median_waitlist: 5),
        .init(key: "trx|Mon|10:10|1388", name: "TRX", weekday: "Mon", start: "10:10", branch_id: 1388,
              branch: "Northwest", capacity: 16, weeks: 5, filled: 5, median_fill_s: 159, fastest_fill_s: 5,
              within_60s: 2, median_waitlist: 3),
        .init(key: "aqua fitness|Tue|09:00|1392", name: "Aqua Fitness", weekday: "Tue", start: "09:00", branch_id: 1392,
              branch: "Southwest", capacity: 50, weeks: 5, filled: 5, median_fill_s: 224, fastest_fill_s: 87,
              within_60s: 0, median_waitlist: 3),
        .init(key: "bodypump|Tue|09:00|1392", name: "BODYPUMP", weekday: "Tue", start: "09:00", branch_id: 1392,
              branch: "Southwest", capacity: 41, weeks: 5, filled: 5, median_fill_s: 37, fastest_fill_s: 34,
              within_60s: 4, median_waitlist: 3),
        .init(key: "bodybalance|Tue|10:15|1392", name: "BODYBALANCE", weekday: "Tue", start: "10:15", branch_id: 1392,
              branch: "Southwest", capacity: 28, weeks: 5, filled: 5, median_fill_s: 15, fastest_fill_s: 13,
              within_60s: 5, median_waitlist: 1),
        .init(key: "pilates|Wed|09:00|1392", name: "Pilates", weekday: "Wed", start: "09:00", branch_id: 1392,
              branch: "Southwest", capacity: 28, weeks: 5, filled: 5, median_fill_s: 61, fastest_fill_s: 37,
              within_60s: 2, median_waitlist: 5),
        .init(key: "upbeat barre|Wed|09:50|1392", name: "UpBeat Barre", weekday: "Wed", start: "09:50", branch_id: 1392,
              branch: "Southwest", capacity: 40, weeks: 5, filled: 5, median_fill_s: 26, fastest_fill_s: 22,
              within_60s: 5, median_waitlist: 0),
        .init(key: "aqua fitness|Thu|09:00|1392", name: "Aqua Fitness", weekday: "Thu", start: "09:00", branch_id: 1392,
              branch: "Southwest", capacity: 50, weeks: 5, filled: 5, median_fill_s: 249, fastest_fill_s: 80,
              within_60s: 0, median_waitlist: 2),
        .init(key: "bodypump|Thu|09:00|1392", name: "BODYPUMP", weekday: "Thu", start: "09:00", branch_id: 1392,
              branch: "Southwest", capacity: 41, weeks: 5, filled: 5, median_fill_s: 38, fastest_fill_s: 31,
              within_60s: 5, median_waitlist: 0),
        .init(key: "pilates|Thu|09:00|1392", name: "Pilates", weekday: "Thu", start: "09:00", branch_id: 1392,
              branch: "Southwest", capacity: 28, weeks: 5, filled: 5, median_fill_s: 128, fastest_fill_s: 103,
              within_60s: 0, median_waitlist: 5),
        .init(key: "trx|Thu|10:10|1388", name: "TRX", weekday: "Thu", start: "10:10", branch_id: 1388,
              branch: "Northwest", capacity: 16, weeks: 5, filled: 5, median_fill_s: 15, fastest_fill_s: 10,
              within_60s: 4, median_waitlist: 4),
        .init(key: "bodybalance|Thu|10:15|1392", name: "BODYBALANCE", weekday: "Thu", start: "10:15", branch_id: 1392,
              branch: "Southwest", capacity: 28, weeks: 5, filled: 5, median_fill_s: 65, fastest_fill_s: 28,
              within_60s: 2, median_waitlist: 0),
        .init(key: "aqua fitness|Fri|09:00|1392", name: "Aqua Fitness", weekday: "Fri", start: "09:00", branch_id: 1392,
              branch: "Southwest", capacity: 50, weeks: 6, filled: 6, median_fill_s: 295, fastest_fill_s: 102,
              within_60s: 0, median_waitlist: 0),
        .init(key: "boot camp|Fri|09:00|1392", name: "Boot Camp", weekday: "Fri", start: "09:00", branch_id: 1392,
              branch: "Southwest", capacity: 35, weeks: 6, filled: 6, median_fill_s: 43.5, fastest_fill_s: 24,
              within_60s: 4, median_waitlist: 4),
        .init(key: "upbeat barre|Fri|09:20|1388", name: "UpBeat Barre", weekday: "Fri", start: "09:20", branch_id: 1388,
              branch: "Northwest", capacity: 25, weeks: 6, filled: 6, median_fill_s: 25, fastest_fill_s: 10,
              within_60s: 6, median_waitlist: 2),
        .init(key: "pilates|Sat|08:00|1388", name: "Pilates", weekday: "Sat", start: "08:00", branch_id: 1388,
              branch: "Northwest", capacity: 25, weeks: 3, filled: 3, median_fill_s: 27, fastest_fill_s: 15,
              within_60s: 3, median_waitlist: 5),
    ]
}
#endif
