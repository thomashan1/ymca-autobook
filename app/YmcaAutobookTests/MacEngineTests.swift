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

        let pauses = [Pause(start: "2026-11-23", end: "2026-11-27", except: ["core-mon"], note: "Thanksgiving recess"),
                      Pause(start: "2026-10-23", end: "2026-10-23", except: nil)]
        let p = RepoMirror.pausesYAML(pauses)
        XCTAssertEqual(RepoSync.parsePauses(p), [pauses[1], pauses[0]])
        XCTAssertEqual(RepoMirror.pausesYAML([]).hasSuffix("pauses: []\n"), true)

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
