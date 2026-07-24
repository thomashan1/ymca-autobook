import Foundation

/// Reads/writes away-dates in the **private** repo's `pauses.yml`.
@MainActor
final class PausesRepository: ObservableObject {
    @Published var pauses: [Pause] = []
    @Published var isLoading = false
    @Published var error: String?

    private let client: GitHubClient
    private var sha: String?

    init(client: GitHubClient = GitHubClient()) { self.client = client }

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = Config.timeZone
        return f
    }()

    func load() async {
        if SampleMode.active {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = Config.timeZone; cal.firstWeekday = 2
            let mon = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
            pauses = SampleData.awayNotes.compactMap { n in
                guard let s = cal.date(byAdding: .day, value: n.offsetFromThisMon, to: mon) else { return nil }
                let e = cal.date(byAdding: .day, value: n.days - 1, to: s) ?? s
                return Pause(start: s, end: e, except: n.except, note: n.note)
            }
            error = nil
            return
        }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let (text, sha) = try await client.readFile(repo: Config.privateRepo, path: Config.pausesPath)
            self.sha = sha
            self.pauses = Self.parse(text)
        } catch {
            self.error = String(describing: error)
        }
    }

    func isAway(_ day: Date, classKey: String) -> Bool {
        pauses.contains { $0.contains(day) && !$0.except.contains(classKey) }
    }

    /// True if the day falls in any pause (ignoring per-class `except`) — for the
    /// Away calendar's day highlighting.
    func isPaused(_ day: Date) -> Bool {
        pauses.contains { $0.contains(day) }
    }

    // MARK: Minimal YAML for pauses: [{start:, end:, except: [...]}]

    static func parse(_ yaml: String) -> [Pause] {
        var result: [Pause] = []
        for raw in yaml.components(separatedBy: .newlines) {
            // Split off any inline "# comment" (pauses.yml annotates entries) and keep it as a note.
            var line = raw
            var note: String?
            if let hash = line.firstIndex(of: "#") {
                let comment = line[line.index(after: hash)...].trimmingCharacters(in: .whitespaces)
                if !comment.isEmpty { note = comment }
                line = String(line[..<hash])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- {") else { continue }
            let inner = line.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
            var start: Date?, end: Date?, except: [String] = []
            // Protect commas inside the `except: [...]` list, then split fields.
            let normalized = inner.replacingOccurrences(of: "], ", with: "]|")
            let separator: Character = normalized.contains("|") ? "|" : ","
            for field in normalized.split(separator: separator) {
                let parts = field.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let k = parts[0].trimmingCharacters(in: .whitespaces)
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                switch k {
                case "start": start = df.date(from: v)
                case "end": end = df.date(from: v)
                case "except":
                    except = v.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                default: break
                }
            }
            if let s = start, let e = end {
                result.append(Pause(start: s, end: e, except: except, note: note))
            }
        }
        return result
    }
}
