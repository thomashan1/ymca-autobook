import SwiftUI

/// Sign-in + account + help screen. Paste a GitHub personal access token; it's
/// stored in the Keychain and used for every API call. Doubles as the
/// first-run onboarding sheet, and always shows how to create a token.
struct SettingsView: View {
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var pauses: PausesRepository

    /// When shown as the first-run sheet this is true; false when it's the tab.
    var onboarding: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""
    @State private var reloading = false
    @State private var authError: String?
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            Form {
                if !auth.hasToken {
                    tokenEntrySection
                } else {
                    connectionSection
                    diagnosticsSection
                }
                howToSection
            }
            .navigationTitle(onboarding ? "Connect" : "Settings")
        }
    }

    // MARK: Sections

    private var tokenEntrySection: some View {
        Section {
            SecureField("github_pat_… or ghp_…", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                connect()
            } label: {
                HStack {
                    Text("Save & connect")
                    if connecting { Spacer(); ProgressView() }
                }
            }
            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || connecting)
            if let authError {
                Text(authError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("GitHub token")
        } footer: {
            Text("Paste the token you created below. It's stored only in this device's Keychain — never sent anywhere but GitHub.")
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            Label("Connected to GitHub", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Theme.booked)
            Button {
                reload()
            } label: {
                HStack {
                    Text("Reload data")
                    if reloading { Spacer(); ProgressView() }
                }
            }
            .disabled(reloading)
            Button("Sign out", role: .destructive) {
                auth.signOut()
                classes.classes = []
                pauses.pauses = []
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            LabeledContent("Classes loaded", value: "\(classes.classes.count)")
            if let e = classes.error {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            LabeledContent("Pauses loaded", value: "\(pauses.pauses.count)")
            if let e = pauses.error {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var howToSection: some View {
        Section {
            step(1, "On github.com, open Settings → Developer settings → Personal access tokens → Fine-grained tokens.")
            step(2, "Tap “Generate new token”. Name it (e.g. “YMCA Autobook app”) and set an expiration.")
            step(3, "Resource owner: \(Config.owner).")
            step(4, "Repository access → Only select repositories → choose both \(Config.publicRepo) and \(Config.privateRepo).")
            step(5, "Permissions → Repository permissions, set: Contents = Read and write, Pull requests = Read and write, Actions = Read and write, Workflows = Read and write.")
            step(6, "Generate the token, copy it, and paste it into the field above.")
        } header: {
            Text("How to create a token")
        } footer: {
            Text("A fine-grained token limited to these two repos. If it ever leaks, revoke it on github.com and create a new one — nothing else is affected.")
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Theme.accent, in: Circle())
            Text(text).font(.callout)
        }
    }

    // MARK: Actions

    private func connect() {
        let entered = token
        connecting = true
        authError = nil
        auth.save(token: entered)
        Task {
            if let reason = await GitHubClient().validateToken() {
                authError = reason
                auth.signOut()          // don't leave a bad token claiming "connected"
                connecting = false
                return
            }
            token = ""
            await classes.load()
            await pauses.load()
            connecting = false
            if onboarding { dismiss() }
        }
    }

    private func reload() {
        reloading = true
        Task {
            await classes.load()
            await pauses.load()
            reloading = false
        }
    }
}
