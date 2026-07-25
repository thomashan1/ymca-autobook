import Foundation

/// LAB — authenticated Fisikal calls over a plain `URLSession`, replaying a
/// stored cookie. No browser involved.
///
/// The Python spike already proved this shape works (bare cookie + CSRF header
/// on stdlib HTTP returned 200 / 80 occurrences), so this is the on-device
/// equivalent of that result.
enum YmcaSessionClient {

    enum Outcome {
        case ok(occurrences: Int, elapsedMs: Int)
        case expired(status: Int)          // 401, or a 3xx bounce back to SSO
        case failed(String)

        var isOK: Bool { if case .ok = self { return true }; return false }
    }

    /// Cheap authenticated read used as the liveness check for a stored session.
    static func validate(_ session: StoredSession) async -> Outcome {
        let since = Date()
        let till = since.addingTimeInterval(2 * 24 * 3600)
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"

        let filter: [String: Any] = ["filter": [
            ["by": "status", "with": LabConfig.listStatuses],
            ["by": "since", "with": iso.string(from: since)],
            ["by": "till", "with": iso.string(from: till)],
            ["by": "location_id", "with": LabConfig.locationIds],
        ]]
        guard let json = try? JSONSerialization.data(withJSONObject: filter),
              let jsonStr = String(data: json, encoding: .utf8) else {
            return .failed("could not build filter")
        }

        var comps = URLComponents(url: LabConfig.occurrencesURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "json", value: jsonStr),
            .init(name: "all_service_categories", value: "true"),
        ]
        guard let url = comps.url else { return .failed("bad URL") }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(session.csrf, forHTTPHeaderField: "x-csrf-token")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
        req.setValue("*/*", forHTTPHeaderField: "accept")
        req.setValue(LabConfig.fisikalBase.absoluteString + "/", forHTTPHeaderField: "referer")
        req.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 30

        // Don't follow redirects: a bounce back to SSO *is* the expiry signal.
        let delegate = NoRedirect()
        let urlSession = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { urlSession.finishTasksAndInvalidate() }

        let t0 = Date()
        do {
            let (data, response) = try await urlSession.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ms = Int(Date().timeIntervalSince(t0) * 1000)

            if status == 401 || (300...399).contains(status) { return .expired(status: status) }
            guard status == 200 else { return .failed("HTTP \(status)") }

            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = obj["data"] as? [[String: Any]] else {
                // HTML instead of JSON almost always means a login page.
                return .expired(status: status)
            }
            return .ok(occurrences: rows.count, elapsedMs: ms)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}
