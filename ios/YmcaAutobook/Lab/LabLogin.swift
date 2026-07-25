import Foundation
import SwiftUI
import WebKit

/// LAB — egym SSO login in a `WKWebView`, harvesting the Fisikal session.
///
/// Two modes, and the difference is the whole point of the spike:
///
/// - `.interactive` — the user types into **egym's real page**. Nothing of ours
///   touches the password.
/// - `.scripted` — no user present: fill + submit via injected JS using the
///   Keychain credentials. This is what an unattended 9:45am re-login must do
///   when the stored cookie has expired, and whether it works is the
///   load-bearing unknown for the standalone proposal (#59).
///
/// Mirrors the flow `src/login.py` drives with Playwright: id.egym.com form →
/// egym mints a JWT → redirect to fisikal.com/egym_login?token=… → Fisikal sets
/// its session cookie → read `<meta name="csrf-token">`.
@MainActor
final class LabLoginController: NSObject, ObservableObject {

    enum Mode {
        case interactive
        case scripted(username: String, password: String)
    }

    @Published var log: [String] = []
    @Published var isRunning = false

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<StoredSession, Error>?
    private var pollTimer: Timer?
    private var deadline: Date = .distantFuture
    private var mode: Mode = .interactive
    private var finished = false

    enum LoginError: LocalizedError {
        case timedOut(String)
        case noCSRF
        case cancelled
        var errorDescription: String? {
            switch self {
            case .timedOut(let where_): return "Timed out (last at: \(where_))"
            case .noCSRF: return "Reached Fisikal but found no csrf-token meta tag"
            case .cancelled: return "Cancelled"
            }
        }
    }

    private func note(_ s: String) {
        let t = DateFormatter()
        t.dateFormat = "HH:mm:ss"
        log.append("[\(t.string(from: Date()))] \(s)")
    }

    /// Build (or reuse) the web view. For `.scripted` it is never shown.
    func makeWebView() -> WKWebView {
        if let webView { return webView }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // persistent, so cookies survive
        let wv = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 700), configuration: cfg)
        wv.navigationDelegate = self
        webView = wv
        return wv
    }

    func start(mode: Mode, timeout: TimeInterval = 90) async throws -> StoredSession {
        self.mode = mode
        self.finished = false
        self.isRunning = true
        self.deadline = Date().addingTimeInterval(timeout)
        log.removeAll()

        switch mode {
        case .interactive: note("Interactive login — sign in on egym's page.")
        case .scripted:    note("Scripted login — no user interaction (unattended path).")
        }

        let wv = makeWebView()
        wv.load(URLRequest(url: LabConfig.loginURL))
        note("Loading \(LabConfig.loginURL.host ?? "")…")

        startPolling()

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
        }
    }

    func cancel() {
        finish(.failure(LoginError.cancelled))
    }

    private func startPolling() {
        pollTimer?.invalidate()
        // The SPA advances without full navigations, so poll rather than relying
        // only on didFinish.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard !finished, let wv = webView else { return }
        if Date() > deadline {
            finish(.failure(LoginError.timedOut(wv.url?.absoluteString ?? "unknown")))
            return
        }
        if let host = wv.url?.host, host.contains(LabConfig.fisikalHost) {
            harvest(from: wv)
            return
        }
        if case .scripted(let u, let p) = mode {
            advanceForm(wv, username: u, password: p)
        }
    }

    /// Fill whichever step of egym's form is currently showing and submit it.
    /// Handles both single-step and email-first two-step layouts, and sets values
    /// through the native setter so React-style SPAs actually register them.
    private func advanceForm(_ wv: WKWebView, username: String, password: String) {
        let js = """
        (function(){
          function setVal(el, v){
            try {
              var d = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
              if (d && d.set) { d.set.call(el, v); } else { el.value = v; }
            } catch(e) { el.value = v; }
            el.dispatchEvent(new Event('input',  {bubbles:true}));
            el.dispatchEvent(new Event('change', {bubbles:true}));
          }
          function visible(el){ return el && el.offsetParent !== null; }
          var u = document.querySelector("input[type=email], input[name=username], input[name=email], input#username");
          var p = document.querySelector("input[type=password], input[name=password], input#password");
          var btn = document.querySelector("button[type=submit]");
          if (!btn) {
            var all = Array.prototype.slice.call(document.querySelectorAll("button, input[type=submit]"));
            btn = all.filter(function(b){
              var t = (b.innerText || b.value || "").toLowerCase();
              return /log in|login|sign in|continue|next/.test(t);
            })[0];
          }
          if (visible(p) && !p.value) { setVal(p, %@); if (btn) btn.click(); return "filled-password"; }
          if (visible(u) && !u.value) { setVal(u, %@); if (!visible(p) && btn) btn.click(); return "filled-username"; }
          if (visible(u) && u.value && !visible(p) && btn) { btn.click(); return "advance"; }
          if (visible(p) && p.value && btn) { btn.click(); return "submit"; }
          return "waiting";
        })()
        """
        func jsQuote(_ s: String) -> String {
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        let script = String(format: js, jsQuote(password), jsQuote(username))

        wv.evaluateJavaScript(script) { [weak self] result, _ in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                if let s = result as? String, s != "waiting",
                   self.log.last?.hasSuffix(s) != true {
                    self.note("form: \(s)")
                }
            }
        }
    }

    /// On Fisikal: read the CSRF meta tag and copy cookies out of the web view.
    private func harvest(from wv: WKWebView) {
        guard !finished else { return }
        finished = true      // stop the poll from re-entering
        note("Reached \(wv.url?.host ?? "fisikal") — harvesting session…")

        wv.evaluateJavaScript("document.querySelector('meta[name=csrf-token]')?.getAttribute('content') || ''") { [weak self] value, _ in
            Task { @MainActor in
                guard let self else { return }
                let csrf = (value as? String) ?? ""
                guard !csrf.isEmpty else {
                    self.finished = false
                    // The redirect may still be settling; let the poll retry.
                    self.note("no csrf yet, retrying…")
                    return
                }
                let store = wv.configuration.websiteDataStore.httpCookieStore
                store.getAllCookies { cookies in
                    Task { @MainActor in
                        let mapped = cookies.map {
                            StoredSession.Cookie(name: $0.name, value: $0.value, domain: $0.domain)
                        }
                        let session = StoredSession(cookies: mapped, csrf: csrf, capturedAt: Date())
                        self.note("harvested \(mapped.count) cookies + csrf")
                        self.finish(.success(session))
                    }
                }
            }
        }
    }

    private func finish(_ result: Result<StoredSession, Error>) {
        guard continuation != nil else { return }
        finished = true
        pollTimer?.invalidate(); pollTimer = nil
        isRunning = false
        let c = continuation
        continuation = nil
        switch result {
        case .success(let s): c?.resume(returning: s)
        case .failure(let e): c?.resume(throwing: e)
        }
    }
}

extension LabLoginController: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.note("loaded: \(webView.url?.host ?? "?")\(webView.url?.path ?? "")")
            self.tick()
        }
    }
}

/// Shows the login web view (interactive mode only).
struct LabLoginWebView: UIViewRepresentable {
    let controller: LabLoginController
    func makeUIView(context: Context) -> WKWebView { controller.makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
