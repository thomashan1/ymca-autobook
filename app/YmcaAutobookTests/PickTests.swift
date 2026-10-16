import CloudKit
import XCTest
@testable import YMCA_Booker

/// Booking and cancelling single sessions: the queue rules, the state each
/// session shows on both platforms, and the records the iPhone and Mac swap.
final class PickTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func pick(_ id: Int, opensIn: TimeInterval, startsIn: TimeInterval = 8 * 86400) -> ClassPick {
        ClassPick(occurrenceId: id, name: "BODYCOMBAT", occursAt: now.addingTimeInterval(startsIn),
                  openAt: now.addingTimeInterval(opensIn), branchId: 1388, room: "Studio 2", trainer: "Sam")
    }

    private func item(_ id: Int = 1, opensIn: TimeInterval, startsIn: TimeInterval = 8 * 86400,
                      full: Bool = false, joined: Bool = false, autoBook: Bool = false) -> ScheduleItem {
        ScheduleItem(id: id, name: "RPM", occursAt: now.addingTimeInterval(startsIn), openAt: now.addingTimeInterval(opensIn),
                     minutes: 50, branchId: 1388, room: "Cycle", trainer: "Ana", capacity: 30,
                     full: full, joined: joined, autoBook: autoBook)
    }

    // MARK: Triage

    func testTriageSortsPicksByWhatTheScheduleSays() {
        let picks = [pick(1, opensIn: 3600), pick(2, opensIn: -60), pick(3, opensIn: -60), pick(4, opensIn: 3600),
                     pick(5, opensIn: -86400, startsIn: -60), pick(6, opensIn: 3600)]
        let seen: [Int: (joined: Bool, openAt: Date)] = [
            1: (false, now.addingTimeInterval(3600)),
            2: (false, now.addingTimeInterval(-60)),
            3: (true, now.addingTimeInterval(-60)),
            4: (false, now.addingTimeInterval(3600)),
            // 6 isn't on the schedule (cancelled or out of range): kept, not acted on
        ]
        let r = PickTriage.run(picks, seen: seen, lineup: [4], now: now)
        XCTAssertEqual(r.atOpening, [1])
        XCTAssertEqual(r.now, [2])
        XCTAssertEqual(r.drop, [3, 4, 5])   // booked already, the lineup has it, over
    }

    func testRequestsApplyInOrder() {
        let a = pick(1, opensIn: 3600), b = pick(2, opensIn: 7200)
        let reqs = [
            Cloud.Request(action: .withdraw, pick: a, requestedAt: now.addingTimeInterval(2)),
            Cloud.Request(action: .book, pick: a, requestedAt: now.addingTimeInterval(1)),
            Cloud.Request(action: .book, pick: b, requestedAt: now.addingTimeInterval(3)),
            Cloud.Request(action: .skip, pick: pick(9, opensIn: 60), requestedAt: now.addingTimeInterval(4)),
            Cloud.Request(action: .cancel, pick: pick(7, opensIn: -60), requestedAt: now.addingTimeInterval(5)),
        ]
        let (p, k) = PickTriage.apply(reqs, picks: [], skips: [pick(8, opensIn: 60)])
        XCTAssertEqual(p.map(\.id), [2])      // booked then withdrawn; cancel doesn't touch the queue
        XCTAssertEqual(Set(k.map(\.id)), [8, 9])

        let (p2, k2) = PickTriage.apply([Cloud.Request(action: .unskip, pick: pick(8, opensIn: 60)),
                                         Cloud.Request(action: .book, pick: pick(9, opensIn: 60))], picks: p, skips: k)
        XCTAssertEqual(Set(p2.map(\.id)), [2, 9])
        XCTAssertEqual(k2.map(\.id), [])      // booking a skipped session un-skips it
    }

    // MARK: State and actions

    func testStatesAndTheirActions() {
        func s(_ i: ScheduleItem, picked: Bool = false, skipped: Bool = false) -> SessionState {
            SessionState(i, picked: picked, skipped: skipped, now: now)
        }
        XCTAssertEqual(s(item(opensIn: -60, joined: true)), .booked)
        XCTAssertEqual(s(item(opensIn: -60, joined: true)).action, .cancel)
        XCTAssertEqual(s(item(opensIn: 60), picked: true), .queued)
        XCTAssertEqual(s(item(opensIn: 60), picked: true).action, .withdraw)
        XCTAssertEqual(s(item(opensIn: -60), picked: true), .booking)
        XCTAssertNil(s(item(opensIn: -60), picked: true).action)
        XCTAssertEqual(s(item(opensIn: 60, autoBook: true)), .lineup)
        XCTAssertEqual(s(item(opensIn: 60, autoBook: true)).action, .skip)
        XCTAssertEqual(s(item(opensIn: 60, autoBook: true), skipped: true), .skipped)
        XCTAssertEqual(s(item(opensIn: 60, autoBook: true), skipped: true).action, .unskip)
        XCTAssertEqual(s(item(opensIn: 60)), .future)
        XCTAssertEqual(s(item(opensIn: 60)).action, .book)
        XCTAssertEqual(s(item(opensIn: -60)), .open)
        XCTAssertEqual(s(item(opensIn: -60)).action, .book)
        XCTAssertEqual(s(item(opensIn: -60, full: true)), .full)
        XCTAssertNil(s(item(opensIn: -60, full: true)).action)
        XCTAssertEqual(s(item(opensIn: -86400, startsIn: -60)), .started)
    }

    // MARK: Records

    func testRequestRecordRoundTrip() throws {
        let q = Cloud.Request(action: .skip, pick: pick(308671, opensIn: 3600), requestedAt: now)
        let r = q.record()
        XCTAssertEqual(r.recordType, "BookRequest")
        XCTAssertEqual(r.recordID.zoneID, Cloud.zoneID)
        let back = try XCTUnwrap(Cloud.Request(r))
        XCTAssertEqual(back, q)
        XCTAssertNil(Cloud.Request(CKRecord(recordType: "OneOff")))   // only requests decode as requests
    }

    func testScheduleRoundTrip() throws {
        let items = [item(1, opensIn: 60, autoBook: true), item(2, opensIn: -60, full: true, joined: true)]
        let r = CKRecord(recordType: "Schedule")
        r["items"] = Cloud.encodeSchedule(items) as NSString
        XCTAssertEqual(Cloud.schedule(r), items)
        XCTAssertNil(Cloud.schedule(CKRecord(recordType: "Schedule")))
    }

    /// The Book screen's "Hide pool" and From / Before time filters.
    func testPoolAndTimeFilters() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func item(_ name: String, room: String = "Studio 1", _ h: Int, _ m: Int = 0) -> ScheduleItem {
            let at = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: h, minute: m))!
            return ScheduleItem(id: h * 60 + m, name: name, occursAt: at, openAt: at.addingTimeInterval(-167 * 3600),
                                minutes: 45, branchId: 1392, room: room, trainer: "", capacity: 30,
                                full: false, joined: false, autoBook: false)
        }
        func keeps(_ i: ScheduleItem, pool: Bool = false, from: Int = -1, until: Int = -1) -> Bool {
            ClassFilter.matches(i, hidePool: pool, from: from, until: until, calendar: cal)
        }
        for pool in ["Indoor Lap/Rec Swim", "Aqua Zumba", "WaterInMotion Platinum", "Pool in Use - Aqua Class"] {
            XCTAssertFalse(keeps(item(pool, 9), pool: true), pool)
            XCTAssertTrue(keeps(item(pool, 9)), pool)
        }
        XCTAssertFalse(keeps(item("Shallow fun", room: "Pool", 9), pool: true))
        XCTAssertTrue(keeps(item("BODYPUMP", 9), pool: true))

        // From 8:30, before noon.
        XCTAssertFalse(keeps(item("RPM", 8, 15), from: 510, until: 720))
        XCTAssertTrue(keeps(item("RPM", 8, 30), from: 510, until: 720))
        XCTAssertTrue(keeps(item("RPM", 11, 20), from: 510, until: 720))
        XCTAssertFalse(keeps(item("RPM", 12), from: 510, until: 720))
        XCTAssertTrue(keeps(item("RPM", 18), from: 510))
        XCTAssertEqual(ClassFilter.timeLabel(510), "8:30 AM")
        XCTAssertEqual(ClassFilter.timeLabel(720), "12 PM")
    }
}
