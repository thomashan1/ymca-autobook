import SwiftUI

/// Sign-in + account screen. Paste a GitHub personal access token; it's stored
/// in the Keychain and used for every API call. Doubles as the first-run
/// onboarding sheet.
struct SettingsView: View {
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var pauses: PausesRepository

    /// When shown as the first-run sheet this is set; nil when it's the tab.
    var onboarding: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                if !auth.hasToken {
                    Section {
                        SecureField("ghp_… or github_pat_…", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save & connect") { connect() }
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    } header: {
                        Text("GitHub token")
                    } footer: {
                        Text("A fine-grained token with Contents (read/write) on \(Config.owner)/\(Config.publicRepo) and \(Config.owner)/\(Config.privateRepo), plus Actions (read) and Workflows (write). Create one at github.com → Settings → Developer settings → Fine-grained tokens.")
                    }
                } else {
                    Section {
                        Label("Connected to GitHub", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.booked)
                        Button("Sign out", role: .destructive) {
                            auth.signOut()
                            classes.classes = []
                            pauses.pauses = []
                        }
                    }
                }
            }
            .navigationTitle(onboarding ? "Connect" : "Settings")
            .toolbar {
                if !onboarding && auth.hasToken {
                    // plain tab, nothing to dismiss
                }
            }
        }
    }

    private func connect() {
        auth.save(token: token)
        token = ""
        Task {
            await classes.load()
            await pauses.load()
            if onboarding { dismiss() }
        }
    }
}
