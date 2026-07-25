import Foundation

/// LAB — P0 spike scaffolding for the standalone-app proposal (#59).
///
/// Everything under `Lab/` is additive and self-contained: nothing outside this
/// directory imports it, and it never mutates the shipped app's state. The
/// GitHub Actions bot remains the real booking engine while this is validated.
///
/// Gym constants are duplicated here (rather than added to `Config`) to keep the
/// isolation rule intact — the shipped files stay untouched. When the engine
/// graduates, these move into a proper multi-gym directory (#59 §6).
enum LabConfig {
    static let clientId = "silicon-valley-ymca-2b6f1d9d-5696-4fc7-a96c-bfc8051c32d1"
    static let fisikalBase = URL(string: "https://ymca-silicon-valley.fisikal.com")!
    static var fisikalHost: String { fisikalBase.host ?? "" }

    static var callbackURL: String { fisikalBase.appendingPathComponent("egym_login").absoluteString }

    /// The egym SSO entry point — the same URL `src/login.py` drives.
    static var loginURL: URL {
        var c = URLComponents(string: "https://id.egym.com/login")!
        c.queryItems = [
            .init(name: "clientId", value: clientId),
            .init(name: "callbackUrl", value: callbackURL),
        ]
        return c.url!
    }

    static let occurrencesURL = URL(string: "https://ymca-silicon-valley.fisikal.com/api/web/schedule/occurrences")!

    /// Statuses the web UI requests when listing the schedule (mirrors fisikal.py).
    static let listStatuses = ["Rescheduled", "Scheduled", "Reminded", "Completed",
                               "Requested", "Counted", "Verified"]

    static let locationIds = [1392, 1388]   // Southwest, Northwest
}
