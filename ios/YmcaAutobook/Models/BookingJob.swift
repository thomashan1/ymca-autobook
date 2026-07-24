import Foundation

/// A scheduled or completed booking attempt, surfaced on the Jobs screen.
struct BookingJob: Identifiable, Hashable {
    enum State: Hashable {
        case queued           // waiting for its open instant
        case booked           // succeeded
        case failed(String)   // with reason
    }

    var id: String { classKey + "-" + ISO8601DateFormatter().string(from: classDate) }

    var classKey: String
    var className: String
    var weekday: Weekday
    var classDate: Date       // the class occurrence being booked
    var opensAt: Date         // classDate - 167h
    var state: State
    var attempts: Int = 0

    /// Live countdown to the booking opening; nil once past.
    var countdown: TimeInterval? {
        let delta = opensAt.timeIntervalSinceNow
        return delta > 0 ? delta : nil
    }
}
