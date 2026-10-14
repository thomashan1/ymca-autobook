#if os(iOS)
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

    /// The Book screen's directory: a plausible two weeks at both branches, from
    /// today. The lineup's sessions are booked once their window has opened.
    static var schedule: [ScheduleItem] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Config.timeZone
        let today = cal.startOfDay(for: Date())
        let now = Date()
        // weekday (1=Sun) | start | minutes | name | branch | room | instructor | lineup | popular
        let week: [(Int, String, Int, String, Int, String, String, Bool, Bool)] = [
            (2, "08:30", 45, "Zumba", 1388, "Group Exercise Room", "Lena V.", false, false),
            (2, "09:45", 30, "Les Mills CORE", 1392, "Rec Room", "Jordan A.", true, false),
            (2, "10:15", 60, "Vinyasa Yoga", 1392, "Studio 2", "Priya M.", true, true),
            (2, "11:20", 40, "Lift & H.I.I.T.", 1392, "Group Exercise Room", "Marcus D.", true, false),
            (2, "12:15", 45, "Pilates", 1388, "Studio 1", "Ana C.", false, false),
            (3, "09:00", 60, "BODYPUMP", 1392, "Group Exercise Room", "Gini B.", true, true),
            (3, "09:50", 60, "BODYCOMBAT", 1388, "Group Exercise Room", "Sam R.", false, true),
            (3, "10:15", 60, "Cycle", 1392, "Rec Room", "Dana K.", true, false),
            (3, "11:30", 45, "Aqua Fit", 1388, "Pool", "Lena V.", false, false),
            (4, "09:30", 50, "RPM", 1388, "Group Exercise Room", "Sam R.", true, true),
            (4, "10:30", 30, "Les Mills CORE", 1388, "Family Pavilion", "Jordan A.", true, false),
            (4, "10:30", 60, "Gentle Yoga", 1392, "Studio 2", "Priya M.", false, false),
            (4, "12:00", 45, "TRX for Beginners", 1392, "Rec Room", "Marcus D.", false, false),
            (5, "09:00", 60, "BODYPUMP", 1392, "Group Exercise Room", "Sophia B.", true, true),
            (5, "09:15", 45, "Barre", 1388, "Studio 1", "Ana C.", false, false),
            (5, "10:15", 60, "Cycle Sculpt", 1392, "Group Exercise Room", "Nina T.", true, true),
            (5, "11:30", 60, "Vinyasa Yoga", 1388, "Studio 1", "Priya M.", false, false),
            (6, "08:45", 60, "BODYCOMBAT", 1388, "Group Exercise Room", "Eyal B.", false, true),
            (6, "09:45", 30, "Les Mills CORE", 1388, "Family Pavilion", "Eyal B.", true, false),
            (6, "10:30", 45, "TRX for Beginners", 1392, "Rec Room", "Marcus D.", false, false),
            (6, "11:20", 40, "Lift & H.I.I.T.", 1392, "Group Exercise Room", "Marcus D.", true, false),
            (7, "09:00", 60, "Zumba", 1392, "Group Exercise Room", "Lena V.", false, false),
        ]
        var out: [ScheduleItem] = []
        var id = 900_000
        for offset in 0..<14 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let wd = cal.component(.weekday, from: day)
            for c in week where c.0 == wd {
                let hm = c.1.split(separator: ":").compactMap { Int($0) }
                guard let at = cal.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: day), at > now else { continue }
                let open = at.addingTimeInterval(-Double(Config.bookOpenLeadHours) * 3600)
                id += 1
                out.append(ScheduleItem(id: id, name: c.3, occursAt: at, openAt: open, minutes: c.2, branchId: c.4,
                                        room: c.5, trainer: c.6, capacity: c.8 ? 40 : 25,
                                        full: c.8 && open <= now && !c.7, joined: c.7 && open <= now,
                                        autoBook: c.7))
            }
        }
        return out
    }

    /// One queued pick so the screenshot shows that state: next week's Friday BODYCOMBAT.
    static var pickedIds: Set<Int> {
        Set(schedule.filter { $0.name == "BODYCOMBAT" && $0.openAt > Date() }.suffix(1).map(\.id))
    }
}
#endif
