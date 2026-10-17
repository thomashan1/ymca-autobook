#if os(iOS)
import XCTest
@testable import YMCA_Booker

@MainActor
final class ClassesParsingTests: XCTestCase {
    private let yaml = """
    timezone: America/Los_Angeles
    classes:
      - key: core-mon            # Les Mills CORE
        name: "Les Mills CORE"
        weekday: Mon
        start: "09:45"
        location_ids: [1392]
      - key: rpm-wed
        name: RPM
        weekday: Wed
        start: "09:30"
        location_ids: [1388]
    """

    func testParse() {
        let cs = ClassesRepository.parse(yaml)
        XCTAssertEqual(cs.map(\.key), ["core-mon", "rpm-wed"])
        XCTAssertEqual(cs[0].name, "Les Mills CORE")
        XCTAssertEqual(cs[0].weekday, .mon)
        XCTAssertEqual(cs[1].locationIds, [1388])
        XCTAssertEqual(cs[1].branch, Branch(1388))
        XCTAssertEqual(cs[1].branch.name, "Northwest")
    }

    func testRemovingClassDropsOnlyThatBlock() throws {
        let out = try XCTUnwrap(ClassesRepository.removingClass("core-mon", from: yaml))
        XCTAssertEqual(ClassesRepository.parse(out).map(\.key), ["rpm-wed"])
        XCTAssertTrue(out.contains("timezone: America/Los_Angeles"))
        XCTAssertNil(ClassesRepository.removingClass("nope", from: yaml))
    }
}

@MainActor
final class AwayParsingTests: XCTestCase {
    func testParseAndSerializeRoundTrip() {
        let yaml = """
        awayRanges:

          # Thanksgiving
          - {start: 2026-11-23, end: 2026-11-27, except: [core-mon, lift-hiit-mon]}
          - {start: 2026-10-23, end: 2026-10-23}                                # teacher day
        """
        let ps = AwayRepository.parse(yaml)
        XCTAssertEqual(ps.count, 2)
        XCTAssertEqual(ps[0].except, ["core-mon", "lift-hiit-mon"])
        XCTAssertEqual(ps[0].header, ["Thanksgiving"])
        XCTAssertEqual(ps[1].note, "teacher day")
        let again = AwayRepository.parse(AwayRepository.serialize(ps))
        XCTAssertEqual(again.map(\.id).sorted(), ps.map(\.id).sorted())
        XCTAssertEqual(again.first { $0.note != nil }?.note, "teacher day")
    }

    func testRemovingKeepsSectionHeader() {
        let ps = AwayRepository.parse("""
        awayRanges:
          # Winter
          - {start: 2026-12-21, end: 2027-01-01}
          - {start: 2027-01-18, end: 2027-01-18}
        """)
        let left = AwayRepository.removing(ps[0], from: ps)
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left[0].header, ["Winter"])
    }
}

@MainActor
final class SwapsParsingTests: XCTestCase {
    func testParse() {
        let ws = SwapsRepository.parse("""
        swaps:
          - date: 2026-10-02
            skip: lift-hiit-fri
            book:
              name: BODYCOMBAT
              start: "09:50"
              location_ids: [1388]
          - date: 2026-10-01
            skip: cycle-sculpt-thu
          - date: 2026-10-05
        """)
        XCTAssertEqual(ws.count, 2)            // an entry with neither half is dropped
        XCTAssertEqual(ws[0].skipKey, "lift-hiit-fri")
        XCTAssertEqual(ws[0].bookName, "BODYCOMBAT")
        XCTAssertEqual(ws[0].bookBranch, "Northwest")
        XCTAssertEqual(ws[1].summary, "cycle-sculpt-thu → —")
    }
}
#endif
