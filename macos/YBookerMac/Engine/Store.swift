import Foundation

/// Local files in ~/Library/Application Support/YBookerMac. Classes and pauses are
/// seeded from JSON bundled with the build on first launch; the shadow log is
/// appended as the app runs.
enum Store {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("YBookerMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private static func seeded<T: Decodable>(_ name: String, as: T.Type) -> T? {
        let local = url(name)
        if !FileManager.default.fileExists(atPath: local.path),
           let bundled = Bundle.main.url(forResource: name.replacingOccurrences(of: ".json", with: ""),
                                         withExtension: "json", subdirectory: nil) {
            try? FileManager.default.copyItem(at: bundled, to: local)
        }
        guard let data = try? Data(contentsOf: local) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func classes() -> [RecurringClass] { seeded("classes.json", as: [RecurringClass].self) ?? [] }
    static func pauses() -> [Pause] { seeded("pauses.json", as: [Pause].self) ?? [] }

    static func save(classes: [RecurringClass]) { write(classes, to: "classes.json") }
    static func save(pauses: [Pause]) { write(pauses.sorted { $0.start < $1.start }, to: "pauses.json") }

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

    static func shadowLog() -> [ShadowEntry] {
        guard let data = try? Data(contentsOf: url("shadow-log.json")) else { return [] }
        return (try? decoder.decode([ShadowEntry].self, from: data)) ?? []
    }

    static func save(shadowLog: [ShadowEntry]) {
        guard let data = try? encoder.encode(Array(shadowLog.suffix(1000))) else { return }
        try? data.write(to: url("shadow-log.json"), options: .atomic)
    }
}
