#if os(macOS)
import XCTest
@testable import YMCA_Booker

final class RepoSyncTests: XCTestCase {
    func testParseAway() {
        let yaml = """
        awayRanges:
          # Fall
          - {start: 2026-10-23, end: 2026-10-23}                              # teacher day
          - {start: 2026-11-23, end: 2026-11-27, except: [core-mon, lift-hiit-mon]}
        """
        let ps = RepoSync.parseAway(yaml)
        XCTAssertEqual(ps.count, 2)
        XCTAssertEqual(ps[0].start, "2026-10-23")
        XCTAssertEqual(ps[0].note, "teacher day")
        XCTAssertEqual(ps[1].end, "2026-11-27")
        XCTAssertEqual(ps[1].except ?? [], ["core-mon", "lift-hiit-mon"])
    }

    func testRepoMirrorFilesReadBack() throws {
        let classes = [
            RecurringClass(key: "bodypump-thu", name: "BODYPUMP", weekday: "Thu", start: "09:00", locationIds: [1392],
                           extraLeads: [50, 10, 5]),
            RecurringClass(key: "core-mon", name: "Core \"Conditioning\"", weekday: "Mon", start: "09:45", locationIds: [1392]),
        ]
        let c = RepoMirror.classesYAML(classes, timeZone: "America/Los_Angeles")
        XCTAssertTrue(c.contains("timezone: America/Los_Angeles"))
        XCTAssertLessThan(c.range(of: "core-mon")!.lowerBound, c.range(of: "bodypump-thu")!.lowerBound)  // Mon first
        XCTAssertTrue(c.contains("    name: \"Core \\\"Conditioning\\\"\"\n"))
        XCTAssertTrue(c.contains("    extra_leads: [50, 10, 5]"))

        let awayRanges = [AwayRange(start: "2026-11-23", end: "2026-11-27", except: ["core-mon"], note: "Thanksgiving recess"),
                      AwayRange(start: "2026-10-23", end: "2026-10-23", except: nil)]
        let p = RepoMirror.awayYAML(awayRanges)
        XCTAssertEqual(RepoSync.parseAway(p), [awayRanges[1], awayRanges[0]])
        XCTAssertEqual(RepoMirror.awayYAML([]).hasSuffix("away: []\n"), true)

        let at = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T15:45:00Z"))   // Fri 8:45 PDT
        let pick = ClassPick(occurrenceId: 1, name: "BODYCOMBAT", occursAt: at, openAt: at.addingTimeInterval(-167 * 3600),
                             branchId: 1388)
        let w = RepoMirror.swapsYAML(swaps: [], skips: [(date: "2026-10-22", key: "bodypump-thu")], picks: [pick])
        let swaps = RepoSync.parseSwaps(w)
        XCTAssertEqual(swaps.map(\.date), ["2026-10-22", "2026-10-23"])
        XCTAssertTrue(swaps[0].isSkipOnly)
        XCTAssertEqual(swaps[1].bookName, "BODYCOMBAT")
        XCTAssertEqual(swaps[1].bookStart, "08:45")
        XCTAssertEqual(swaps[1].bookLocationIds, [1388])
        XCTAssertTrue(RepoMirror.swapsYAML(swaps: [], skips: [], picks: []).hasSuffix("swaps: []\n"))
    }

    func testParseSwaps() {
        let yaml = """
        swaps:
          - date: 2026-10-02
            skip: lift-hiit-fri
            note: "try BODYCOMBAT # once"
            book:
              name: BODYCOMBAT
              start: "09:50"
              location_ids: [1388]
          - date: 2026-10-01
            skip: cycle-sculpt-thu
        """
        let ws = RepoSync.parseSwaps(yaml)
        XCTAssertEqual(ws.count, 2)
        XCTAssertEqual(ws[0].date, "2026-10-02")
        XCTAssertEqual(ws[0].bookName, "BODYCOMBAT")
        XCTAssertEqual(ws[0].bookStart, "09:50")
        XCTAssertEqual(ws[0].bookLocationIds ?? [], [1388])
        XCTAssertFalse(ws[0].isSkipOnly)
        XCTAssertTrue(ws[1].isSkipOnly)
    }
}

