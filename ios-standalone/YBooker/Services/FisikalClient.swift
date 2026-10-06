import Foundation

/// egym SSO -> Fisikal session over plain HTTP (no WebView), plus read-only calls.
/// Port of spikes/http_login.py. Slice 1 never joins or cancels anything.
actor FisikalClient {
    static let shared = FisikalClient()

    static let clientId = "silicon-valley-ymca-2b6f1d9d-5696-4fc7-a96c-bfc8051c32d1"
    static let fisikal = URL(string: "https://ymca-silicon-valley.fisikal.com")!
    static let callback = "https://ymca-silicon-valley.fisikal.com/egym_login"
    static let egymLogin = URL(string: "https://id.egym.com/login")!

    enum Failure: LocalizedError {
        case rejected(String), noRedirect, noCSRF, sessionExpired, noCredentials, http(Int)
        var errorDescription: String? {
            switch self {
            case .rejected(let why): return "egym rejected the login: \(why)"
            case .noRedirect: return "egym didn't return a redirect to the YMCA"
            case .noCSRF: return "Reached the YMCA but found no CSRF token"
            case .sessionExpired: return "Session expired"
            case .noCredentials: return "Not signed in"
            case .http(let code): return "HTTP \(code)"
            }
        }
    }

    enum SessionPath: String, Codable { case reused, relogin, reloginSkippedQuietWindow }

    private let cookies: HTTPCookieStorage
    private let session: URLSession
    private var csrf: String?

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        // Use the ephemeral config's own in-memory store: a bare HTTPCookieStorage()
        // silently keeps nothing, and Fisikal answers a cookieless API call with a 500.
        cookies = cfg.httpCookieStorage!
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
        restoreSession()
    }

    // MARK: Credentials

    static var hasCredentials: Bool { Keychain.string("egym.username") != nil }

    func signIn(username: String, password: String) async throws -> [Occurrence] {
        try await login(username: username, password: password)
        Keychain.setString(username, for: "egym.username")
        Keychain.setString(password, for: "egym.password")
        return try await listOccurrences()
    }

    func signOut() {
        for k in ["egym.username", "egym.password", "fisikal.session"] { Keychain.delete(k) }
        cookies.cookies?.forEach(cookies.deleteCookie)
        csrf = nil
    }

    // MARK: Session

    /// Reuse the stored session; if it's dead, silently log in again — except in
    /// the weekday booking window, where a fresh login might evict a GitHub
    /// Actions run that's mid-wait (if Fisikal is single-session per account).
    func occurrencesEnsuringSession(allowReloginInQuietWindow: Bool) async throws
        -> (occurrences: [Occurrence], path: SessionPath) {
        if csrf != nil, let occs = try? await listOccurrences() {
            return (occs, .reused)
        }
        if !allowReloginInQuietWindow, QuietWindow.isNow() {
            return ([], .reloginSkippedQuietWindow)
        }
        guard let u = Keychain.string("egym.username"), let p = Keychain.string("egym.password")
        else { throw Failure.noCredentials }
        try await login(username: u, password: p)
        return (try await listOccurrences(), .relogin)
    }

    private func login(username: String, password: String) async throws {
        cookies.cookies?.forEach(cookies.deleteCookie)
        var page = URLComponents(url: Self.egymLogin, resolvingAgainstBaseURL: false)!
        page.queryItems = [.init(name: "clientId", value: Self.clientId),
                           .init(name: "callbackUrl", value: Self.callback)]
        _ = try await session.data(from: page.url!)

        var post = URLRequest(url: Self.egymLogin)
        post.httpMethod = "POST"
        post.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        post.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        post.setValue("https://id.egym.com", forHTTPHeaderField: "Origin")
        post.setValue(page.url!.absoluteString, forHTTPHeaderField: "Referer")
        post.httpBody = Self.formEncode([("username", username), ("password", password),
                                         ("clientId", Self.clientId), ("callbackUrl", Self.callback)])
        let (body, resp) = try await session.data(for: post)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            throw Failure.rejected(json?["errorReason"] as? String
                                   ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let redirect = String(decoding: body, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        guard let url = URL(string: redirect), url.host == Self.fisikal.host else { throw Failure.noRedirect }

        var (html, final) = try await session.data(from: url)   // sets fisikal_v2_session, 302s to /
        var token = Self.csrfToken(in: html)
        if token == nil {
            (html, final) = try await session.data(from: Self.fisikal)
            token = Self.csrfToken(in: html)
        }
        guard final.url?.host == Self.fisikal.host, let token else { throw Failure.noCSRF }
        csrf = token
        persistSession()
    }

    // MARK: Read-only API

    func listOccurrences(days: Int = 16) async throws -> [Occurrence] {
        guard let csrf else { throw Failure.sessionExpired }
        let fmt = ISO8601DateFormatter()
        let now = Date()
        let filter: [String: Any] = ["filter": [
            ["by": "status", "with": ["Rescheduled", "Scheduled", "Reminded", "Completed",
                                      "Requested", "Counted", "Verified"]],
            ["by": "since", "with": fmt.string(from: now.addingTimeInterval(-2 * 3600))],
            ["by": "till", "with": fmt.string(from: now.addingTimeInterval(Double(days) * 86400))],
        ]]
        var comps = URLComponents(url: Self.fisikal.appendingPathComponent("api/web/schedule/occurrences"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "json", value: String(decoding: try JSONSerialization.data(withJSONObject: filter), as: UTF8.self)),
            .init(name: "all_service_categories", value: "true"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue(Self.fisikal.absoluteString + "/", forHTTPHeaderField: "Referer")
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        // A missing or dead session doesn't get a clean 401: Fisikal answers with an
        // HTML page — a login redirect, or a Rails "something went wrong" 500. So
        // anything that isn't JSON means "log in again"; only a JSON error is real.
        let isJSON = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json")
        guard let http, http.statusCode == 200, isJSON else {
            if isJSON, let code = http?.statusCode { throw Failure.http(code) }
            self.csrf = nil
            throw Failure.sessionExpired
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["data"] as? [[String: Any]] ?? []).compactMap(Occurrence.init)
    }

    // MARK: Persistence (session cookie + CSRF in the Keychain)

    private struct Stored: Codable { var csrf: String; var cookies: [[String: String]] }

    private func persistSession() {
        guard let csrf else { return }
        let fisikalCookies = (cookies.cookies ?? []).filter { $0.domain.contains("fisikal") }.map {
            ["name": $0.name, "value": $0.value, "domain": $0.domain, "path": $0.path]
        }
        if let data = try? JSONEncoder().encode(Stored(csrf: csrf, cookies: fisikalCookies)) {
            Keychain.set(data, for: "fisikal.session")
        }
    }

    private func restoreSession() {
        guard let data = Keychain.get("fisikal.session"),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        for c in stored.cookies {
            if let cookie = HTTPCookie(properties: [.name: c["name"] ?? "", .value: c["value"] ?? "",
                                                    .domain: c["domain"] ?? "", .path: c["path"] ?? "/"]) {
                cookies.setCookie(cookie)
            }
        }
        csrf = stored.csrf
    }

    // MARK: Helpers

    private static func csrfToken(in html: Data) -> String? {
        let s = String(decoding: html, as: UTF8.self)
        guard let r = s.range(of: #"<meta name="csrf-token" content="([^"]+)""#, options: .regularExpression)
        else { return nil }
        let match = String(s[r])
        return match.split(separator: "\"").dropFirst(3).first.map(String.init)
    }

    private static func formEncode(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return Data(pairs.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").utf8)
    }
}

/// Weekdays 9:00–13:30 PT, when GitHub Actions booking runs may be logged in and waiting.
enum QuietWindow {
    static func isNow(_ date: Date = Date()) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let c = cal.dateComponents([.weekday, .hour, .minute], from: date)
        guard let wd = c.weekday, (2...6).contains(wd), let h = c.hour, let m = c.minute else { return false }
        let mins = h * 60 + m
        return mins >= 9 * 60 && mins < 13 * 60 + 30
    }
}

struct Occurrence: Identifiable, Hashable {
    let id: Int
    let occursAt: Date
    let title: String
    let location: String
    let trainer: String
    let isJoined: Bool
    let isFull: Bool

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? Int, let at = d["occurs_at"] as? String,
              let date = ISO8601DateFormatter().date(from: at) else { return nil }
        self.id = id
        occursAt = date
        title = (d["service_title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        location = (d["sub_location_name"] as? String) ?? (d["location_name"] as? String) ?? ""
        trainer = d["trainer_name"] as? String ?? ""
        isJoined = d["is_joined"] as? Bool ?? false
        isFull = d["full_group"] as? Bool ?? false
    }
}
