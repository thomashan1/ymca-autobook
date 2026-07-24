import Foundation

enum Branch: Int, Codable {
    case southwest = 1392
    case northwest = 1388

    var short: String { self == .southwest ? "SW" : "NW" }
    var name: String { self == .southwest ? "Southwest" : "Northwest" }
}

enum Weekday: String, Codable, CaseIterable, Comparable {
    case mon = "Mon", tue = "Tue", wed = "Wed", thu = "Thu", fri = "Fri"
    case sat = "Sat", sun = "Sun"

    var order: Int { Weekday.allCases.firstIndex(of: self)! }
    static func < (l: Weekday, r: Weekday) -> Bool { l.order < r.order }

    var fullName: String {
        switch self {
        case .mon: return "Monday"
        case .tue: return "Tuesday"
        case .wed: return "Wednesday"
        case .thu: return "Thursday"
        case .fri: return "Friday"
        case .sat: return "Saturday"
        case .sun: return "Sunday"
        }
    }
}

/// One recurring class from `classes.yml`. A class is a "trial" when it carries
/// a `firstLive` date in the future (mirrors the CLAUDE.md trial convention);
/// otherwise it's a regular.
struct GymClass: Identifiable, Codable, Hashable {
    var key: String            // e.g. "vinyasa-yoga-mon"
    var name: String           // exact Fisikal title
    var weekday: Weekday
    var start: String          // local "HH:mm"
    var locationIds: [Int]

    /// Not in classes.yml today — an optional app-side annotation for the
    /// trial/first-live badge shown in the mockup. Persisted as a YAML comment
    /// or side file; nil means "regular".
    var firstLive: Date?

    var id: String { key }
    var branch: Branch { Branch(rawValue: locationIds.first ?? 1392) ?? .southwest }
    var isTrial: Bool {
        guard let firstLive else { return false }
        return firstLive > Date()
    }
}