/// The Mac needs nothing from GitHub: the backup copy is written only with a
/// repo set (Settings → For technical users), and never replaces the Mac's own data.
final class GitHubBackupTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, String) {
        let name = "GitHubBackupTests-\(UUID())"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testBackupIsOffWithoutARepo() throws {
        XCTAssertNil(RepoSync.normalize(nil))
        XCTAssertNil(RepoSync.normalize(""))
        XCTAssertNil(RepoSync.normalize("   "))
        XCTAssertEqual(RepoSync.normalize(" me/private "), "me/private")
        let (d, name) = try defaults()
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertNil(RepoSync.repo(in: d))                 // a fresh Mac: no GitHub
        d.set("", forKey: "githubRepo")                    // what turning the backup off leaves
        XCTAssertNil(RepoSync.repo(in: d))
        d.set("me/private", forKey: "githubRepo")
        XCTAssertEqual(RepoSync.repo(in: d), "me/private")
    }

    func testMacWithoutARepoNeverImportsFromOne() throws {
        let (d, name) = try defaults()
        defer { d.removePersistentDomain(forName: name) }
        RepoSync.settleImport(d)                           // launched with no repo
        XCTAssertTrue(d.bool(forKey: RepoSync.importedKey))
        d.set("me/private", forKey: "githubRepo")          // backup turned on later
        RepoSync.settleImport(d)
        XCTAssertTrue(d.bool(forKey: RepoSync.importedKey))   // still only writes
    }

    func testMacThatHadARepoImportsOnce() throws {
        let (d, name) = try defaults()
        defer { d.removePersistentDomain(forName: name) }
        d.set("me/private", forKey: "githubRepo")
        RepoSync.settleImport(d)
        XCTAssertFalse(d.bool(forKey: RepoSync.importedKey))  // carries over once
    }

    func testOnlyChangedFilesAreWritten() {
        let files = ["classes.yml": "c2", "away.yml": "p", "swaps.yml": "s"]
        XCTAssertEqual(RepoMirror.pendingWrites(files, written: [:], force: false), RepoMirror.paths)
        XCTAssertEqual(RepoMirror.pendingWrites(files, written: ["classes.yml": "c1", "away.yml": "p", "swaps.yml": "s"],
                                                force: false), ["classes.yml"])
        XCTAssertEqual(RepoMirror.pendingWrites(files, written: files, force: false), [])
        XCTAssertEqual(RepoMirror.pendingWrites(files, written: files, force: true), RepoMirror.paths)
    }
}

final class ModelTests: XCTestCase {
    private func occurrence(_ title: String, _ iso: String) -> Occurrence? {
        Occurrence(["id": 1, "occurs_at": iso, "service_title": title,
                    "restrict_to_book_in_advance_time_in_hours": 167])
    }

    func testMatchesNameDayAndTimeInPacific() throws {
        let k = RecurringClass(key: "bodypump-tue", name: "BODYPUMP", weekday: "Tue", start: "09:00", locationIds: [1392])
        // 16:00Z on Tue 10/20 is 9:00 PDT.
        let o = try XCTUnwrap(occurrence("BodyPump ", "2026-10-20T16:00:00.000Z"))
        XCTAssertTrue(k.matches(o))
        XCTAssertFalse(k.matches(try XCTUnwrap(occurrence("BODYPUMP", "2026-10-20T16:15:00.000Z"))))
        XCTAssertFalse(k.matches(try XCTUnwrap(occurrence("BODYCOMBAT", "2026-10-20T16:00:00.000Z"))))
    }

