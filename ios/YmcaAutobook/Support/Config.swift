import Foundation

/// Static configuration for which repos/workflows the app talks to.
/// Swap `apiBase` + auth in `GitHubClient` for a Cloudflare Worker later
/// without touching feature code.
enum Config {
    static let apiBase = URL(string: "https://api.github.com")!

    static let owner = "thomashan1"
    static let publicRepo = "ymca-autobook"
    static let privateRepo = "ymca-private"

    /// Files the app reads/writes.
    static let classesPath = "classes.yml"
    static let pausesPath = "pauses.yml"

    /// Workflow dispatched for a one-off "Book now".
    static let bookWorkflow = "book.yml"

    /// Republishes bookings.json. It runs every 6h on its own, so the app is
    /// otherwise up to 6h stale after a booking — this lets it be asked directly.
    static let bookingsSnapshotWorkflow = "bookings-snapshot.yml"

    static let timeZone = TimeZone(identifier: "America/Los_Angeles")!

    /// Booking opens this many hours before a class starts
    /// (restrict_to_book_in_advance_time_in_hours from the Fisikal API).
    static let bookOpenLeadHours = 167
}
