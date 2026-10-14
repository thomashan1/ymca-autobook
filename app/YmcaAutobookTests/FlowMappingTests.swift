import XCTest
@testable import YMCA_Booker

final class FlowMappingTests: XCTestCase {
    func testSplitsOnlyAtTopLevelCommas() {
        let f = FlowMapping.fields("start: 2026-11-23, end: 2026-11-27, except: [a, b, c]")
        XCTAssertEqual(f.map(\.key), ["start", "end", "except"])
        XCTAssertEqual(FlowMapping.list(f[2].value), ["a", "b", "c"])
        let g = FlowMapping.fields("start: 2026-08-03, except: [x, y], end: 2026-08-09")
        XCTAssertEqual(g.map(\.key), ["start", "except", "end"])
        XCTAssertEqual(FlowMapping.list(g[1].value), ["x", "y"])
        XCTAssertEqual(FlowMapping.list("[]"), [])
    }
}
