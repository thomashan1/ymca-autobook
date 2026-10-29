#if os(iOS)
import SwiftUI

/// Sign-in + account + help screen. Paste a GitHub personal access token; it's
/// stored in the Keychain and used for every API call. Doubles as the
/// first-run onboarding sheet, and always shows how to create a token.
struct SettingsView: View {
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var classes: ClassesRepository
    @EnvironmentObject var awayRanges: AwayRepository
    @EnvironmentObject var snapshot: SnapshotRepository
    @EnvironmentObject var bookings: BookingsRepository
    @EnvironmentObject var fullClasses: FullRepository
    @ObservedObject private var cloud = CloudSource.shared

    /// When shown as the first-run sheet this is true; false when it's the tab.
    var onboarding: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""
    @State private var reloading = false
    @State private var refreshing = false
    @State private var refreshNote: String?
    @State private var authError: String?
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            Form {
                if auth.isCloud || SampleMode.active {
                    Section("Your Macs") {
                        MacsList(macs: SampleMode.active ? Self.sampleMacs : cloud.macs)
                    }
                }
                if auth.isCloud {
                    cloudSection
                    diagnosticsSection
                } else {
                    if !auth.hasToken {
                        tokenEntrySection
                    } else {
                        connectionSection
                        diagnosticsSection
                    }
                    whySection
                    howToSection
                }
                advancedSection
            }
            .navigationTitle(onboarding ? "Connect" : "Settings")
        }
    }

    // MARK: Sections

    private static var sampleMacs: [Cloud.MacDevice] {
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.2"
        return [Cloud.MacDevice(id: "mac-sample-1", name: "Mac mini", booking: true, version: v, checkedIn: .now.addingTimeInterval(-120)),
                Cloud.MacDevice(id: "mac-sample-2", name: "MacBook Pro", booking: false, version: v, checkedIn: .now.addingTimeInterval(-3 * 3600), laptop: true)]
    }

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

    /// GitHub is for people running the Actions setup themselves; everyone else
    /// leaves this off and reads from their Mac.
    private var advancedSection: some View {
        Section {
            Toggle(isOn: Binding(get: { auth.source == .github },
                                 set: { auth.use($0 ? .github : .icloud) })) {
                Label("Use GitHub instead", systemImage: "server.rack")
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("For the GitHub Actions setup (see the project README): this app then reads and edits your plan in your GitHub repos and needs a GitHub token. Leave it off to use YMCA Booker on your Mac.")
        }
    }

    /// The Mac's status, when it's the source.
    private var cloudSection: some View {
        Section {
            MacStatusRow()
            NavigationLink { BookingHistoryView() } label: {
                Label("Booking history", systemImage: "clock.arrow.circlepath")
            }
            Button {
                reload()
            } label: {
                HStack {
                    Text("Reload data")
                    if reloading { Spacer(); ProgressView() }
                }
            }
            .disabled(reloading)
        } footer: {
            Text("Everything here comes from YMCA Booker on your Mac, through your own iCloud. Sign in to the same Apple Account on the Mac and on this device.")
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
            Button {
                refreshBookingsNow()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Refresh bookings from YMCA")
                        Text("Re-reads what's actually booked, instead of waiting for the 6-hourly job.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if refreshing { Spacer(); ProgressView() }
                }
            }
            .disabled(refreshing)
            if let refreshNote {
                Text(refreshNote).font(.caption).foregroundStyle(.secondary)
            }
            Button("Sign out", role: .destructive) {
                auth.signOut()
                classes.classes = []
                awayRanges.awayRanges = []
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            LabeledContent("Classes loaded", value: "\(classes.classes.count)")
            if let e = classes.error {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            LabeledContent("Away dates loaded", value: "\(awayRanges.awayRanges.count)")
            if let e = awayRanges.error {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// Sits above the steps because "should I even be doing this?" comes before
    /// "how". Most of the time the answer is no — the token outlives app
    /// reinstalls, so a fresh one is the exception, not routine maintenance.
    private var whySection: some View {
        Section {
            reason("key.fill", "What it's for",
                   "GitHub Actions does the actual booking. This app just reads and edits your plan on GitHub — classes, away dates — and can kick off a booking run. The token is how GitHub knows those requests are yours.")
            reason("calendar.badge.exclamationmark", "When it expires",
                   "Fine-grained tokens always have an expiry date, and GitHub emails you shortly before. Once it lapses the app stops loading data and you'll need a new one.")
            reason("exclamationmark.triangle", "If it leaks or you revoke it",
                   "Revoke it on github.com and make another. It only reaches these two repos, so nothing else of yours is exposed.")
            reason("lock.rotation", "If a permission is missing",
                   "An action that used to work starts failing — deleting a class needs Contents: Read and write, for instance. Fix it by editing the token's permissions on github.com; that doesn't require a new token.")
            reason("iphone", "On a new phone",
                   "Tokens live in this device's Keychain and aren't shared between devices, so a second phone needs its own.")
        } header: {
            Text("Why you need a token")
        } footer: {
            Text("You usually won't need to repeat this. The token survives deleting and reinstalling the app — it's only gone if you sign out here, revoke it, or let it expire.")
        }
    }

    private var howToSection: some View {
        Section {
            step(1, "On github.com, open Settings → Developer settings → Personal access tokens → Fine-grained tokens.")
            step(2, "Tap “Generate new token”. Name it (e.g. “YMCA Autobook app”) and set an expiration.")
            step(3, "Resource owner: your own GitHub account (the one with both repos).")
            step(4, "Repository access → Only select repositories → choose both \(Config.publicRepo) and \(Config.privateRepo).")
            step(5, "Permissions → Repository permissions. Set all three of these — every one is Read and write, not Read-only:")
            ForEach(Self.tokenPermissions, id: \.self) { permissionRow($0) }
            step(6, "Generate the token, copy it, and paste it into the field above.")
        } header: {
            Text("How to create a token")
        } footer: {
            Text("A fine-grained token limited to these two repos. If it ever leaks, revoke it on github.com and create a new one — nothing else is affected.")
        }
    }

    /// The repository permissions the token needs. All four are Read and write:
    /// every one of them backs a write path — Contents edits classes.yml and
    /// away.yml in the private repo, Actions dispatches a booking run, Workflows
    /// covers book.yml living under .github/workflows.
    static let tokenPermissions = ["Contents", "Actions", "Workflows"]

    /// One permission as a row rather than a clause in a sentence — you set
    /// these one dropdown at a time on github.com, so a list you can tick off
    /// while switching between two screens beats prose. The level is repeated
    /// on every row on purpose: a single "all of them are Read and write" line
    /// is exactly what gets skimmed past, and Read-only is the wrong default
    /// GitHub offers first.
    private func permissionRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5)).foregroundStyle(.secondary)
            Text(name).font(.callout)
            Spacer()
            Text("Read and write")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Theme.weekDivider.opacity(0.15), in: Capsule())
                .foregroundStyle(Theme.weekDivider)
        }
        .padding(.leading, 30)   // line up under the step text, past the number badge
    }

    /// Numbered step. Deliberately *not* the accent red — these are ordinary
    /// instructions, and a row of red badges reads as a list of errors.
    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.weekDivider)
                .frame(width: 20, height: 20)
                .background(Theme.weekDivider.opacity(0.15), in: Circle())
            Text(text).font(.callout)
        }
    }

    private func reason(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Theme.weekDivider)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            await awayRanges.load()
            connecting = false
            if onboarding { dismiss() }
        }
    }

    /// Reloads everything the app shows. It used to fetch only classes and
    /// away dates, so "Reload data" left the Week view's real bookings untouched —
    /// exactly the thing you'd hit the button to update.
    private func reload() {
        reloading = true
        Task {
            if auth.isCloud { await CloudSource.shared.refresh() }
            await classes.load()
            await awayRanges.load()
            await snapshot.load()
            await bookings.load()
            await fullClasses.load()
            reloading = false
        }
    }

    /// bookings.json is republished by a workflow every 6h, so a booking made
    /// just now isn't in it yet and no amount of pulling to refresh will help.
    /// This asks that workflow to run, waits for it, then reloads.
    private func refreshBookingsNow() {
        refreshing = true
        refreshNote = "Asking GitHub to re-read your bookings…"
        Task {
            do {
                try await GitHubClient().dispatchBookingsSnapshot()
            } catch {
                refreshNote = "Couldn't start it: \(error.localizedDescription)"
                refreshing = false
                return
            }
            // The run takes ~1 min (login + Playwright). Poll the file rather
            // than guessing: stop as soon as its timestamp moves.
            let before = bookings.updatedAt
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await bookings.load()
                await fullClasses.load()
                if bookings.updatedAt != before {
                    refreshNote = "Up to date."
                    refreshing = false
                    return
                }
            }
            refreshNote = "Still running — pull down on Week in a moment."
            refreshing = false
        }
    }
}
#endif
