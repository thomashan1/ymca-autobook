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

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
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
