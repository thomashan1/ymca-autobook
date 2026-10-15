#if os(macOS)
import XCTest
@testable import YMCA_Booker

final class RepoSyncTests: XCTestCase {
    func testParsePauses() {
        let yaml = """
        pauses:
          # Fall
          - {start: 2026-10-23, end: 2026-10-23}                              # teacher day
          - {start: 2026-11-23, end: 2026-11-27, except: [core-mon, lift-hiit-mon]}
        """
        let ps = RepoSync.parsePauses(yaml)
        XCTAssertEqual(ps.count, 2)
        XCTAssertEqual(ps[0].start, "2026-10-23")
        XCTAssertEqual(ps[0].note, "teacher day")
        XCTAssertEqual(ps[1].end, "2026-11-27")
        XCTAssertEqual(ps[1].except ?? [], ["core-mon", "lift-hiit-mon"])
    }

    func testMirrorSkipsAddsRemovesAndLeavesOthers() {
        let yaml = """
        # header comment
        swaps:
          - date: 2026-10-01
            skip: cycle-sculpt-thu
            note: "lunch"

          - date: 2026-10-20
            skip: cycle-tue
            note: "Skipped in YMCA Booker"
        """
        let out = RepoSync.mirrorSkips(yaml, want: ["2026-10-22|bodypump-thu"])
        let swaps = RepoSync.parseSwaps(out)
        XCTAssertEqual(swaps.map(\.date), ["2026-10-01", "2026-10-22"])
        XCTAssertEqual(swaps.map(\.skip), ["cycle-sculpt-thu", "bodypump-thu"])
        XCTAssertTrue(out.hasPrefix("# header comment\nswaps:\n  - date: 2026-10-01"))
        // Idempotent, and an empty want removes only the Mac's own entries.
        XCTAssertEqual(RepoSync.mirrorSkips(out, want: ["2026-10-22|bodypump-thu"]), out)
        XCTAssertEqual(RepoSync.parseSwaps(RepoSync.mirrorSkips(out, want: [])).map(\.date), ["2026-10-01"])
    }

    func testMirrorSkipsIntoEmptyFile() {
        let out = RepoSync.mirrorSkips("swaps: []\n", want: ["2026-10-22|bodypump-thu"])
        XCTAssertEqual(out, "swaps:\n\n  - date: 2026-10-22\n    skip: bodypump-thu\n    note: \"Skipped in YMCA Booker\"\n")
        XCTAssertEqual(RepoSync.parseSwaps(out).first?.isSkipOnly, true)
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

    func testPauseCoversRespectsExcept() {
        let p = Pause(start: "2026-11-23", end: "2026-11-27", except: ["core-mon"])
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
}

#endif
