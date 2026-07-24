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
        if SampleMode.active {
            classes = SampleData.classes.sorted { ($0.weekday, $0.start) < ($1.weekday, $1.start) }
            return
        }
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

    // MARK: Delete a class (via PR, since classes.yml lives on protected main)

    enum DeleteOutcome { case merged, prOpened(Int, String), failed(String) }

    /// Remove a class from classes.yml on a branch, open a PR, and try to land
    /// it (immediate merge, else enable auto-merge). Refreshes on success.
    func delete(_ c: GymClass) async -> DeleteOutcome {
        do {
            let (text, sha) = try await client.readFile(repo: Config.publicRepo, path: Config.classesPath)
            guard let newText = Self.removingClass(c.key, from: text) else {
                return .failed("Couldn't find \(c.key) in classes.yml.")
            }
            let stamp = Int(Date().timeIntervalSince1970)
            let branch = "app/remove-\(c.key)-\(stamp)"
            let head = try await client.headSha()
            try await client.createBranch(branch, fromSha: head)
            try await client.writeFile(
                repo: Config.publicRepo, path: Config.classesPath, text: newText,
                message: "Remove \(c.name) (\(c.weekday.rawValue) \(c.start)) via iOS app",
                sha: sha, branch: branch)
            let pr = try await client.createPR(
                title: "Remove \(c.name) (\(c.weekday.rawValue) \(c.start))",
                head: branch,
                body: "Removing this class from the auto-book schedule, requested from the iOS app.")

            // Try an immediate merge; fall back to enabling auto-merge.
            do {
                try await client.mergePR(number: pr.number)
                await load()
                return .merged
            } catch {
                try? await client.enableAutoMerge(prNodeId: pr.node_id)
                return .prOpened(pr.number, pr.html_url)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Remove one `- key: <key>` block (and its indented lines) from classes.yml text.
    static func removingClass(_ key: String, from yaml: String) -> String? {
        var lines = yaml.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { isKeyLine($0, key) }) else { return nil }
        var end = lines.count
        var i = start + 1
        while i < lines.count {
            let raw = lines[i]
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") { end = i; break }                    // next list entry
            if !raw.hasPrefix(" ") && !t.isEmpty { end = i; break }     // dedent to a top-level key
            i += 1
        }
        lines.removeSubrange(start..<end)
        return lines.joined(separator: "\n")
    }

    private static func isKeyLine(_ line: String, _ key: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("- key:") else { return false }
        var v = t.dropFirst("- key:".count).trimmingCharacters(in: .whitespaces)
        if let hash = v.firstIndex(of: "#") { v = v[..<hash].trimmingCharacters(in: .whitespaces) }
        return v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) == key
    }

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
