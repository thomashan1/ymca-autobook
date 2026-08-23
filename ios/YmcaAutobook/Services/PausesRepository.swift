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
            let mon = CalendarHelper.currentMonday
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

    // MARK: Write-back (pauses.yml is in the private repo — direct commit, no PR)

    func add(start: Date, end: Date, except: [String] = [], note: String? = nil) async -> String? {
        var next = pauses
        next.append(Pause(start: start, end: end, except: except, note: note))
        return await write(next, message: "Add pause \(Self.df.string(from: start))–\(Self.df.string(from: end)) via iOS app")
    }

    func delete(_ pause: Pause) async -> String? {
        let next = Self.removing(pause, from: pauses)
        return await write(next, message: "Remove pause \(Self.df.string(from: pause.start))–\(Self.df.string(from: pause.end)) via iOS app")
    }

    /// Drop `pause` from `list`. If it owned a section header, hand the comment to
    /// whichever entry now starts that section instead of deleting it too.
    static func removing(_ pause: Pause, from list: [Pause]) -> [Pause] {
        var next = list.filter { $0.id != pause.id }
        guard !pause.header.isEmpty else { return next }
        if let heir = next.indices
            .filter({ next[$0].start >= pause.start })
            .min(by: { next[$0].start < next[$1].start }) {
            next[heir].header = pause.header + next[heir].header
        }
        return next
    }

    /// Commit the given set to pauses.yml. Returns nil on success, else a message.
    private func write(_ next: [Pause], message: String) async -> String? {
        let sorted = next.sorted { $0.start < $1.start }
        if SampleMode.active { pauses = sorted; return nil }
        guard let sha else { return "pauses.yml hasn't loaded yet — pull to refresh and retry." }
        do {
            try await client.writeFile(repo: Config.privateRepo, path: Config.pausesPath,
                                       text: Self.serialize(sorted), message: message, sha: sha)
            await load()   // refresh parsed list + new blob sha
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// Emit pauses.yml in the flow style the Python engine + parser read, keeping
    /// each entry's `except` list and inline `# note`.
    static func serialize(_ pauses: [Pause]) -> String {
        var lines = ["pauses:"]
        for p in pauses.sorted(by: { $0.start < $1.start }) {
            if !p.header.isEmpty {
                lines.append("")
                lines.append(contentsOf: p.header.map { "  # \($0)" })
            }
            var inner = "start: \(df.string(from: p.start)), end: \(df.string(from: p.end))"
            if !p.except.isEmpty { inner += ", except: [\(p.except.joined(separator: ", "))]" }
            var line = "  - {\(inner)}"
            if let note = p.note, !note.isEmpty {
                // Align inline notes the way the hand-maintained file does, so an
                // app write doesn't reflow every line it didn't touch.
                line += String(repeating: " ", count: max(2, 70 - line.count)) + "# \(note)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Minimal YAML for pauses: [{start:, end:, except: [...]}]

    static func parse(_ yaml: String) -> [Pause] {
        var result: [Pause] = []
        var pendingHeader: [String] = []
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
            guard line.hasPrefix("- {") else {
                // Nothing but a comment on this line -> a section header. Hold it
                // for the next entry so a write-back can put it back.
                if line.isEmpty, let note { pendingHeader.append(note) }
                continue
            }
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
                result.append(Pause(start: s, end: e, except: except, note: note,
                                    header: pendingHeader))
            }
            pendingHeader = []
        }
        return result
    }
}
