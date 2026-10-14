import Foundation

/// egym SSO -> Fisikal session over plain HTTP (no browser), plus schedule reads and joins.
actor FisikalClient {
    static let shared = FisikalClient()

    static let clientId = "silicon-valley-ymca-2b6f1d9d-5696-4fc7-a96c-bfc8051c32d1"
    static let fisikal = URL(string: "https://ymca-silicon-valley.fisikal.com")!
    static let callback = "https://ymca-silicon-valley.fisikal.com/egym_login"
    static let egymLogin = URL(string: "https://id.egym.com/login")!
    static let zone = TimeZone(identifier: "America/Los_Angeles")!

    enum Failure: LocalizedError {
        case rejected(String), noRedirect, noCSRF, sessionExpired, noCredentials, http(Int)
        var errorDescription: String? {
            switch self {
            case .rejected(let why): return "egym rejected the login: \(why)"
            case .noRedirect: return "egym didn't return a redirect to the YMCA"
            case .noCSRF: return "Reached the YMCA but found no CSRF token"
            case .sessionExpired: return "Session expired"
            case .noCredentials: return "Not signed in"
            case .http(let code): return "YMCA server returned HTTP \(code)"
            }
        }
    }

    enum SessionPath: String, Codable { case reused, relogin }

    private let cookies: HTTPCookieStorage
    private let session: URLSession
    private var csrf: String?

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        // The ephemeral config's own in-memory store: a bare HTTPCookieStorage()
        // keeps nothing, and Fisikal answers a cookieless API call with a 500.
        cookies = cfg.httpCookieStorage!
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
        if let data = Keychain.get("fisikal.session"),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            for c in stored.cookies {
                if let cookie = HTTPCookie(properties: [.name: c["name"] ?? "", .value: c["value"] ?? "",
                                                        .domain: c["domain"] ?? "", .path: c["path"] ?? "/"]) {
                    cookies.setCookie(cookie)
                }
            }
            csrf = stored.csrf
        }
    }

    // MARK: Account

    static var username: String? { Keychain.string("egym.username") }

    func signIn(username: String, password: String) async throws {
        try await login(username: username, password: password)
        _ = try await occurrences(locationIds: [1392], since: Date(), till: Date().addingTimeInterval(3600))
        Keychain.setString(username, for: "egym.username")
        Keychain.setString(password, for: "egym.password")
    }

    func signOut() {
        for k in ["egym.username", "egym.password", "fisikal.session"] { Keychain.delete(k) }
        cookies.cookies?.forEach(cookies.deleteCookie)
        csrf = nil
    }

    /// Reuse the stored session if it still works; otherwise log in again silently.
    func ensureSession() async throws -> SessionPath {
        if csrf != nil {
            do {
                _ = try await occurrences(locationIds: [1392], since: Date(), till: Date().addingTimeInterval(60))
                return .reused
            } catch Failure.sessionExpired {}
        }
        guard let u = Keychain.string("egym.username"), let p = Keychain.string("egym.password")
        else { throw Failure.noCredentials }
        try await login(username: u, password: p)
        return .relogin
    }

    // MARK: Read-only API

    func occurrences(locationIds: [Int], since: Date, till: Date) async throws -> [Occurrence] {
        guard let csrf else { throw Failure.sessionExpired }
        let fmt = ISO8601DateFormatter()
        let filter: [String: Any] = ["filter": [
            ["by": "status", "with": ["Rescheduled", "Scheduled", "Reminded", "Completed",
                                      "Requested", "Counted", "Verified"]],
            ["by": "since", "with": fmt.string(from: since)],
            ["by": "till", "with": fmt.string(from: till)],
            ["by": "location_id", "with": locationIds],
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
        // A missing/dead session gets an HTML page (login redirect or a Rails 500),
        // never a clean 401 — so non-JSON means "log in again". A JSON error,
        // or the 503 "heavy load" page, is a real server problem.
        let isJSON = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json")
        guard let http, http.statusCode == 200, isJSON else {
            if let code = http?.statusCode, isJSON || code == 503 { throw Failure.http(code) }
            self.csrf = nil
            throw Failure.sessionExpired
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["data"] as? [[String: Any]] ?? []).compactMap(Occurrence.init)
    }

    // MARK: Booking (the only write the app ever makes; there is no cancel)

    struct JoinResult: Sendable {
        let ok: Bool
        let errorTypes: [String]
        let message: String
        let sentAt: Date
        let repliedAt: Date
    }

    /// POST .../occurrences/{id}/join with form `json={"lock_version":N}` — the same
    /// request the Python engine (src/fisikal.py) has been booking with all along.
    func join(occurrenceId: Int, lockVersion: Int) async throws -> JoinResult {
        guard let csrf else { throw Failure.sessionExpired }
        var req = URLRequest(url: Self.fisikal.appendingPathComponent("api/web/schedule/occurrences/\(occurrenceId)/join"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue(Self.fisikal.absoluteString + "/", forHTTPHeaderField: "Referer")
        req.httpBody = Self.formEncode([("json", #"{"lock_version": \#(lockVersion)}"#)])
        let sent = Date()
        let (data, resp) = try await session.data(for: req)
        let replied = Date()
        let http = resp as? HTTPURLResponse
        guard (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json") else {
            if let code = http?.statusCode, code == 503 { throw Failure.http(code) }
            self.csrf = nil
            throw Failure.sessionExpired
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let oc = body?["occurrence_client"] as? [String: Any]
        let errors = (oc?["errors"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
        let ok = (200..<300).contains(http?.statusCode ?? 0) && errors.isEmpty
        let message = ok ? "booked (occurrence_client id=\(oc?["id"] ?? "?"))"
                         : (errors.isEmpty ? "HTTP \(http?.statusCode ?? 0)" : errors.joined(separator: ", "))
        return JoinResult(ok: ok, errorTypes: errors, message: message, sentAt: sent, repliedAt: replied)
    }

    // MARK: Login

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
        let fisikalCookies = (cookies.cookies ?? []).filter { $0.domain.contains("fisikal") }.map {
            ["name": $0.name, "value": $0.value, "domain": $0.domain, "path": $0.path]
        }
        if let data = try? JSONEncoder().encode(Stored(csrf: token, cookies: fisikalCookies)) {
            Keychain.set(data, for: "fisikal.session")
        }
    }

    private struct Stored: Codable { var csrf: String; var cookies: [[String: String]] }

    private static func csrfToken(in html: Data) -> String? {
        let s = String(decoding: html, as: UTF8.self)
        guard let r = s.range(of: #"<meta name="csrf-token" content="([^"]+)""#, options: .regularExpression)
        else { return nil }
        return String(s[r]).split(separator: "\"").dropFirst(3).first.map(String.init)
    }

    private static func formEncode(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return Data(pairs.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").utf8)
    }
}

/// One scheduled session of a class, as Fisikal reports it.
struct Occurrence: Identifiable, Hashable, Sendable {
    let id: Int
    let occursAt: Date
    /// When booking opens: occurs_at minus the club's own book-in-advance setting (167h here).
    let openAt: Date
    let title: String
    let location: String
    let room: String
    let trainer: String
    let isJoined: Bool
    let isFull: Bool
    let fullGroupAt: Date?
    let lockVersion: Int
    let capacity: Int
    let waitlist: Int
    let durationMinutes: Int

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? Int, let at = (d["occurs_at"] as? String).flatMap(FisikalDate.parse)
        else { return nil }
        self.id = id
        occursAt = at
        let hours = d["restrict_to_book_in_advance_time_in_hours"] as? Int ?? 0
        let minutes = d["restrict_to_book_in_advance_time_in_minutes"] as? Int ?? 0
        openAt = at.addingTimeInterval(-Double(hours * 3600 + minutes * 60))
        title = (d["service_title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        location = (d["location_name"] as? String ?? "").replacingOccurrences(of: " YMCA", with: "")
        room = d["sub_location_name"] as? String ?? ""
        trainer = (d["trainer_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        isJoined = d["is_joined"] as? Bool ?? false
        isFull = d["full_group"] as? Bool ?? false
        fullGroupAt = (d["full_group_at"] as? String).flatMap(FisikalDate.parse)
        lockVersion = d["lock_version"] as? Int ?? 0
        capacity = d["service_group_size"] as? Int ?? 0
        waitlist = d["total_on_waiting_list"] as? Int ?? 0
        durationMinutes = (d["duration_in_hours"] as? Int ?? 0) * 60 + (d["duration_in_minutes"] as? Int ?? 0)
    }
}

enum FisikalDate {
    private static let plain = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func parse(_ s: String) -> Date? { plain.date(from: s) ?? fractional.date(from: s) }
}
