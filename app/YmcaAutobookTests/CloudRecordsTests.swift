#if os(macOS)
import CloudKit
import XCTest
@testable import YMCA_Booker

/// The contract between the two halves of the app: every record the Mac writes
/// (CloudStore.build) must decode on the iPhone (Cloud.* in CloudRecords.swift)
/// with the same values.
final class CloudRecordsTests: XCTestCase {
    private let occursAt = Date(timeIntervalSince1970: 1_792_512_000)   // a fixed instant

    private func snapshot(bookings: [CloudStore.Booking]? = nil) -> CloudStore.Snapshot {
        var entry = ShadowEntry(classKey: "bodypump-tue", className: "BODYPUMP", occurrenceId: 308671,
                                occursAt: occursAt, openAt: occursAt.addingTimeInterval(-167 * 3600), away: false)
        entry.fullGroupAt = entry.openAt.addingTimeInterval(42)
        entry.capacity = 41
        var log = ShadowEntry.BookingLog()
        log.attempts = [.init(sentAt: entry.openAt.addingTimeInterval(0.004),
                              repliedAt: entry.openAt.addingTimeInterval(1.059), result: "taken")]
        log.outcome = "already booked — another trigger got there first"
        log.booked = true
        entry.booking = log
        return CloudStore.Snapshot(
            classes: [RecurringClass(key: "bodypump-tue", name: "BODYPUMP", weekday: "Tue", start: "09:00", locationIds: [1392])],
            awayRanges: [AwayRange(start: "2026-11-23", end: "2026-11-27", except: nil, note: "Thanksgiving"),
                     AwayRange(start: "2026-10-23", end: "2026-10-23", except: ["lift-hiit-fri"])],
            swaps: [Swap(date: "2026-10-02", skip: "lift-hiit-fri", bookName: "BODYCOMBAT", bookStart: "09:50",
                         bookLocationIds: [1388], note: "try it"),
                    Swap(date: "2026-10-01", skip: "cycle-sculpt-thu")],
            log: [entry],
            stats: [SlotStats(id: "bodypump|Tue|09:00|1392", name: "BODYPUMP", weekday: "Tue", start: "09:00",
                              branchId: 1392, weeks: 6, filledWeeks: 6, medianFill: 37, fastestFill: 31,
                              filledWithinMinute: 5, medianWaitlist: 3, signupsBy: [10: 11, 30: 33], curveWeeks: 1)],
            bookings: bookings,
            status: .init(updatedAt: occursAt, status: "Planned 11 upcoming openings", signedInAs: "member@example.com",
                          liveClasses: 11, nextOpening: occursAt, nextOpeningClasses: ["BODYPUMP"],
                          lastSynced: nil, syncError: nil))
    }

    private func records(_ s: CloudStore.Snapshot, _ type: String) -> [CKRecord] {
        CloudStore.shared.build(s).map(\.record).filter { $0.recordType == type }
    }

    func testPicksSkipsAndScheduleRoundTrip() throws {
        let p = ClassPick(occurrenceId: 401, name: "BODYCOMBAT", occursAt: occursAt,
                          openAt: occursAt.addingTimeInterval(-167 * 3600), branchId: 1388, room: "", trainer: "Sam")
        let item = ScheduleItem(id: 401, name: "BODYCOMBAT", occursAt: occursAt, openAt: p.openAt, minutes: 60,
                                branchId: 1388, room: "Studio", trainer: "Sam", capacity: 30, full: false,
                                joined: false, autoBook: true)
        var s = snapshot()
        s.picks = [p]
        s.skips = [p]
        s.schedule = [item]
        XCTAssertEqual(records(s, "OneOff").compactMap(Cloud.pick), [p])
        XCTAssertEqual(records(s, "Skip").compactMap(Cloud.pick), [p])
        let sched = try XCTUnwrap(records(s, "Schedule").first)
        XCTAssertEqual(sched.recordID.recordName, Cloud.scheduleRecordName)
        XCTAssertEqual(Cloud.schedule(sched), [item])
        // No plan yet since launch: no Schedule record (and push keeps iCloud's copy).
        XCTAssertTrue(records(snapshot(), "Schedule").isEmpty)
    }

    func testOneOffClassBypassesItsKey() {
        let p = ClassPick(occurrenceId: 401, name: "BODYCOMBAT", occursAt: occursAt, openAt: occursAt, branchId: 1388)
        let k = RecurringClass.oneOff(p)
        XCTAssertTrue(k.isOneOff)
        XCTAssertEqual(k.key, "oneoff-401")
        XCTAssertEqual(k.locationIds, [1388])
        XCTAssertFalse(RecurringClass(key: "rpm-wed", name: "RPM", weekday: "Wed", start: "09:30", locationIds: [1388]).isOneOff)
    }

    func testClassRoundTrip() throws {
        let c = try XCTUnwrap(records(snapshot(), "Class").first.flatMap(Cloud.Class.init))
        XCTAssertEqual(c.key, "bodypump-tue")
        XCTAssertEqual(c.name, "BODYPUMP")
        XCTAssertEqual(c.weekday, "Tue")
        XCTAssertEqual(c.start, "09:00")
        XCTAssertEqual(c.locationIds, [1392])
    }

