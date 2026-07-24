import Foundation

/// Reads `bookings.json` from the private repo — the list of classes actually
/// booked (is_joined) for this + the next two weeks, published by
/// scripts/snapshot_bookings.py. This is the real "what I booked" source; the
/// Week view merges it with the recurring classes.yml schedule so real bookings
/// always appear (even one-offs not in classes.yml), with room + instructor.
///
/// Until the bookings workflow has run at least once the file won't exist yet;
/// handled gracefully (no bookings → everything shows as scheduled).
@MainActor
final class BookingsRepository: ObservableObject {
    struct Booking: Decodable, Hashable {
        let date: String        // yyyy-MM-dd
        let start: String       // HH:mm
        let end: String?
        let name: String
        let location_id: Int?
        let room: String?
        let instructor: String?

        var branch: Branch { Branch(rawValue: location_id ?? 1392) ?? .southwest }
    }
    private struct Snapshot: Decodable { let updated_at: String?; let bookings: [Booking] }

    @Published var updatedAt: String?
    @Published var loaded = false
    @Published var error: String?

    private let client: GitHubClient
    private var byDate: [String: [Booking]] = [:]

    init(client: GitHubClient = GitHubClient()) { self.client = client }

    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Config.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func load() async {
        if SampleMode.active {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = Config.timeZone; cal.firstWeekday = 2
            let mon = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
            var map: [String: [Booking]] = [:]
            for (offset, list) in SampleData.weekBookings {
                guard let d = cal.date(byAdding: .day, value: offset, to: mon) else { continue }
                let ds = Self.iso.string(from: d)
                map[ds] = list.map {
                    Booking(date: ds, start: $0.0, end: $0.1, name: $0.2,
                            location_id: $0.3, room: $0.4, instructor: $0.5)
                }
            }
            byDate = map; updatedAt = "sample"; loaded = true; error = nil
            return
        }
        do {
            let (text, _) = try await client.readFile(repo: Config.privateRepo, path: "bookings.json")
            let snap = try JSONDecoder().decode(Snapshot.self, from: Data(text.utf8))
            byDate = Dictionary(grouping: snap.bookings, by: { $0.date })
            updatedAt = snap.updated_at
            loaded = true
            error = nil
        } catch let err {
            byDate = [:]
            loaded = false
            self.error = String(describing: err)
        }
    }

    func bookings(on date: Date) -> [Booking] {
        byDate[Self.iso.string(from: date)] ?? []
    }

    func booking(name: String, on date: Date, start: String) -> Booking? {
        bookings(on: date).first { $0.name == name && $0.start == start }
    }

    func isBooked(name: String, on date: Date, start: String) -> Bool {
        booking(name: name, on: date, start: start) != nil
    }
}
