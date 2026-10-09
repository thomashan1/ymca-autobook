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

    private static let sample: [Slot] = [
        .init(key: "bodypump|Tue|09:00|1392", name: "BODYPUMP", weekday: "Tue", start: "09:00", branch_id: 1392,
              branch: "Southwest", capacity: 41, weeks: 5, filled: 5, median_fill_s: 37, fastest_fill_s: 34,
              within_60s: 4, median_waitlist: 5),
        .init(key: "vinyasa yoga|Mon|10:15|1392", name: "Vinyasa Yoga", weekday: "Mon", start: "10:15", branch_id: 1392,
              branch: "Southwest", capacity: 30, weeks: 5, filled: 5, median_fill_s: 81000, fastest_fill_s: 15100,
              within_60s: 0, median_waitlist: 2),
        .init(key: "rpm|Wed|09:30|1388", name: "RPM", weekday: "Wed", start: "09:30", branch_id: 1388,
              branch: "Northwest", capacity: 29, weeks: 5, filled: 0, median_fill_s: nil, fastest_fill_s: nil,
              within_60s: 0, median_waitlist: 0),
    ]
}
