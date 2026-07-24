import Foundation

/// Sample data for simulator screenshots / previews — no network, no real
/// personal info. Active only in the simulator when no token is stored, so real
/// device builds and signed-in simulator sessions are unaffected.
enum SampleMode {
    static var active: Bool {
        #if targetEnvironment(simulator)
        return KeychainStore.token() == nil
        #else
        return false
        #endif
    }
}

enum SampleData {
    static let classes: [GymClass] = [
        GymClass(key: "bodycombat-mon", name: "BODYCOMBAT", weekday: .mon, start: "08:45", locationIds: [1392], firstLive: nil),
        GymClass(key: "core-mon", name: "Les Mills CORE", weekday: .mon, start: "09:45", locationIds: [1392], firstLive: nil),
        GymClass(key: "vinyasa-yoga-mon", name: "Vinyasa Yoga", weekday: .mon, start: "10:15", locationIds: [1392], firstLive: nil),
        GymClass(key: "lift-hiit-mon", name: "Lift & H.I.I.T.", weekday: .mon, start: "11:20", locationIds: [1392], firstLive: nil),
        GymClass(key: "bodypump-tue", name: "BODYPUMP", weekday: .tue, start: "09:00", locationIds: [1392], firstLive: nil),
        GymClass(key: "cycle-tue", name: "Cycle", weekday: .tue, start: "10:15", locationIds: [1392], firstLive: nil),
        GymClass(key: "rpm-wed", name: "RPM", weekday: .wed, start: "09:30", locationIds: [1388], firstLive: nil),
        GymClass(key: "core-wed", name: "Les Mills CORE", weekday: .wed, start: "10:30", locationIds: [1388], firstLive: nil),
        GymClass(key: "bodypump-thu", name: "BODYPUMP", weekday: .thu, start: "09:00", locationIds: [1392], firstLive: nil),
        GymClass(key: "cycle-sculpt-thu", name: "Cycle Sculpt", weekday: .thu, start: "10:15", locationIds: [1392], firstLive: nil),
        GymClass(key: "trx-beginners-fri", name: "TRX for Beginners", weekday: .fri, start: "10:30", locationIds: [1392], firstLive: nil),
        GymClass(key: "lift-hiit-fri", name: "Lift & H.I.I.T.", weekday: .fri, start: "11:20", locationIds: [1392], firstLive: nil),
    ]

    /// name|weekday|start  ->  end time, for durations.
    static let ends: [String: String] = [
        "BODYCOMBAT|Mon|08:45": "09:45", "Les Mills CORE|Mon|09:45": "10:15",
        "Vinyasa Yoga|Mon|10:15": "11:15", "Lift & H.I.I.T.|Mon|11:20": "12:00",
        "BODYPUMP|Tue|09:00": "10:00", "Cycle|Tue|10:15": "11:15",
        "RPM|Wed|09:30": "10:20", "Les Mills CORE|Wed|10:30": "11:00",
        "BODYPUMP|Thu|09:00": "10:00", "Cycle Sculpt|Thu|10:15": "11:15",
        "TRX for Beginners|Fri|10:30": "11:15", "Lift & H.I.I.T.|Fri|11:20": "12:00",
    ]

    /// Booked classes for the current week (fictional instructors/rooms).
    /// Keyed [weekdayOffset 0=Mon] -> list of (start,end,name,locId,room,instructor).
    static let weekBookings: [Int: [(String, String, String, Int, String, String)]] = [
        0: [("09:45", "10:15", "Les Mills CORE", 1392, "Southwest – Rec Room", "Jordan A."),
            ("10:15", "11:15", "Vinyasa Yoga", 1392, "Southwest – Studio 2", "Priya M."),
            ("11:20", "12:00", "Lift & H.I.I.T.", 1392, "Southwest – Group Exercise Room", "Marcus D.")],
        1: [("10:15", "11:15", "Cycle", 1392, "Southwest – Rec Room", "Dana K.")],
        2: [("09:30", "10:20", "RPM", 1388, "Northwest – Group Exercise Room", "Sam R."),
            ("10:30", "11:00", "Les Mills CORE", 1388, "Northwest – Family Pavilion", "Jordan A.")],
        3: [("10:15", "11:15", "Cycle Sculpt", 1392, "Southwest – Group Exercise Room", "Nina T.")],
    ]

    static let awayNotes: [(offsetFromThisMon: Int, days: Int, note: String, except: [String])] = [
        (7, 3, "Away Mon–Wed", []),
        (10, 1, "Half day — keep morning class", ["cycle-sculpt-thu"]),
    ]
}
