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
        GymClass(key: "core-mon", name: "Les Mills CORE", weekday: .mon, start: "09:45", locationIds: [1392], firstLive: nil),
        GymClass(key: "vinyasa-yoga-mon", name: "Vinyasa Yoga", weekday: .mon, start: "10:15", locationIds: [1392], firstLive: nil),
        GymClass(key: "lift-hiit-mon", name: "Lift & H.I.I.T.", weekday: .mon, start: "11:20", locationIds: [1392], firstLive: nil),
        GymClass(key: "bodypump-tue", name: "BODYPUMP", weekday: .tue, start: "09:00", locationIds: [1392], firstLive: nil),
        GymClass(key: "cycle-tue", name: "Cycle", weekday: .tue, start: "10:15", locationIds: [1392], firstLive: nil),
        GymClass(key: "rpm-wed", name: "RPM", weekday: .wed, start: "09:30", locationIds: [1388], firstLive: nil),
        GymClass(key: "core-wed", name: "Les Mills CORE", weekday: .wed, start: "10:30", locationIds: [1388], firstLive: nil),
        GymClass(key: "bodypump-thu", name: "BODYPUMP", weekday: .thu, start: "09:00", locationIds: [1392], firstLive: nil),
        GymClass(key: "cycle-sculpt-thu", name: "Cycle Sculpt", weekday: .thu, start: "10:15", locationIds: [1392], firstLive: nil),
        GymClass(key: "core-fri", name: "Les Mills CORE", weekday: .fri, start: "09:45", locationIds: [1388], firstLive: nil),
        GymClass(key: "lift-hiit-fri", name: "Lift & H.I.I.T.", weekday: .fri, start: "11:20", locationIds: [1392], firstLive: nil),
    ]

    /// name|weekday|start  ->  end time, for durations.
    static let ends: [String: String] = [
        "Les Mills CORE|Mon|09:45": "10:15",
        "Vinyasa Yoga|Mon|10:15": "11:15", "Lift & H.I.I.T.|Mon|11:20": "12:00",
        "BODYPUMP|Tue|09:00": "10:00", "Cycle|Tue|10:15": "11:15",
        "RPM|Wed|09:30": "10:20", "Les Mills CORE|Wed|10:30": "11:00",
        "BODYPUMP|Thu|09:00": "10:00", "Cycle Sculpt|Thu|10:15": "11:15",
        "Les Mills CORE|Fri|09:45": "10:15", "Lift & H.I.I.T.|Fri|11:20": "12:00",
    ]

    /// Booked classes, fictional instructors/rooms. Keyed [weekdayOffset from
    /// currentMonday, 0=this Mon .. 11=next Fri] -> (start,end,name,locId,room,instructor).
    /// Both weeks are fully booked so the Week screenshot shows two clean, all-green
    /// weeks — booking opens ~7 days ahead, so by the time this week's Friday rolls
    /// around, next week's classes have genuinely all been through their own booking
    /// window already, same as this data models.
    private static let mon: [(String, String, String, Int, String, String)] = [
        ("09:45", "10:15", "Les Mills CORE", 1392, "Southwest – Rec Room", "Jordan A."),
        ("10:15", "11:15", "Vinyasa Yoga", 1392, "Southwest – Studio 2", "Priya M."),
        ("11:20", "12:00", "Lift & H.I.I.T.", 1392, "Southwest – Group Exercise Room", "Marcus D."),
    ]
    private static let tue: [(String, String, String, Int, String, String)] = [
        ("09:00", "10:00", "BODYPUMP", 1392, "Southwest – Group Exercise Room", "Gini B."),
        ("10:15", "11:15", "Cycle", 1392, "Southwest – Rec Room", "Dana K."),
    ]
    private static let wed: [(String, String, String, Int, String, String)] = [
        ("09:30", "10:20", "RPM", 1388, "Northwest – Group Exercise Room", "Sam R."),
        ("10:30", "11:00", "Les Mills CORE", 1388, "Northwest – Family Pavilion", "Jordan A."),
    ]
    private static let thu: [(String, String, String, Int, String, String)] = [
        ("09:00", "10:00", "BODYPUMP", 1392, "Southwest – Group Exercise Room", "Sophia B."),
        ("10:15", "11:15", "Cycle Sculpt", 1392, "Southwest – Group Exercise Room", "Nina T."),
    ]
    private static let fri: [(String, String, String, Int, String, String)] = [
        ("09:45", "10:15", "Les Mills CORE", 1388, "Northwest – Family Pavilion", "Eyal B."),
        ("11:20", "12:00", "Lift & H.I.I.T.", 1392, "Southwest – Group Exercise Room", "Marcus D."),
    ]
    static let weekBookings: [Int: [(String, String, String, Int, String, String)]] = [
        0: mon, 1: tue, 2: wed, 3: thu, 4: fri,
        7: mon, 8: tue, 9: wed, 10: thu, 11: fri,
    ]

    /// Offsets pushed past the visible two-week grid so the Week screenshot's
    /// two weeks stay clean and fully booked; the Away tab still has something
    /// upcoming to show.
    static let awayNotes: [(offsetFromThisMon: Int, days: Int, note: String, except: [String])] = [
        (14, 3, "Away Mon–Wed", []),
        (17, 1, "Half day — keep morning class", ["cycle-sculpt-thu"]),
    ]

    /// One-off swaps, dated relative to this week's Monday so screenshots always
    /// show them as upcoming.
    static var swaps: [Swap] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Config.timeZone; cal.firstWeekday = 2
        let mon = CalendarHelper.currentMonday
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: mon) ?? mon }
        return [
            Swap(date: day(8), skipKey: "cycle-tue", bookName: "BODYCOMBAT",
                 bookStart: "09:50", bookLocationIDs: [1388],
                 note: "Northwest BODYCOMBAT instead of Cycle"),
            Swap(date: day(15), skipKey: "cycle-tue", note: "dentist"),
        ]
    }
}
