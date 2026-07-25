import SwiftUI

/// LAB — Session spike for the standalone-app proposal (#59).
///
/// Answers, on real hardware, the question the proposal now hinges on:
/// **can the app log in and re-login without a user present?**
///
/// Nothing here books anything. Every call is a read (`occurrences` GET), so it
/// cannot affect real reservations — GitHub Actions stays the booking engine
/// until the port is proven.
struct LabView: View {
    @StateObject private var login = LabLoginController()

    @State private var username = GymCredentialStore.username ?? ""
    @State private var password = ""
    @State private var session: StoredSession? = GymCredentialStore.session
    @State private var showWebLogin = false
    @State private var busy = false
    @State private var results: [String] = []

    var body: some View {
        NavigationStack {
            List {
                statusSection
                credentialsSection
                actionsSection
                if !results.isEmpty { resultsSection }
                if !login.log.isEmpty { logSection }
            }
            .navigationTitle("Lab · Session")
            .navigationBarTitleDisplayMode(.inline)
            .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .sheet(isPresented: $showWebLogin) {
                NavigationStack {
                    LabLoginWebView(controller: login)
                        .navigationTitle("Sign in to YMCA")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { login.cancel(); showWebLogin = false }
                            }
                        }
                }
            }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section("Status") {
            if let s = session {
                Label("Session stored", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.booked)
                LabeledContent("Age", value: String(format: "%.1f h", s.ageHours))
                LabeledContent("Cookies", value: "\(s.cookies.count)")
                LabeledContent("CSRF", value: s.csrf.isEmpty ? "—" : "present")
            } else {
                Label("No session", systemImage: "xmark.seal")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Credentials",
                           value: GymCredentialStore.hasCredentials ? "in Keychain" : "not saved")
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField("YMCA / egym email", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
            SecureField("Password", text: $password)
            Button("Save to Keychain") {
                GymCredentialStore.saveCredentials(username: username, password: password)
                password = ""
                results.insert("Credentials saved (AfterFirstUnlockThisDeviceOnly).", at: 0)
            }
            .disabled(username.isEmpty || password.isEmpty)
        } header: {
            Text("1 · Credentials")
        } footer: {
            Text("This is the primary path. Saving your login lets the app sign itself in unattended — the only way a 9:45am booking works with the phone locked and nobody to type anything.\n\nStored only in this device's Keychain: never synced to iCloud, never in a backup, never sent anywhere but egym's own login page.")
        }
    }

    private var actionsSection: some View {
        Group {
            Section {
                Button {
                    runScriptedLogin()
                } label: {
                    Label("Silent sign-in", systemImage: "bolt.badge.clock")
                }
                .disabled(!GymCredentialStore.hasCredentials)

                Button {
                    testCookie()
                } label: {
                    Label("Test stored session", systemImage: "stethoscope")
                }
                .disabled(session == nil)
            } header: {
                Text("2 · The real path")
            } footer: {
                Text("Silent sign-in is exactly what runs unattended: no UI, no typing — the saved credentials are submitted to egym's form and the session is harvested. If this works, an expired cookie stops mattering.\n\nTest stored session replays the cookie over a plain URLSession, which is also how we measure how long a session survives.")
            }

            Section {
                Button {
                    runInteractiveLogin()
                } label: {
                    Label("Manual sign-in (type on egym's page)", systemImage: "person.badge.key")
                }

                Button(role: .destructive) {
                    GymCredentialStore.clearAll()
                    session = nil; username = ""; password = ""
                    results.insert("Cleared credentials + session.", at: 0)
                } label: {
                    Label("Clear everything", systemImage: "trash")
                }
            } header: {
                Text("3 · Fallback")
            } footer: {
                Text("Only needed when silent sign-in can't work — an MFA/CAPTCHA step, or egym changing their form so the injection breaks. It's also the control test: it proves cookie harvesting works independently of the scripted path.\n\nEverything on this screen is read-only — occurrences GETs only. Nothing here books or cancels a class.")
            }
        }
    }

    private var resultsSection: some View {
        Section("Results") {
            ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                Text(r).font(.callout.monospaced())
            }
        }
    }

    private var logSection: some View {
        Section("Login trace") {
            ForEach(Array(login.log.enumerated()), id: \.offset) { _, l in
                Text(l).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private func runInteractiveLogin() {
        showWebLogin = true
        Task {
            do {
                let s = try await login.start(mode: .interactive, timeout: 300)
                GymCredentialStore.saveSession(s)
                session = s
                showWebLogin = false
                results.insert("✅ Interactive login OK — \(s.cookies.count) cookies, csrf captured.", at: 0)
                await verify(s, label: "post-login")
            } catch {
                showWebLogin = false
                results.insert("❌ Interactive login failed: \(error.localizedDescription)", at: 0)
            }
        }
    }

    /// The load-bearing spike: log in with NO user interaction.
    private func runScriptedLogin() {
        guard let u = GymCredentialStore.username, let p = GymCredentialStore.password else { return }
        busy = true
        Task {
            let t0 = Date()
            do {
                let s = try await login.start(mode: .scripted(username: u, password: p), timeout: 120)
                GymCredentialStore.saveSession(s)
                session = s
                let secs = Date().timeIntervalSince(t0)
                results.insert(String(format: "✅ SILENT re-login OK in %.1fs — %d cookies. Unattended path viable.",
                                      secs, s.cookies.count), at: 0)
                await verify(s, label: "post-silent-login")
            } catch {
                results.insert("❌ Silent re-login failed: \(error.localizedDescription)", at: 0)
            }
            busy = false
        }
    }

    private func testCookie() {
        guard let s = session else { return }
        busy = true
        Task {
            await verify(s, label: "cookie test")
            busy = false
        }
    }

    private func verify(_ s: StoredSession, label: String) async {
        switch await YmcaSessionClient.validate(s) {
        case .ok(let n, let ms):
            results.insert(String(format: "✅ %@: session ALIVE at %.1fh — %d occurrences in %dms",
                                  label, s.ageHours, n, ms), at: 0)
        case .expired(let status):
            results.insert(String(format: "⚠️ %@: session EXPIRED at %.1fh (HTTP %d) — silent re-login needed",
                                  label, s.ageHours, status), at: 0)
        case .failed(let why):
            results.insert("❌ \(label): \(why)", at: 0)
        }
    }
}
