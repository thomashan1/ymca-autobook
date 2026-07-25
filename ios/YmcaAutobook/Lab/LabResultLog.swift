import Foundation

/// LAB — persists the spike's result lines across relaunches.
///
/// The session lives in the Keychain and survives app restarts, so an in-memory
/// log left you looking at a stored session with no record of how it was
/// obtained. Session lifetime is measured over days, so the log has to outlive
/// the process.
enum LabResultLog {
    private static let key = "lab.results"
    private static let limit = 200

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ lines: [String]) {
        UserDefaults.standard.set(Array(lines.prefix(limit)), forKey: key)
    }

    /// Prepend a stamped line and persist. Returns the new log.
    static func append(_ line: String, to lines: [String]) -> [String] {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        let next = ["\(f.string(from: Date()))  \(line)"] + lines
        save(next)
        return next
    }
}
