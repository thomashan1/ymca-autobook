import Foundation

/// A YMCA of Silicon Valley branch, by its Fisikal location id. The list is the
/// YMCA's own (`GET /api/web/locations`, which needs no login), not anyone's
/// lineup: the Mac reads every branch, and the Book screens filter by them.
struct Branch: Hashable, Identifiable, Codable, Sendable {
    let id: Int

    init(_ id: Int) { self.id = id }

    var name: String { Self.known[id]?.name ?? "Branch \(id)" }
    /// The chip on a class row: "SW", "PA"…
    var short: String { Self.known[id]?.short ?? "#\(id)" }

    /// Every branch with a group-exercise schedule, in the YMCA's own order.
    static let all: [Branch] = ids.map(Branch.init)
    static let ids = [1384, 1385, 1386, 1387, 1388, 1389, 1390, 1391, 1392]

    private static let known: [Int: (name: String, short: String)] = [
        1384: ("Central", "CEN"),
        1385: ("El Camino", "EC"),
        1386: ("Lewis and Joan Platt", "LJP"),
        1387: ("East Valley", "EV"),
        1388: ("Northwest", "NW"),
        1389: ("Palo Alto", "PA"),
        1390: ("Sequoia", "SEQ"),
        1391: ("South Valley", "SV"),
        1392: ("Southwest", "SW"),
    ]

    static func name(_ id: Int) -> String { Branch(id).name }

    init(from decoder: Decoder) throws { id = try decoder.singleValueContainer().decode(Int.self) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }

    // MARK: The Book screens' branch filter

    /// Chosen branches as stored in settings ("1392,1388"); empty means every branch.
    static func parse(_ stored: String) -> Set<Int> {
        Set(stored.split(separator: ",").compactMap { Int($0) })
    }

    static func store(_ ids: Set<Int>) -> String {
        // Choosing every branch is the same as choosing none: no filter.
        ids.isEmpty || Set(Self.ids).isSubset(of: ids) ? "" : ids.sorted().map(String.init).joined(separator: ",")
    }

    /// Tick or untick one branch. From "All branches" the first tick narrows
    /// to just that branch, so picking two branches is two taps; unticking the
    /// last one goes back to all of them.
    static func toggled(_ id: Int, in chosen: Set<Int>) -> Set<Int> {
        var next = chosen
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        return next
    }

    static func isShown(_ id: Int, by chosen: Set<Int>) -> Bool { chosen.isEmpty || chosen.contains(id) }

    /// "All branches", "Southwest", "Southwest + Northwest", "3 branches".
    static func label(_ ids: Set<Int>) -> String {
        switch ids.count {
        case 0: return "All branches"
        case 1: return name(ids.first!)
        case 2: return all.filter { ids.contains($0.id) }.map(\.name).joined(separator: " + ")
        default: return "\(ids.count) branches"
        }
    }
}
