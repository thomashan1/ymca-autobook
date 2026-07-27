import Foundation

/// Reads `full.json` from the private repo — classes that filled up before the
/// bot could book them, recorded by src/full_log.py.
///
/// Without this, "not booked" and "not bookable" look identical in the Week
/// view, which is the wrong thing to leave ambiguous: one resolves itself when
/// the booking window opens, the other never will and needs you to pick
/// something else.
///
/// The file doesn't exist until something first fills up — a 404 means "nothing
/// is full", which is the common case, so it's treated as empty rather than an
/// error.
@MainActor
final class FullRepository: ObservableObject {
    struct FullClass: Decodable, Hashable {
        let class_key: String?
        let name: String
        let date: String        // yyyy-MM-dd
        let start: String       // HH:mm
        let location: String?
        let first_seen: String?
    }
    private struct Payload: Decodable { let updated_at: String?; let full: [String: FullClass] }

    @Published var updatedAt: String?
    @Published var loaded = false

    private let client: GitHubClient
    /// "yyyy-MM-dd|HH:mm|name" → entry
    private var byKey: [String: FullClass] = [:]

    init(client: GitHubClient = GitHubClient()) { self.client = client }

    private static func key(date: String, start: String, name: String) -> String {
        "\(date)|\(start)|\(name)"
    }

    func load() async {
        if SampleMode.active { byKey = [:]; loaded = true; return }
        do {
            let (text, _) = try await client.readFile(repo: Config.privateRepo, path: "full.json")
            let payload = try JSONDecoder().decode(Payload.self, from: Data(text.utf8))
            byKey = Dictionary(uniqueKeysWithValues: payload.full.values.map {
                (Self.key(date: $0.date, start: $0.start, name: $0.name), $0)
            })
            updatedAt = payload.updated_at
            loaded = true
        } catch {
            // Absent file is the normal state, not a failure worth surfacing.
            byKey = [:]
            loaded = true
        }
    }

    func isFull(name: String, on date: Date, start: String) -> Bool {
        byKey[Self.key(date: BookingsRepository.iso.string(from: date),
                       start: start, name: name)] != nil
    }
}