    func testOpenAtIs167HoursBefore() throws {
        let o = try XCTUnwrap(occurrence("RPM", "2026-10-21T16:30:00.000Z"))
        XCTAssertEqual(o.occursAt.timeIntervalSince(o.openAt), 167 * 3600)
    }

    /// The Mac decides from its own away dates and one-day changes alone.
    func testSkipReasonFromTheMacsOwnData() throws {
        let k = RecurringClass(key: "bodypump-thu", name: "BODYPUMP", weekday: "Thu", start: "09:00", locationIds: [1392])
        let thu = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-22T16:00:00Z"))   // Thu 9:00 PDT
        XCTAssertNil(Engine.skipReason(k, on: thu, awayRanges: [], swaps: []))
        XCTAssertEqual(Engine.skipReason(k, on: thu, awayRanges: [AwayRange(start: "2026-10-19", end: "2026-10-23", except: nil)],
                                         swaps: []), "away")
        XCTAssertNil(Engine.skipReason(k, on: thu, awayRanges: [AwayRange(start: "2026-10-22", end: "2026-10-22", except: ["bodypump-thu"])],
                                       swaps: []), "kept by except:")
        XCTAssertEqual(Engine.skipReason(k, on: thu, awayRanges: [], swaps: [Swap(date: "2026-10-22", skip: "bodypump-thu")]),
                       "swap: skip")
        XCTAssertNil(Engine.skipReason(k, on: thu, awayRanges: [], swaps: [Swap(date: "2026-10-22", skip: "bodypump-thu",
                                                                            bookName: "BODYCOMBAT")]),
                     "with a replacement the original stays booked until the replacement lands")
        XCTAssertNil(Engine.skipReason(k, on: thu, awayRanges: [], swaps: [Swap(date: "2026-10-29", skip: "bodypump-thu")]))
        XCTAssertNil(Engine.skipReason(k, on: thu, awayRanges: [], swaps: [Swap(date: "2026-10-22", skip: "cycle-sculpt-thu")]))
    }

    /// A seat won at the opening reaches the phone with the alert, not ~5 min later.
    func testBookedSeatShowsAtOnce() throws {
        let at = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-22T16:00:00Z"))
        let o = try XCTUnwrap(Occurrence(["id": 7, "occurs_at": "2026-10-22T16:00:00.000Z", "service_title": "BODYPUMP",
                                          "duration_in_minutes": 55, "sub_location_name": "Studio", "trainer_name": "T"]))
        let item = ScheduleItem(id: 7, name: "BODYPUMP", occursAt: at, openAt: at.addingTimeInterval(-167 * 3600), minutes: 55,
                                branchId: 1392, room: "Studio", trainer: "T", capacity: 30, full: false, joined: false, autoBook: true)
        let other = CloudStore.Booking(occurrenceId: 3, name: "Cycle", occursAt: at.addingTimeInterval(-86400), minutes: 45,
                                       branchId: 1392, room: "", trainer: "")
        let (b, s) = Engine.addingBooked([(o, 1388)], bookings: [other], schedule: [item])
        XCTAssertEqual(b?.map(\.occurrenceId), [3, 7])
        XCTAssertEqual(b?.last?.branchId, 1392)               // the schedule's branch wins
        XCTAssertEqual(s?.first?.joined, true)
        let (again, _) = Engine.addingBooked([(o, 1392)], bookings: b, schedule: s)
        XCTAssertEqual(again?.count, 2)                       // no duplicates
        let (none, _) = Engine.addingBooked([(o, 1392)], bookings: nil, schedule: nil)
        XCTAssertNil(none)                                    // before the first plan, nothing to add to
    }

