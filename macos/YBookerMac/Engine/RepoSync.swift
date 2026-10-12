import Foundation

/// Reads away dates and one-off swaps from the private repo — the same
/// `pauses.yml` / `swaps.yml` the GitHub engine and the iOS app use, so there's
/// one place to change them. Read-only: edits are made in the repo itself.
///
/// The parsers are ports of the iOS app's (PausesRepository / SwapsRepository):
/// just enough YAML for the two files' fixed shapes. The Python engine uses a
/// real YAML parser and stays the authority on what the files mean.
enum RepoSync {
    static let repo = "thomashan1/ymca-private"
    private static let tokenKey = "githubToken"

    /// A fine-grained token with Contents: Read-only on the private repo.
    static var token: String? { Keychain.string(tokenKey).flatMap { $0.isEmpty ? nil : $0 } }
    static func setToken(_ t: String) {
        let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { Keychain.delete(tokenKey) } else { Keychain.setString(t, for: tokenKey) }
    }

    enum Failure: LocalizedError {
        case noToken, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noToken: return "No GitHub token — add one in Settings → General"
            case .http(401, _), .http(403, _): return "GitHub refused the token (expired, or no access to \(RepoSync.repo))"
            case .http(let code, let path): return "GitHub returned \(code) for \(path)"
            }
        }
    }

    /// The file's text, or nil if it doesn't exist.
    static func fetch(_ path: String) async throws -> String? {
        guard let token else { throw Failure.noToken }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/contents/\(path)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        // Short: a sync runs right before each opening and must never hold it up.
        req.timeoutInterval = 8
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw Failure.http(code, path) }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: pauses.yml — `- {start: 2026-10-23, end: 2026-10-23, except: [a, b]}  # note`

    static func parsePauses(_ yaml: String) -> [Pause] {
        var result: [Pause] = []
        for raw in yaml.components(separatedBy: .newlines) {
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
            var start: String?, end: String?, except: [String] = []
            // Protect commas inside the `except: [...]` list, then split fields.
            let normalized = inner.replacingOccurrences(of: "], ", with: "]|")
            let separator: Character = normalized.contains("|") ? "|" : ","
            for field in normalized.split(separator: separator) {
                let parts = field.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                switch parts[0].trimmingCharacters(in: .whitespaces) {
                case "start": start = v
                case "end": end = v
                case "except":
                    except = v.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                default: break
                }
            }
            if let s = start, let e = end, isDay(s), isDay(e) {
                result.append(Pause(start: s, end: e, except: except.isEmpty ? nil : except, note: note))
            }
        }
        return result
    }

    // MARK: swaps.yml — keyed off field names, not indentation (see the iOS parser)

    static func parseSwaps(_ yaml: String) -> [Swap] {
        var result: [Swap] = []
        var current: Swap?
        func flush() {
            if let c = current, !c.date.isEmpty, c.skip != nil || c.bookName != nil { result.append(c) }
            current = nil
        }
        for raw in yaml.components(separatedBy: .newlines) {
            var trimmed = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("-") {
                flush()
                current = Swap(date: "")
                trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
            }
            guard current != nil else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = unquote(parts[1].trimmingCharacters(in: .whitespaces))
            guard !value.isEmpty else { continue }   // the bare "book:" line
            switch parts[0].trimmingCharacters(in: .whitespaces) {
            case "date": if isDay(value) { current?.date = value }
            case "skip": current?.skip = value
            case "note": current?.note = value
            case "name": current?.bookName = value
            case "start": current?.bookStart = value
            case "location_ids":
                current?.bookLocationIds = value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            default: break
            }
        }
        flush()
        return result
    }

    private static func isDay(_ s: String) -> Bool {
        s.count == 10 && s.split(separator: "-").count == 3
    }

    /// Drop a trailing `# comment`, ignoring any `#` inside a quoted value.
    private static func stripComment(_ line: String) -> String {
        var inQuotes = false
        for (i, ch) in line.enumerated() {
            if ch == "\"" { inQuotes.toggle() }
            if ch == "#" && !inQuotes { return String(line.prefix(i)) }
        }
        return line
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast())
    }
}
