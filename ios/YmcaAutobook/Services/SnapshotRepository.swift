import Foundation

/// Reads `schedule_snapshot.json` from the private repo to enrich each class
/// with its real end time / duration (classes.yml only carries the start).
/// Same source the standard-schedule email uses; falls back gracefully when a
/// class isn't found.
@MainActor
final class SnapshotRepository: ObservableObject {
    struct Row: Decodable {
        let day: String
        let start: String
        let end: String
        let name: String
    }
    private struct Snapshot: Decodable { let classes: [Row] }

    @Published var error: String?

    private let client: GitHubClient
    private var index: [String: Row] = [:]

    init(client: GitHubClient = GitHubClient()) { self.client = client }

    func load() async {
        if SampleMode.active {
            index = [:]
            for (k, end) in SampleData.ends {
                let parts = k.split(separator: "|")
                guard parts.count == 3 else { continue }
                index[k] = Row(day: String(parts[1]), start: String(parts[2]), end: end, name: String(parts[0]))
            }
            error = nil
            return
        }
        do {
            let (text, _) = try await client.readFile(repo: Config.privateRepo,
                                                      path: "schedule_snapshot.json")
            let snap = try JSONDecoder().decode(Snapshot.self, from: Data(text.utf8))
            index = Dictionary(snap.classes.map { (Self.key($0.name, $0.day, $0.start), $0) },
                               uniquingKeysWith: { _, last in last })
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    private static func key(_ name: String, _ day: String, _ start: String) -> String {
        "\(name)|\(day)|\(start)"
    }

    /// End time ("HH:mm") for a class, if known.
    func endTime(for c: GymClass) -> String? {
        index[Self.key(c.name, c.weekday.rawValue, c.start)]?.end
    }

    /// Duration in minutes, if the end time is known.
    func minutes(for c: GymClass) -> Int? {
        guard let end = endTime(for: c),
              let start = Self.mins(c.start), let e = Self.mins(end) else { return nil }
        let d = e - start
        return d > 0 ? d : nil
    }

    private static func mins(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return p[0] * 60 + p[1]
    }
}