    func testAwayRangeCoversRespectsExcept() {
        let p = AwayRange(start: "2026-11-23", end: "2026-11-27", except: ["core-mon"])
        let mon = try! XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-23T17:45:00Z"))   // Mon 9:45 PST
        XCTAssertTrue(p.covers(mon, key: "vinyasa-yoga-mon"))
        XCTAssertFalse(p.covers(mon, key: "core-mon"))
        XCTAssertFalse(p.covers(mon.addingTimeInterval(7 * 86400), key: "vinyasa-yoga-mon"))
    }
}

final class LegacySettingsTests: XCTestCase {
    func testCopiesOldSettingsOnceWithoutOverwriting() throws {
        let name = "LegacySettingsTests-\(UUID())"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.set("mine", forKey: "githubRepo")
        LegacySettings.migrate(into: d, from: ["githubRepo": "old/repo", "historyBackfilled": true])
        XCTAssertEqual(d.string(forKey: "githubRepo"), "mine")
        XCTAssertTrue(d.bool(forKey: "historyBackfilled"))
        LegacySettings.migrate(into: d, from: ["lastSynced": Date()])
        XCTAssertNil(d.object(forKey: "lastSynced"))     // only the first launch copies
    }

    /// Away dates added and removed on the iPhone, applied by the Mac in order.
    func testAwayRequestsFromThePhone() {
        let t0 = Date(timeIntervalSince1970: 1_792_000_000)
        let have = [AwayRange(start: "2026-10-23", end: "2026-10-23", except: ["core-fri"], note: "staff day"),
                    AwayRange(start: "2026-11-23", end: "2026-11-27", except: nil, note: nil)]
        let qs = [
            Cloud.AwayRequest(action: .add, start: "2026-12-01", end: "2026-12-03", note: "trip", requestedAt: t0),
            Cloud.AwayRequest(action: .remove, start: "2026-11-23", end: "2026-11-27", requestedAt: t0.addingTimeInterval(1)),
            // Re-adding an existing range keeps its except list, updates the note.
            Cloud.AwayRequest(action: .add, start: "2026-10-23", end: "2026-10-23", note: "no school", requestedAt: t0.addingTimeInterval(2)),
            // A backwards range is ignored.
            Cloud.AwayRequest(action: .add, start: "2026-12-10", end: "2026-12-09", requestedAt: t0.addingTimeInterval(3)),
        ]
        let out = Engine.applying(qs, to: have)
        XCTAssertEqual(out.map(\.start), ["2026-10-23", "2026-12-01"])

        // Editing moves a range and keeps its "still book" classes.
        let moved = Engine.applying([Cloud.AwayRequest(action: .change, start: "2026-10-22", end: "2026-10-23",
                                                        note: "long weekend", from: ("2026-10-23", "2026-10-23"))], to: have)
        XCTAssertEqual(moved.map(\.start), ["2026-10-22", "2026-11-23"])
        XCTAssertEqual(moved[0].except, ["core-fri"])
        XCTAssertEqual(moved[0].note, "long weekend")
        XCTAssertEqual(out[0].except, ["core-fri"])
        XCTAssertEqual(out[0].note, "no school")
        XCTAssertEqual(out[1].note, "trip")
    }

    func testAwayRequestRecordRoundTrip() {
        let q = Cloud.AwayRequest(action: .remove, start: "2026-12-01", end: "2026-12-03", note: nil)
        let back = Cloud.AwayRequest(q.record())
        XCTAssertEqual(back?.action, .remove)
        XCTAssertEqual(back?.start, "2026-12-01")
        XCTAssertEqual(back?.end, "2026-12-03")
        XCTAssertEqual(back?.id, q.id)
        XCTAssertNil(Cloud.Request(q.record()))
        let c = Cloud.AwayRequest(action: .change, start: "2026-12-02", end: "2026-12-04", from: ("2026-12-01", "2026-12-03"))
        XCTAssertEqual(Cloud.AwayRequest(c.record())?.fromStart, "2026-12-01")
        XCTAssertEqual(Cloud.AwayRequest(c.record())?.fromEnd, "2026-12-03")
    }
}
#endif
