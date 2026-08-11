import Foundation

/// Reads one-off swaps from the **private** repo's `swaps.yml`.
///
/// Read-only on purpose: a swap has to be secured against a live booking window
/// (book the replacement, only then release the original), which is the Actions
/// engine's job. The app shows what's pending so the week reads correctly.
@MainActor
final class SwapsRepository: ObservableObject {
    @Published var swaps: [Swap] = []
    @Published var isLoading = false
    @Published var error: String?

    private let client: GitHubClient

    init(client: GitHubClient = GitHubClient()) { self.client = client }

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = Config.timeZone
        return f
    }()

    func load() async {
        if SampleMode.active {
            swaps = SampleData.swaps
            error = nil
            return
        }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let (text, _) = try await client.readFile(repo: Config.privateRepo, path: Config.swapsPath)
            self.swaps = Self.parse(text)
        } catch {
            // An absent swaps.yml is the normal state for most weeks — treat it as
            // "no swaps" rather than an error banner the user can't act on.
            self.swaps = []
            self.error = nil
        }
    }

    /// Swaps whose date hasn't passed, soonest first — the only ones worth showing.
    func upcoming(from day: Date = Date(), calendar: Calendar = .current) -> [Swap] {
        let today = calendar.startOfDay(for: day)
        return swaps.filter { calendar.startOfDay(for: $0.date) >= today }
            .sorted { $0.date < $1.date }
    }

    /// The swap covering `day`, if any — used to annotate the Week view.
    func swap(on day: Date, calendar: Calendar = .current) -> Swap? {
        swaps.first { $0.matches(day, calendar: calendar) }
    }

    /// True if `classKey` is displaced by a swap on `day`, so the Week view can
    /// show it as dropped rather than booked.
    func isSwappedOut(_ classKey: String, on day: Date, calendar: Calendar = .current) -> Bool {
        swaps.contains { $0.matches(day, calendar: calendar) && $0.skipKey == classKey }
    }

    // MARK: Minimal YAML for the fixed swaps.yml shape
    //
    // Keyed off field NAMES rather than indentation: `date`/`skip`/`note` only
    // ever appear on an entry and `name`/`start`/`location_ids` only ever appear
    // inside `book:`, so there's nothing to disambiguate and no indent tracking
    // to get wrong. Anything richer belongs in the Python engine, which uses a
    // real YAML parser.

    static func parse(_ yaml: String) -> [Swap] {
        var result: [Swap] = []
        var current: Swap?

        func flush() {
            if let c = current, c.skipKey != nil || c.bookName != nil { result.append(c) }
            current = nil
        }

        for raw in yaml.components(separatedBy: .newlines) {
            let line = Self.stripComment(raw)
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // A new list item; the dash may carry the first key ("- date: ...").
            if trimmed.hasPrefix("-") {
                flush()
                current = Swap(date: Date())
                trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
            }
            guard current != nil else { continue }

            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = Self.unquote(parts[1].trimmingCharacters(in: .whitespaces))
            guard !value.isEmpty else { continue }   // e.g. the bare "book:" line

            switch key {
            case "date": if let d = df.date(from: value) { current?.date = d }
            case "skip": current?.skipKey = value
            case "note": current?.note = value
            case "name": current?.bookName = value
            case "start": current?.bookStart = value
            case "location_ids":
                current?.bookLocationIDs = value
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    .split(separator: ",")
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            default: break
            }
        }
        flush()
        return result
    }

    /// Drop a trailing `# comment`, ignoring any `#` inside a quoted value.
    private static func stripComment(_ line: String) -> String {
        var inQuotes = false
        for (i, ch) in line.enumerated() {
            if ch == "\"" { inQuotes.toggle() }
            if ch == "#" && !inQuotes {
                return String(line.prefix(i))
            }
        }
        return line
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast())
    }
}
