#if os(macOS)
import Foundation

/// The Mac's link to the GitHub backup's private repo. Since 10/14 the Mac
/// writes classes.yml, away.yml and swaps.yml there (RepoMirror) and reads
/// away.yml / swaps.yml only once, to carry over what was edited there before.
///
/// The parsers are ports of the iOS app's (AwayRepository / SwapsRepository):
/// just enough YAML for the two files' fixed shapes. The Python engine uses a
/// real YAML parser and stays the authority on what the files mean.
enum RepoSync {
    private static let tokenKey = "githubToken"
    private static let repoKey = "githubRepo"

    /// "owner/name" of the GitHub backup's private repo. Optional: only people
    /// who also run the GitHub booker (Option B) as a backup need it.
    static var repo: String? { repo(in: .standard) }
    static func repo(in d: UserDefaults) -> String? { normalize(d.string(forKey: repoKey)) }
    /// The GitHub backup is on only with a repo set; empty or blank means off.
    static var isEnabled: Bool { repo != nil }
    static func setRepo(_ r: String) { UserDefaults.standard.set(r.trimmingCharacters(in: .whitespaces), forKey: repoKey) }
    static func normalize(_ r: String?) -> String? {
        guard let t = r?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }

    /// The one-time read of away.yml / swaps.yml carries over what a Mac that
    /// used to read its away dates from the repo had there. A Mac with no repo
    /// set when this runs (at launch) has nothing to carry over, so it's marked
    /// done: turning the backup on later only writes, and never replaces the
    /// Mac's own away dates with the repo's.
    static func settleImport(_ d: UserDefaults = .standard) {
        if repo(in: d) == nil { d.set(true, forKey: importedKey) }
    }
    static let importedKey = "repoImported"

    /// A fine-grained token with Contents: Read and write on the backup's repo only.
    static var token: String? { Keychain.string(tokenKey).flatMap { $0.isEmpty ? nil : $0 } }
    static func setToken(_ t: String) {
        let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { Keychain.delete(tokenKey) } else { Keychain.setString(t, for: tokenKey) }
    }

    enum Failure: LocalizedError {
        case noRepo, noToken, readOnly, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noRepo: return "No GitHub repo set"
            case .noToken: return "No GitHub token — add one in Settings → Advanced"
            case .readOnly: return "The GitHub token can't write to \(RepoSync.repo ?? "the repo") — give it Contents: Read and write"
            case .http(401, _), .http(403, _): return "GitHub refused the token (expired, or no access to \(RepoSync.repo ?? "the repo"))"
            case .http(let code, let path): return "GitHub returned \(code) for \(path)"
            }
        }
    }

    /// The file's text, or nil if it doesn't exist.
    static func fetch(_ path: String) async throws -> String? {
        guard let repo else { throw Failure.noRepo }
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

    /// Change a file in the repo: `edit` gets its text (nil if absent) and
    /// returns the new text, or nil to leave it. Retries once if someone else
    /// committed in between.
    static func update(_ path: String, message: String, _ edit: (String?) -> String?) async throws {
        guard let repo else { throw Failure.noRepo }
        guard let token else { throw Failure.noToken }
        let url = URL(string: "https://api.github.com/repos/\(repo)/contents/\(path)")!
        func request(_ method: String) -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 15
            return req
        }
        struct Current: Decodable { let sha: String; let content: String }
        for attempt in 1...2 {
            let (data, resp) = try await URLSession.shared.data(for: request("GET"))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var sha: String?, text: String?
            if code == 200 {
                let c = try JSONDecoder().decode(Current.self, from: data)
                sha = c.sha
                text = Data(base64Encoded: c.content.replacingOccurrences(of: "\n", with: "")).map { String(decoding: $0, as: UTF8.self) }
            } else if code != 404 {
                throw Failure.http(code, path)
            }
            guard let new = edit(text), new != text else { return }
            var put = request("PUT")
            var body: [String: String] = ["message": message, "content": Data(new.utf8).base64EncodedString()]
            if let sha { body["sha"] = sha }
            put.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, r) = try await URLSession.shared.data(for: put)
            switch (r as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200, 201: return
            case 403: throw Failure.readOnly
            case 409 where attempt == 1: continue   // the file moved under us
            case let c: throw Failure.http(c, path)
            }
        }
    }

    // MARK: away.yml — `- {start: 2026-10-23, end: 2026-10-23, except: [a, b]}  # note`

    static func parseAway(_ yaml: String) -> [AwayRange] {
        var result: [AwayRange] = []
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
            for (k, v) in FlowMapping.fields(inner) {
                switch k {
                case "start": start = v
                case "end": end = v
                case "except": except = FlowMapping.list(v)
                default: break
                }
            }
            if let s = start, let e = end, isDay(s), isDay(e) {
                result.append(AwayRange(start: s, end: e, except: except.isEmpty ? nil : except, note: note))
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
#endif