    func testAwayRangesRoundTrip() {
        let ps = records(snapshot(), "AwayRange").compactMap(Cloud.AwayRange.init).sorted { $0.start < $1.start }
        XCTAssertEqual(ps.count, 2)
        XCTAssertEqual(ps[0].start, "2026-10-23")
        XCTAssertEqual(ps[0].except, ["lift-hiit-fri"])
        XCTAssertNil(ps[0].note)
        XCTAssertEqual(ps[1].end, "2026-11-27")
        XCTAssertEqual(ps[1].except, [])      // empty lists are left out, and read back as empty
        XCTAssertEqual(ps[1].note, "Thanksgiving")
    }

    func testSwapsRoundTrip() {
        let ws = records(snapshot(), "Swap").compactMap(Cloud.Swap.init).sorted { $0.date < $1.date }
        XCTAssertEqual(ws.count, 2)
        XCTAssertEqual(ws[0].skip, "cycle-sculpt-thu")
        XCTAssertNil(ws[0].bookName)
        XCTAssertEqual(ws[1].bookName, "BODYCOMBAT")
        XCTAssertEqual(ws[1].bookStart, "09:50")
        XCTAssertEqual(ws[1].bookLocationIds, [1388])
        XCTAssertEqual(ws[1].note, "try it")
    }

    func testOpeningRoundTrip() throws {
        let o = try XCTUnwrap(records(snapshot(), "Opening").first.flatMap(Cloud.Opening.init))
        XCTAssertEqual(o.classKey, "bodypump-tue")
        XCTAssertEqual(o.className, "BODYPUMP")
        XCTAssertEqual(o.occursAt, occursAt)
        XCTAssertTrue(o.live)
        XCTAssertTrue(o.booked)
        XCTAssertFalse(o.failed)
        XCTAssertEqual(o.verdict, "already booked — another trigger got there first")
        XCTAssertEqual(o.sendLagMs, 4)
        XCTAssertEqual(try XCTUnwrap(o.fillSeconds), 42, accuracy: 0.001)
    }

    func testSlotStatRoundTrip() throws {
        let s = try XCTUnwrap(records(snapshot(), "SlotStat").first.flatMap(Cloud.Slot.init))
        XCTAssertEqual(s.name, "BODYPUMP")
        XCTAssertEqual(s.branchId, 1392)
        XCTAssertEqual(s.weeks, 6)
        XCTAssertEqual(s.filledWeeks, 6)
        XCTAssertEqual(s.medianFill, 37)
        XCTAssertEqual(s.fastestFill, 31)
        XCTAssertEqual(s.filledWithinMinute, 5)
        XCTAssertEqual(s.medianWaitlist, 3)
    }

    func testMacStatusRoundTrip() throws {
        let m = try XCTUnwrap(records(snapshot(), "MacStatus").first.flatMap(Cloud.MacStatus.init))
        XCTAssertEqual(m.updatedAt, occursAt)
        XCTAssertEqual(m.liveClasses, 11)
        XCTAssertEqual(m.nextOpening, occursAt)
        XCTAssertEqual(m.nextOpeningClasses, ["BODYPUMP"])
        XCTAssertNil(m.syncError)
    }

    func testBookingRoundTrip() throws {
        let b = CloudStore.Booking(occurrenceId: 309129, name: "Cycle", occursAt: occursAt, minutes: 60,
                                   branchId: 1392, room: "Cycle Studio", trainer: "")
        let r = try XCTUnwrap(records(snapshot(bookings: [b]), "Booking").first)
        let d = try XCTUnwrap(Cloud.Booking(r))
        XCTAssertEqual(d.name, "Cycle")
        XCTAssertEqual(d.occursAt, occursAt)
        XCTAssertEqual(d.minutes, 60)
        XCTAssertEqual(d.branchId, 1392)
        XCTAssertEqual(d.room, "Cycle Studio")
        XCTAssertNil(d.trainer)               // empty strings aren't stored
    }

    func testNoBookingRecordsBeforeFirstPlan() {
        XCTAssertTrue(records(snapshot(bookings: nil), "Booking").isEmpty)
    }

    func testRecordNamesAndHashesAreStable() {
        let s = snapshot()
        let a = CloudStore.shared.build(s), b = CloudStore.shared.build(s)
        XCTAssertEqual(a.map(\.name).sorted(), b.map(\.name).sorted())
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: a.map { ($0.name, $0.hash) }),
                       Dictionary(uniqueKeysWithValues: b.map { ($0.name, $0.hash) }))
        XCTAssertEqual(Set(a.map(\.record.recordID.zoneID.zoneName)), [Cloud.zoneName])
    }

    func testOldOpeningsAreLeftOut() {
        var s = snapshot()
        var old = s.log[0]
        old.id = UUID()
        s.log.append(ShadowEntry(classKey: old.classKey, className: old.className, occurrenceId: 1,
                                 occursAt: Date().addingTimeInterval(-200 * 86400),
                                 openAt: Date().addingTimeInterval(-207 * 86400), away: false))
        XCTAssertEqual(records(s, "Opening").count, 1)
    }
}
#endif
