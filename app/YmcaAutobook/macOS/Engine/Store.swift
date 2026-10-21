#if os(macOS)
import Foundation

/// Local files in ~/Library/Application Support/YBookerMac. Classes and away dates are
/// seeded from JSON bundled with the build on first launch; the shadow log is
/// appended as the app runs.
enum Store {
    static let dir: URL = {
        // Screenshot mode never sees or touches the real files.
        if MacSample.active {
            let d = FileManager.default.temporaryDirectory.appendingPathComponent("YBookerSample-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("YBookerMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        // Away dates were kept in pauses.json before 2026-10-15.
        let old = d.appendingPathComponent("pauses.json"), new = d.appendingPathComponent("away.json")
        if !FileManager.default.fileExists(atPath: new.path) { try? FileManager.default.moveItem(at: old, to: new) }
        return d
    }()

    private static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        (try? Data(contentsOf: url(name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func classes() -> [RecurringClass] { load("classes.json", as: [RecurringClass].self) ?? [] }
    static func awayRanges() -> [AwayRange] { load("away.json", as: [AwayRange].self) ?? [] }

    static func swaps() -> [Swap] {
        (try? Data(contentsOf: url("swaps.json"))).flatMap { try? JSONDecoder().decode([Swap].self, from: $0) } ?? []
    }
    static func save(swaps: [Swap]) { write(swaps.sorted { $0.date < $1.date }, to: "swaps.json") }

    static func picks() -> [ClassPick] {
        guard let data = try? Data(contentsOf: url("picks.json")) else { return [] }
        return (try? decoder.decode([ClassPick].self, from: data)) ?? []
    }
    static func save(picks: [ClassPick]) {
        guard let data = try? encoder.encode(picks.sorted { $0.openAt < $1.openAt }) else { return }
        try? data.write(to: url("picks.json"), options: .atomic)
    }

    static func skips() -> [ClassPick] {
        guard let data = try? Data(contentsOf: url("skips.json")) else { return [] }
        return (try? decoder.decode([ClassPick].self, from: data)) ?? []
    }
    static func save(skips: [ClassPick]) {
        guard let data = try? encoder.encode(skips.sorted { $0.occursAt < $1.occursAt }) else { return }
        try? data.write(to: url("skips.json"), options: .atomic)
    }

    /// When a file last changed on disk, to notice edits made outside the app.
    static func modified(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(name).path))?[.modificationDate] as? Date
    }

    static func save(classes: [RecurringClass]) { write(classes, to: "classes.json") }
    static func save(awayRanges: [AwayRange]) { write(awayRanges.sorted { $0.start < $1.start }, to: "away.json") }

    private static func write<T: Encodable>(_ value: T, to name: String) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    // Milliseconds matter here: "landed at 10:00:00" says nothing about whether the
    // read beat a class that fills in 30 s. Plain .iso8601 drops fractional seconds.
    private static let isoMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(isoMillis.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = FisikalDate.parse(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
            }
            return date
        }
        return d
    }

    static func fillHistory() -> [FillRecord] {
        guard let data = try? Data(contentsOf: url("fill-history.json")) else { return [] }
        return (try? decoder.decode([FillRecord].self, from: data)) ?? []
    }

    static func save(fillHistory: [FillRecord]) {
        guard let data = try? encoder.encode(fillHistory.sorted { $0.openAt < $1.openAt }) else { return }
        try? data.write(to: url("fill-history.json"), options: .atomic)
    }

    static func shadowLog() -> [ShadowEntry] {
        guard let data = try? Data(contentsOf: url("shadow-log.json")) else { return [] }
        return (try? decoder.decode([ShadowEntry].self, from: data)) ?? []
    }

    static func save(shadowLog: [ShadowEntry]) {
        guard let data = try? encoder.encode(Array(shadowLog.suffix(1000))) else { return }
        try? data.write(to: url("shadow-log.json"), options: .atomic)
    }
}
#endif
