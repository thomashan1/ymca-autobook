import Foundation

/// Reads `bookings.json` from the private repo — the list of classes actually
/// booked (is_joined) for the next ~2 weeks, published by
/// scripts/snapshot_bookings.py. This is the real "what I booked" source; the
/// Week view uses it to distinguish booked classes from merely scheduled ones.
///
/// Until the bookings workflow has run at least once the file won't exist yet;
/// that's handled gracefully (no bookings → everything shows as scheduled).
@MainActor
final class BookingsRepository: ObservableObject {
    struct Booking: Decodable { let date: String; let start: String; let name: String }
    private struct Snapshot: Decodable { let updated_at: String?; let bookings: [Booking] }

    @Published var updatedAt: String?
    @Published var loaded = false
    @Published var error: String?

    private let client: GitHubClient
    private var booked: Set<String> = []

    init(client: GitHubClient = GitHubClient()) { self.client = client }

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Config.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func key(name: String, date: String, start: String) -> String {
        "\(name)|\(date)|\(start)"
    }

    func load() async {
        do {
            let (text, _) = try await client.readFile(repo: Config.privateRepo, path: "bookings.json")
            let snap = try JSONDecoder().decode(Snapshot.self, from: Data(text.utf8))
            booked = Set(snap.bookings.map { Self.key(name: $0.name, date: $0.date, start: $0.start) })
            updatedAt = snap.updated_at
            loaded = true
            error = nil
        } catch let err {
            // Missing file (workflow hasn't run) or read failure — treat as "no data".
            booked = []
            loaded = false
            self.error = String(describing: err)
        }
    }

    /// True when the given class occurrence is actually booked.
    func isBooked(name: String, on date: Date, start: String) -> Bool {
        booked.contains(Self.key(name: name, date: Self.iso.string(from: date), start: start))
    }
}
