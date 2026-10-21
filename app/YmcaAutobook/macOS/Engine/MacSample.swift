#if os(macOS)
import AppKit
import SwiftUI

/// Made-up classes for the README's Mac screenshots: launched with
/// `-sampleData YES` the app signs in to nothing, books nothing, writes nothing
/// to disk or iCloud and shows these instead. With `-screenshotDir <folder>` it
/// also saves a PNG of each tab of its window there and quits.
enum MacSample {
    static var active: Bool { UserDefaults.standard.bool(forKey: "sampleData") }

    static let lineup: [RecurringClass] = [
        .init(key: "pilates-mon", name: "Pilates", weekday: "Mon", start: "09:00", locationIds: [1392]),
        .init(key: "trx-mon", name: "TRX", weekday: "Mon", start: "10:10", locationIds: [1388]),
        .init(key: "bodybalance-tue", name: "BODYBALANCE", weekday: "Tue", start: "10:15", locationIds: [1392]),
        .init(key: "pilates-wed", name: "Pilates", weekday: "Wed", start: "09:00", locationIds: [1392]),
        .init(key: "upbeat-barre-wed", name: "Upbeat Barre", weekday: "Wed", start: "09:50", locationIds: [1392]),
        .init(key: "trx-thu", name: "TRX", weekday: "Thu", start: "10:10", locationIds: [1388]),
        .init(key: "boot-camp-fri", name: "Boot Camp", weekday: "Fri", start: "09:00", locationIds: [1392]),
    ]

    /// Other classes on the schedule, to add from.
    private static let others: [(weekday: String, start: String, name: String, branch: Int, minutes: Int, room: String, trainer: String)] = [
        ("Mon", "08:30", "Zumba", 1388, 45, "Group Exercise Room", "Lena V."),
        ("Tue", "09:00", "BODYPUMP", 1392, 60, "Group Exercise Room", "Jordan A."),
        ("Wed", "10:30", "Gentle Yoga", 1392, 60, "Studio 2", "Priya M."),
        ("Thu", "11:15", "Cycle Sculpt", 1392, 50, "Cycle Studio", "Sam R."),
        ("Fri", "08:45", "BODYCOMBAT", 1388, 60, "Group Exercise Room", "Sam R."),
    ]

    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = ClubTime.zone
        return c
    }

    private static let lead: TimeInterval = 167 * 3600

    /// Two weeks of sessions from today: the lineup's are booked once their
    /// window has opened, one is skipped, one is queued to book just once.
    static func schedule(now: Date = Date()) -> [ScheduleItem] {
        let cal = cal
        let today = cal.startOfDay(for: now)
        var out: [ScheduleItem] = []
        var id = 800_000
        let mine = lineup.map { ($0.weekday, $0.start, $0.name, $0.locationIds[0], 45, "Studio 1", "Ana C.", true) }
        let rest = others.map { ($0.weekday, $0.start, $0.name, $0.branch, $0.minutes, $0.room, $0.trainer, false) }
        for offset in -7..<15 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let wd = ClubTime.weekday(day)
            for c in mine + rest where c.0 == wd {
                let hm = c.1.split(separator: ":").compactMap { Int($0) }
                guard let at = cal.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: day), at > now else { continue }
                id += 1
                out.append(ScheduleItem(id: id, name: c.2, occursAt: at, openAt: at.addingTimeInterval(-lead),
                                        minutes: c.4, branchId: c.3, room: c.5, trainer: c.6, capacity: 30,
                                        full: false, joined: c.7 && at.addingTimeInterval(-lead) <= now, autoBook: c.7))
            }
        }
        return out.sorted { $0.occursAt < $1.occursAt }
    }

    /// Next week's Cycle Sculpt, queued to book once.
    static func picks(_ schedule: [ScheduleItem], now: Date = Date()) -> [ClassPick] {
        schedule.filter { $0.name == "Cycle Sculpt" && $0.openAt > now }.prefix(1).map(\.pick)
    }

    /// Next week's BODYBALANCE, skipped.
    static func skips(_ schedule: [ScheduleItem], now: Date = Date()) -> [ClassPick] {
        schedule.filter { $0.name == "BODYBALANCE" && $0.autoBook && $0.openAt > now }.prefix(1).map(\.pick)
    }

    /// Six past weeks per class, so each has a fill speed.
    static func history(now: Date = Date()) -> [FillRecord] {
        let fill: [String: Double] = ["Pilates": 40, "TRX": 95, "BODYBALANCE": 7200, "Upbeat Barre": 26,
                                      "Boot Camp": 44, "BODYPUMP": 30, "Cycle Sculpt": 300]
        var out: [FillRecord] = []
        var id = 700_000
        for c in lineup.map({ ($0.name, $0.weekday, $0.start, $0.locationIds[0]) })
                + others.map({ ($0.name, $0.weekday, $0.start, $0.branch) }) {
            for w in 1...6 {
                id += 1
                let at = now.addingTimeInterval(-Double(w) * 7 * 86400)
                let open = at.addingTimeInterval(-lead)
                let s = fill[c.0].map { $0 * (0.8 + 0.08 * Double(w)) }
                out.append(FillRecord(id: id, name: c.0, weekday: c.1, start: c.2, branchId: c.3, occursAt: at, openAt: open,
                                      capacity: 30, fullGroupAt: s.map { open.addingTimeInterval($0) }, waitlist: s == nil ? 0 : 3,
                                      lastSeen: at))
            }
        }
        return out
    }

    /// Recent results for the menu.
    static func log(now: Date = Date()) -> [ShadowEntry] {
        [("Pilates", "pilates-mon", 2), ("TRX", "trx-mon", 2), ("BODYBALANCE", "bodybalance-tue", 1)].map { name, key, daysAgo in
            let open = now.addingTimeInterval(-Double(daysAgo) * 86400)
            var e = ShadowEntry(classKey: key, className: name, occurrenceId: 1, occursAt: open.addingTimeInterval(lead),
                                openAt: open, away: false)
            var b = ShadowEntry.BookingLog()
            b.attempts = [.init(sentAt: open.addingTimeInterval(0.004), repliedAt: open.addingTimeInterval(0.9), result: "joined")]
            b.outcome = "Booked by your Mac"
            b.booked = true
            e.booking = b
            return e
        }
    }

    /// Save each tab of the app's window as a PNG, then quit. Renders the
    /// window's own views, so it needs no screen-recording permission.
    @MainActor static func captureAndQuit(to dir: String) async {
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true || $0.title == "YMCA Booker" }) else {
            NSApp.terminate(nil); return
        }
        window.setContentSize(NSSize(width: 1180, height: 720))
        window.center()
        for tab in [MacTab.schedule, MacTab.classes, MacTab.settings] {
            UserDefaults.standard.set(tab, forKey: MacTab.key)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("mac-\(tab).png"))
        }
        NSApp.terminate(nil)
    }
}
#endif
