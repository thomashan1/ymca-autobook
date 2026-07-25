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
    @State private var editingCredentials = false

    /// Persisted, because this is measured across days: view state would wipe
    /// the log on every relaunch while the session itself survives in the
    /// Keychain, leaving a stored session with no record of where it came from.
    @State private var results: [String] = LabResultLog.load()

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
            if session != nil {
                Button {
                    testCookie()
                } label: {
                    Label("Check session again", systemImage: "stethoscope")
                }
            }
        }
    }

    /// Deliberately loud: the user is being asked to hand over a real password,
    /// so the guarantees should be impossible to miss rather than footer text.
    private var privacyCallout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("🔒").font(.title3)
                Text("Stored ONLY on this device")
                    .font(.subheadline.weight(.heavy))
            }
            VStack(alignment: .leading, spacing: 6) {
                neverRow("NEVER sent to us or any server we run")
                neverRow("NEVER synced to iCloud or another device")
                neverRow("NEVER included in a backup")
            }
            Text("The only place it is ever sent is egym's own login page — the same page you'd type it into yourself.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("To remove it, use Clear everything below. Deleting the app is not a reliable way to erase it — Keychain items have been observed surviving a reinstall.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .listRowBackground(Theme.booked.opacity(0.10))
    }

    private func neverRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("🚫").font(.caption)
            Text(text)
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var credentialsSection: some View {
        Section {
            privacyCallout

            if GymCredentialStore.hasCredentials && !editingCredentials {
                // Saved state — otherwise clearing the password field on save
                // just looks like the save failed.
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.booked)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(GymCredentialStore.username ?? "—").font(.body.weight(.medium))
                        Text("Password saved in Keychain")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Update credentials") {
                    username = GymCredentialStore.username ?? ""
                    password = ""
                    editingCredentials = true
                }
            } else {
                TextField("YMCA / egym email", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                SecureField("Password", text: $password)
                Button("Save & sign in") {
                    GymCredentialStore.saveCredentials(username: username, password: password)
                    password = ""              // don't keep plaintext in view state
                    editingCredentials = false
                    record("✅ Saved for \(username). The password is in the Keychain, not shown again.")
                    runScriptedLogin()         // no dead end — prove it works right away
                }
                .disabled(username.isEmpty || password.isEmpty)
                if GymCredentialStore.hasCredentials {
                    Button("Cancel", role: .cancel) {
                        password = ""
                        editingCredentials = false
                    }
                }
            }
        } header: {
            Text("Sign in")
        } footer: {
            Text("This is the primary path. Booking opens at a fixed moment each week — usually while your phone is locked in your pocket and nobody is around to type anything. Saving your login is what lets the app sign itself in at that moment.\n\nKept in the device Keychain (AfterFirstUnlock, ThisDeviceOnly) and intentionally not displayed again after saving.")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                runInteractiveLogin()
            } label: {
                Label("Sign in manually instead", systemImage: "person.badge.key")
            }

            Button(role: .destructive) {
                GymCredentialStore.clearAll()
                session = nil; username = ""; password = ""
                record("Cleared credentials + session.")
            } label: {
                Label("Clear everything", systemImage: "trash")
            }
        } footer: {
            Text("Sign in manually only if the automatic sign-in fails — a CAPTCHA, or egym changing their form. Clear everything removes the saved password and session from the Keychain.\n\nNothing on this screen books or cancels a class.")
        }
    }

    private var resultsSection: some View {
        Section {
            ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                Text(r).font(.callout.monospaced())
            }
        } header: {
            HStack {
                Text("Results")
                Spacer()
                Button("Clear") { results = []; LabResultLog.save([]) }
                    .font(.caption)
            }
        } footer: {
            Text("Kept across relaunches — each entry is stamped with the session's age, so re-checking over several days shows how long a session lasts.")
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

    /// Single write path for results so every line is timestamped and persisted.
    private func record(_ line: String) {
        results = LabResultLog.append(line, to: results)
    }

    private func runInteractiveLogin() {
        showWebLogin = true
        Task {
            do {
                let s = try await login.start(mode: .interactive, timeout: 300)
                GymCredentialStore.saveSession(s)
                session = s
                showWebLogin = false
                record("✅ Interactive login OK — \(s.cookies.count) cookies, csrf captured.")
                await verify(s, label: "post-login")
            } catch {
                showWebLogin = false
                record("❌ Interactive login failed: \(error.localizedDescription)")
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
                record(String(format: "✅ SILENT re-login OK in %.1fs — %d cookies. Unattended path viable.",
                                      secs, s.cookies.count))
                await verify(s, label: "post-silent-login")
            } catch {
                record("❌ Silent re-login failed: \(error.localizedDescription)")
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
            record(String(format: "✅ %@: session ALIVE at %.1fh — %d occurrences in %dms",
                                  label, s.ageHours, n, ms))
        case .expired(let status):
            record(String(format: "⚠️ %@: session EXPIRED at %.1fh (HTTP %d) — silent re-login needed",
                                  label, s.ageHours, status))
        case .failed(let why):
            record("❌ \(label): \(why)")
        }
    }
}
