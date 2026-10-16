#if os(iOS)
import Foundation

/// Reads/writes away-dates in the **private** repo's `away.yml`.
@MainActor
final class AwayRepository: ObservableObject {
    @Published var awayRanges: [AwayRange] = []
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
            awayRanges = SampleData.awayNotes.compactMap { n in
                guard let s = cal.date(byAdding: .day, value: n.offsetFromThisMon, to: mon) else { return nil }
                let e = cal.date(byAdding: .day, value: n.days - 1, to: s) ?? s
                return AwayRange(start: s, end: e, except: n.except, note: n.note)
            }
            error = nil
            return
        }
        if DataSource.isCloud {
            await CloudSource.shared.ensureFresh()
            awayRanges = CloudSource.shared.awayRanges
            error = CloudSource.shared.error
            return
        }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let (text, sha) = try await client.readFile(repo: Config.privateRepo, path: Config.awayPath)
            self.sha = sha
            self.awayRanges = Self.parse(text)
        } catch {
            self.error = String(describing: error)
        }
    }

    func isAway(_ day: Date, classKey: String) -> Bool {
        awayRanges.contains { $0.contains(day) && !$0.except.contains(classKey) }
    }

    /// True if the day falls in any away range (ignoring per-class `except`) — for the
    /// Away calendar's day highlighting.
    func isAway(_ day: Date) -> Bool {
        awayRanges.contains { $0.contains(day) }
    }

    // MARK: Write-back (away.yml is in the private repo — direct commit, no PR)

    func add(start: Date, end: Date, except: [String] = [], note: String? = nil) async -> String? {
        var next = awayRanges
        next.append(AwayRange(start: start, end: end, except: except, note: note))
        return await write(next, message: "Add away dates \(Self.df.string(from: start))–\(Self.df.string(from: end)) via iOS app")
    }

    func delete(_ awayRange: AwayRange) async -> String? {
        let next = Self.removing(awayRange, from: awayRanges)
        return await write(next, message: "Remove away dates \(Self.df.string(from: awayRange.start))–\(Self.df.string(from: awayRange.end)) via iOS app")
    }

    /// Drop `awayRange` from `list`. If it owned a section header, hand the comment to
    /// whichever entry now starts that section instead of deleting it too.
    static func removing(_ awayRange: AwayRange, from list: [AwayRange]) -> [AwayRange] {
        var next = list.filter { $0.id != awayRange.id }
        guard !awayRange.header.isEmpty else { return next }
        if let heir = next.indices
            .filter({ next[$0].start >= awayRange.start })
            .min(by: { next[$0].start < next[$1].start }) {
            next[heir].header = awayRange.header + next[heir].header
        }
        return next
    }

    /// Commit the given set to away.yml. Returns nil on success, else a message.
    private func write(_ next: [AwayRange], message: String) async -> String? {
        let sorted = next.sorted { $0.start < $1.start }
        if SampleMode.active { awayRanges = sorted; return nil }
        guard let sha else { return "away.yml hasn't loaded yet — pull to refresh and retry." }
        do {
            try await client.writeFile(repo: Config.privateRepo, path: Config.awayPath,
                                       text: Self.serialize(sorted), message: message, sha: sha)
            await load()   // refresh parsed list + new blob sha
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// Emit away.yml in the flow style the Python engine + parser read, keeping
    /// each entry's `except` list and inline `# note`.
    static func serialize(_ awayRanges: [AwayRange]) -> String {
        var lines = ["away:"]
        for p in awayRanges.sorted(by: { $0.start < $1.start }) {
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

    // MARK: Minimal YAML for away dates: [{start:, end:, except: [...]}]

    static func parse(_ yaml: String) -> [AwayRange] {
        var result: [AwayRange] = []
        var pendingHeader: [String] = []
        for raw in yaml.components(separatedBy: .newlines) {
            // Split off any inline "# comment" (away.yml annotates entries) and keep it as a note.
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
            for (k, v) in FlowMapping.fields(inner) {
                switch k {
                case "start": start = df.date(from: v)
                case "end": end = df.date(from: v)
                case "except": except = FlowMapping.list(v)
                default: break
                }
            }
            if let s = start, let e = end {
                result.append(AwayRange(start: s, end: e, except: except, note: note,
                                    header: pendingHeader))
            }
            pendingHeader = []
        }
        return result
    }
}
#endif
