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
    /// A made-up lineup (not the owner's: theirs is private), built from slots
    /// FillStatsRepository's sample has stats for.
    static let classes: [GymClass] = [
        GymClass(key: "pilates-mon", name: "Pilates", weekday: .mon, start: "09:00", locationIds: [1392], firstLive: nil),
        GymClass(key: "trx-mon", name: "TRX", weekday: .mon, start: "10:10", locationIds: [1388], firstLive: nil),
        GymClass(key: "bodybalance-tue", name: "BODYBALANCE", weekday: .tue, start: "10:15", locationIds: [1392], firstLive: nil),
        GymClass(key: "pilates-wed", name: "Pilates", weekday: .wed, start: "09:00", locationIds: [1392], firstLive: nil),
        GymClass(key: "barre-wed", name: "Upbeat Barre", weekday: .wed, start: "09:50", locationIds: [1392], firstLive: nil),
        GymClass(key: "trx-thu", name: "TRX", weekday: .thu, start: "10:10", locationIds: [1388], firstLive: nil),
        GymClass(key: "bodybalance-thu", name: "BODYBALANCE", weekday: .thu, start: "10:15", locationIds: [1392], firstLive: nil),
        GymClass(key: "boot-camp-fri", name: "Boot Camp", weekday: .fri, start: "09:00", locationIds: [1392], firstLive: nil),
        GymClass(key: "barre-fri", name: "Upbeat Barre", weekday: .fri, start: "09:20", locationIds: [1388], firstLive: nil),
    ]

    /// name|weekday|start  ->  end time, for durations.
    static let ends: [String: String] = [
        "Pilates|Mon|09:00": "09:45", "TRX|Mon|10:10": "10:55",
        "BODYBALANCE|Tue|10:15": "11:15",
        "Pilates|Wed|09:00": "09:45", "Upbeat Barre|Wed|09:50": "10:45",
        "TRX|Thu|10:10": "10:55", "BODYBALANCE|Thu|10:15": "11:15",
        "Boot Camp|Fri|09:00": "10:00", "Upbeat Barre|Fri|09:20": "10:15",
    ]

    /// Booked classes, fictional instructors/rooms. Keyed [weekdayOffset from
    /// currentMonday, 0=this Mon .. 11=next Fri] -> (start,end,name,locId,room,instructor).
    /// Both weeks are fully booked so the Week screenshot shows two clean, all-green
    /// weeks — booking opens ~7 days ahead, so by the time this week's Friday rolls
    /// around, next week's classes have genuinely all been through their own booking
    /// window already, same as this data models.
    private static let mon: [(String, String, String, Int, String, String)] = [
        ("09:00", "09:45", "Pilates", 1392, "Southwest – Studio 1", "Ana C."),
        ("10:10", "10:55", "TRX", 1388, "Northwest – Rec Room", "Chris L."),
    ]
    private static let tue: [(String, String, String, Int, String, String)] = [
        ("10:15", "11:15", "BODYBALANCE", 1392, "Southwest – Studio 2", "Priya M."),
    ]
    private static let wed: [(String, String, String, Int, String, String)] = [
        ("09:00", "09:45", "Pilates", 1392, "Southwest – Studio 1", "Ana C."),
        ("09:50", "10:45", "Upbeat Barre", 1392, "Southwest – Studio 2", "Dana K."),
    ]
    private static let thu: [(String, String, String, Int, String, String)] = [
        ("10:10", "10:55", "TRX", 1388, "Northwest – Rec Room", "Chris L."),
        ("10:15", "11:15", "BODYBALANCE", 1392, "Southwest – Studio 2", "Priya M."),
    ]
    private static let fri: [(String, String, String, Int, String, String)] = [
        ("09:00", "10:00", "Boot Camp", 1392, "Southwest – Group Exercise Room", "Theo W."),
        ("09:20", "10:15", "Upbeat Barre", 1388, "Northwest – Studio 1", "Dana K."),
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
        (17, 1, "Half day — keep morning class", ["trx-thu"]),
    ]

    /// One-off swaps, dated relative to this week's Monday so screenshots always
    /// show them as upcoming.
    static var swaps: [Swap] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Config.timeZone; cal.firstWeekday = 2
        let mon = CalendarHelper.currentMonday
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: mon) ?? mon }
        return [
            Swap(date: day(8), skipKey: "bodybalance-tue", bookName: "BODYCOMBAT",
                 bookStart: "09:50", bookLocationIDs: [1388],
                 note: "Northwest BODYCOMBAT instead of BODYBALANCE"),
            Swap(date: day(15), skipKey: "bodybalance-tue", note: "dentist"),
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
            (2, "09:00", 45, "Pilates", 1392, "Studio 1", "Ana C.", true, false),
            (2, "10:10", 45, "TRX", 1388, "Rec Room", "Chris L.", true, false),
            (2, "11:30", 45, "Aqua Fit", 1388, "Pool", "Lena V.", false, false),
            (2, "12:15", 45, "$ Strength Development", 1392, "Weight Room", "Theo W.", false, false),
            (3, "09:00", 60, "BODYPUMP", 1392, "Group Exercise Room", "Jordan A.", false, true),
            (3, "09:50", 60, "BODYCOMBAT", 1388, "Group Exercise Room", "Sam R.", false, true),
            (3, "10:15", 60, "BODYBALANCE", 1392, "Studio 2", "Priya M.", true, false),
            (3, "17:30", 45, "Lap Swim", 1392, "Pool", "", false, false),
            (4, "09:00", 45, "Pilates", 1392, "Studio 1", "Ana C.", true, false),
            (4, "09:50", 55, "Upbeat Barre", 1392, "Studio 2", "Dana K.", true, false),
            (4, "10:30", 60, "Gentle Yoga", 1392, "Studio 2", "Priya M.", false, false),
            (4, "18:00", 60, "Cycle", 1388, "Cycle Studio", "Sam R.", false, false),
            (5, "09:00", 60, "BODYPUMP", 1392, "Group Exercise Room", "Jordan A.", false, true),
            (5, "10:10", 45, "TRX", 1388, "Rec Room", "Chris L.", true, false),
            (5, "10:15", 60, "BODYBALANCE", 1392, "Studio 2", "Priya M.", true, false),
            (5, "11:30", 60, "Vinyasa Yoga", 1388, "Studio 1", "Nina T.", false, false),
            (6, "08:45", 60, "BODYCOMBAT", 1388, "Group Exercise Room", "Sam R.", false, true),
            (6, "09:00", 60, "Boot Camp", 1392, "Group Exercise Room", "Theo W.", true, false),
            (6, "09:20", 55, "Upbeat Barre", 1388, "Studio 1", "Dana K.", true, false),
            (6, "12:00", 45, "Aqua Fit", 1392, "Pool", "Lena V.", false, false),
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
