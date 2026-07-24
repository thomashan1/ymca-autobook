import Foundation

/// Reads/writes the recurring lineup in `classes.yml`.
///
/// v1 ships a tiny purpose-built parser for the known, flat `classes.yml`
/// shape (see the repo's classes.yml). If the schema grows, swap this for the
/// Yams SwiftPM package — declare it in `project.yml` under `packages`.
@MainActor
final class ClassesRepository: ObservableObject {
    @Published var classes: [GymClass] = []
    @Published var isLoading = false
    @Published var error: String?

    private let client: GitHubClient
    private var sha: String?

    init(client: GitHubClient = GitHubClient()) { self.client = client }

    func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let (text, sha) = try await client.readFile(repo: Config.publicRepo, path: Config.classesPath)
            self.sha = sha
            self.classes = Self.parse(text).sorted { ($0.weekday, $0.start) < ($1.weekday, $1.start) }
        } catch {
            self.error = String(describing: error)
        }
    }

    var regulars: [GymClass] { classes.filter { !$0.isTrial } }
    var trials: [GymClass] { classes.filter { $0.isTrial } }

    // MARK: Minimal YAML for the classes: [...] list

    static func parse(_ yaml: String) -> [GymClass] {
        var result: [GymClass] = []
        var cur: [String: String] = [:]
        func flush() {
            if let key = cur["key"], let name = cur["name"],
               let wd = cur["weekday"].flatMap(Weekday.init(rawValue:)),
               let start = cur["start"] {
                let ids = (cur["location_ids"] ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                result.append(GymClass(key: key, name: name, weekday: wd,
                                       start: start, locationIds: ids, firstLive: nil))
            }
            cur = [:]
        }
        for raw in yaml.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.isEmpty else { continue }
            if line.hasPrefix("- ") { flush() }
            let content = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
            guard let colon = content.firstIndex(of: ":") else { continue }
            let k = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
            var v = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let hash = v.firstIndex(of: "#") { v = String(v[..<hash]).trimmingCharacters(in: .whitespaces) }
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if ["key", "name", "weekday", "start", "location_ids"].contains(k) { cur[k] = v }
        }
        flush()
        return result
    }
}

private func < (l: (Weekday, String), r: (Weekday, String)) -> Bool {
    l.0 == r.0 ? l.1 < r.1 : l.0 < r.0
}
