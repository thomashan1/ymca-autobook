#if os(macOS)
import SwiftUI
import UserNotifications

/// The app's window, laid out like the iPhone and iPad app: Schedule, Classes
/// and Settings, with no segments. The menu bar buttons pick the tab through
/// the same stored key.
struct SettingsView: View {
    @ObservedObject var engine: Engine
    @AppStorage(MacTab.key) private var tab = MacTab.schedule

    var body: some View {
        if engine.signedInAs == nil {
            WelcomeView(engine: engine)
                .frame(minWidth: 960, minHeight: 560)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            MacScheduleView(engine: engine)
                .tabItem { Label("Schedule", systemImage: "calendar") }.tag(MacTab.schedule)
            ClassesEditor(engine: engine)
                .tabItem { Label("Classes", systemImage: "list.bullet") }.tag(MacTab.classes)
            GeneralSettings(engine: engine)
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(MacTab.settings)
        }
        .padding()
        // On every tab, so a screenshot or a question always says which build.
        .safeAreaInset(edge: .bottom, alignment: .trailing) { VersionTag().padding(.trailing, 16).padding(.bottom, 6) }
        .frame(minWidth: 960, minHeight: 560)
    }
}

/// "1.1 (20261020.12)": the same version and build TestFlight and the release page show.
enum AppVersion {
    static var label: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// The version and build, small and grey.
struct VersionTag: View {
    var body: some View {
        Text("YMCA Booker \(AppVersion.label)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            .textSelection(.enabled)
    }
}

/// First run (or signed out): what the app does and the YMCA sign-in, in the
/// window itself rather than only in the menu bar.
private struct WelcomeView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Welcome to YMCA Booker").font(.largeTitle.bold())
            Text("Sign in with the account you use in the YMCA app. Then pick your classes: this Mac books each one the second it opens, every week.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            SignInForm(engine: engine).frame(width: 360)
            WatchOnlyToggle(engine: engine).frame(width: 360)
            Text("Want your classes on an iPhone or iPad too? Install YMCA Booker there and sign in to the same Apple Account as this Mac: everything shows up through your own iCloud.")
                .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            VersionTag()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The "Don't book on this Mac" switch and what it means.
struct WatchOnlyToggle: View {
    @ObservedObject var engine: Engine
    @AppStorage(WatchOnly.key) private var on = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Don't book on this Mac", isOn: $on)
                .onChange(of: on) { _, now in if now { engine.enterWatchOnly() } else { engine.leaveWatchOnly() } }
            Text(on ? "Watch only: this Mac shows the booking Mac's classes and away dates (same iCloud account) but never books, cancels or changes anything. Make changes on that Mac or the iPhone."
                    : "Turn on for a second Mac that should only watch, so two Macs never book the same classes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Tab names, shared with the menu bar's buttons.
enum MacTab {
    static let key = "macTab"
    static let schedule = "schedule", classes = "classes", settings = "settings"
}

/// A sheet holding one of the bigger tables (the YMCA schedule, fill speed,
/// the booking log), with a Done button.
struct SheetFrame<Content: View>: View {
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            content
            HStack {
                VersionTag()
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 1000, minHeight: 620)
    }
}

private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

// MARK: Classes

/// Your classes: every week (with how fast each fills) and just once. Add a
/// class from the YMCA schedule, either way.
struct ClassesEditor: View {
    @ObservedObject var engine: Engine
    @State private var sheet: Sheet?
    @AppStorage(WatchOnly.key) private var watchOnly = false

    private enum Sheet: String, Identifiable { case add, fill; var id: String { rawValue } }

    var body: some View {
        let stats = Dictionary(engine.slotStats().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your classes").font(.title2.bold())
                Spacer()
                if watchOnly {
                    Text("Watch only: change classes on the Mac that books, or on the iPhone.")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    Button { sheet = .add } label: { Label("Add a class", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("n")
                        .help("Add a class from the YMCA schedule, every week or just once")
                }
            }
            List {
                Section {
                    ForEach(sorted) { k in
                        HStack(spacing: 10) {
                            Text(k.weekday).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                            Text(k.name).bold()
                            Text("\(k.start) · \(k.branch)").foregroundStyle(.secondary)
                            if !engine.isOnSchedule(k) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help("No matching class on the YMCA schedule in the next 16 days — check the name and time")
                            }
                            Spacer()
                            if let st = stats[k.slotKey] { fillBadge(st) }
                            if !watchOnly {
                                Button(role: .destructive) {
                                    engine.update(classes: engine.classes.filter { $0.key != k.key })
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Stop booking it every week")
                            }
                        }
                    }
                    if engine.classes.isEmpty { Text("None yet. Click Add a class.").foregroundStyle(.secondary) }
                } header: {
                    HStack {
                        Text("Every week")
                        Spacer()
                        Button { sheet = .fill } label: { Label("How fast classes fill", systemImage: "chart.bar") }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
                if !upcomingPicks.isEmpty {
                    Section("Just once") {
                        ForEach(upcomingPicks) { p in
                            HStack(spacing: 10) {
                                Text(p.name).bold()
                                Text("\(p.occursAt.formatted(.dateTime.weekday().month().day().hour().minute())) · \(Branch.name(p.branchId))")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(p.openAt > Date() ? "books \(MacScheduleView.when(p.openAt))" : "booking…")
                                    .foregroundStyle(.blue)
                                if !watchOnly { Button("Don't book") { engine.perform(.withdraw, on: p) } }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $sheet) { s in
            SheetFrame(close: { sheet = nil }) {
                switch s {
                case .add: MacBookView(engine: engine)
                case .fill: StatsView(engine: engine)
                }
            }
        }
    }

    private var upcomingPicks: [ClassPick] { engine.picks.filter { $0.occursAt > Date() } }

    private func fillBadge(_ s: SlotStats) -> some View {
        let fast = (s.medianFill ?? .infinity) <= 300
        return Text(s.filledWeeks == 0 ? "rarely fills" : "fills in \(Self.duration(s.medianFill))")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((fast ? Color.orange : Color.gray).opacity(0.15), in: Capsule())
            .foregroundStyle(fast ? Color.orange : Color.secondary)
    }

    static func duration(_ seconds: Double?) -> String {
        guard let s = seconds else { return "—" }
        if s < 120 { return "\(Int(s.rounded())) s" }
        if s < 7200 { return "\(Int(s / 60)) min" }
        if s < 2 * 86400 { return String(format: "%.0f h", s / 3600) }
        return String(format: "%.0f d", s / 86400)
    }

    private var sorted: [RecurringClass] {
        engine.classes.sorted { (weekdays.firstIndex(of: $0.weekday) ?? 9, $0.start) < (weekdays.firstIndex(of: $1.weekday) ?? 9, $1.start) }
    }
}

// MARK: Away dates (edited here; the GitHub backup gets a copy)

struct MacAwayView: View {
    @ObservedObject var engine: Engine
    @State private var showPast = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var note = ""
    @State private var keep: Set<String> = []
    /// The range loaded into the form for editing; nil when adding.
    @State private var editing: AwayRange?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(editing == nil ? "Add away dates" : "Edit away dates") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        DatePicker("From", selection: $start, displayedComponents: .date)
                        DatePicker("to", selection: $end, in: start..., displayedComponents: .date)
                        TextField("Note (optional)", text: $note)
                    }
                    HStack {
                        Menu(keep.isEmpty ? "Book nothing on these days" : "Still book: \(keep.map(className).sorted().joined(separator: ", "))") {
                            ForEach(engine.classes.filter { !$0.isOneOff }) { c in
                                Toggle("\(c.name) \(c.weekday) \(c.start)", isOn: Binding(
                                    get: { keep.contains(c.key) },
                                    set: { if $0 { keep.insert(c.key) } else { keep.remove(c.key) } }))
                            }
                        }
                        .fixedSize()
                        Spacer()
                        if editing != nil {
                            Button("Cancel") { clearForm() }.keyboardShortcut(.cancelAction)
                        }
                        Button(editing == nil ? "Add" : "Save") { add() }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(4)
            }
            .onChange(of: start) { _, s in if end < s { end = s } }
            HStack {
                if RepoSync.isEnabled { SyncStatus(engine: engine) }
                Spacer()
                Toggle("Show past", isOn: $showPast)
            }
            List {
                Section("Away dates — no booking on these days") {
                    let awayRanges = engine.awayRanges.filter { showPast || !$0.isPast }.sorted { $0.start < $1.start }
                    if awayRanges.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(awayRanges) { p in
                        HStack(alignment: .firstTextBaseline) {
                            Text(p.start == p.end ? withWeekday(p.start) : "\(withWeekday(p.start)) → \(withWeekday(p.end))")
                                .monospacedDigit()
                                .frame(minWidth: 230, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                if let note = p.note { Text(note) }
                                if let ex = p.except, !ex.isEmpty {
                                    Text("still booking: \(ex.map(className).joined(separator: ", "))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button { load(p) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .help("Edit these away dates")
                            Button(role: .destructive) { engine.removeAwayRange(p) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Remove these away dates")
                        }
                        .foregroundStyle(p.isPast ? .secondary : .primary)
                    }
                }
                let swaps = engine.swaps.filter { showPast || !$0.isPast }
                if !swaps.isEmpty {
                    Section("One-off swaps (from before 10/14)") {
                        ForEach(swaps) { w in
                            HStack(alignment: .firstTextBaseline) {
                                Text(withWeekday(w.date)).monospacedDigit().frame(minWidth: 230, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(describe(w))
                                    if let note = w.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .foregroundStyle(w.isPast ? .secondary : .primary)
                        }
                    }
                }
            }
            Text("For a single day's change, use Book: Skip a weekly class, or Book a different one. "
                 + (RepoSync.isEnabled ? "A copy of your classes, away dates and one-day changes goes to \(RepoSync.repo ?? "your repo") for the GitHub backup." : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add() {
        let s = AwayRange.day(start), e = AwayRange.day(max(start, end))
        let n = note.trimmingCharacters(in: .whitespaces)
        let range = AwayRange(start: s, end: e, except: keep.isEmpty ? nil : keep.sorted(), note: n.isEmpty ? nil : n)
        if let old = editing { engine.replaceAwayRange(old, with: range) } else { engine.addAwayRange(range) }
        clearForm()
    }

    /// Put a range into the form to edit it.
    private func load(_ p: AwayRange) {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = FisikalClient.zone
        f.dateFormat = "yyyy-MM-dd"
        guard let s = f.date(from: p.start), let e = f.date(from: p.end) else { return }
        editing = p
        start = s; end = e
        note = p.note ?? ""
        keep = Set(p.except ?? [])
    }

    private func clearForm() {
        editing = nil
        note = ""; keep = []
    }

    private func describe(_ w: Swap) -> String {
        let skip = w.skip.map { "skip \(className($0))" }
        let book = w.bookName.map { name in
            "take \(name)\(w.bookStart.map { " \($0)" } ?? "")\(w.bookLocationIds?.first.map { " · \(Slot.branchName($0))" } ?? "")"
        }
        return [skip, book].compactMap { $0 }.joined(separator: ", ")
    }

    /// "2026-10-23" -> "Fri 10/23/2026"
    private func withWeekday(_ day: String) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = FisikalClient.zone
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return day }
        f.dateFormat = "EEE M/d/yyyy"
        return f.string(from: d)
    }

    private func className(_ key: String) -> String {
        engine.classes.first { $0.key == key }.map { "\($0.name) \($0.weekday)" } ?? key
    }
}

/// "Backup copy updated 3 min ago" — or why it isn't.
struct SyncStatus: View {
    @ObservedObject var engine: Engine

    var body: some View {
        if !RepoSync.isEnabled {
            Label("No GitHub backup", systemImage: "icloud.slash").foregroundStyle(.secondary)
        } else if let err = engine.syncError {
            Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if let t = engine.lastSynced {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Label("GitHub backup's copy checked \(t.formatted(.relative(presentation: .named)))", systemImage: "checkmark.icloud")
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("GitHub backup not updated yet", systemImage: "icloud.slash").foregroundStyle(.secondary)
        }
    }
}

// MARK: General

struct GeneralSettings: View {
    @ObservedObject var engine: Engine
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var notifications = "…"
    @State private var showLog = false

    var body: some View {
        Form {
            Section("This Mac") {
                WatchOnlyToggle(engine: engine)
            }
            Section("Your Macs") {
                MacsList(macs: engine.macs, thisMac: UserDefaults.standard.string(forKey: "macDeviceId"))
                Text("Every Mac with YMCA Booker on your iCloud account. One books; the others can just watch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Open YMCA Booker at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try LoginItem.set(on); loginError = nil }
                        catch { loginError = error.localizedDescription; launchAtLogin = LoginItem.isEnabled }
                    }
                if let loginError { Text(loginError).foregroundStyle(.red) }
                Text("Keeps the Mac from idle-sleeping while running (the display can still sleep). Booking needs the Mac awake and online at each opening.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                LabeledContent("Status", value: notifications)
                Text("A notification per opening with the booking result, plus a warning if the YMCA can't be reached.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("iCloud (for the iPhone app)") {
                if let err = engine.cloudError {
                    Label(err, systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
                } else if let t = engine.lastCloudPush {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Label("Up to date \(t.formatted(.relative(presentation: .named)))", systemImage: "checkmark.icloud")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Not sent yet", systemImage: "icloud").foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Send now") { Task { await engine.pushToCloud() } }
                }
                Text("Your classes, away dates, swaps, booking results and fill stats go to your own iCloud so the iPhone app can show them. Sign in to the same Apple Account on the iPhone and iPad. Booking never waits on iCloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                HStack {
                    Text("YMCA Booker \(AppVersion.label). Checks for a new version once a day and asks before installing; it never restarts around an opening.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    CheckForUpdatesButton()
                }
            }
            Section("Booking history") {
                HStack {
                    Text("Every opening your Mac handled: when the booking went out, the reply, and how fast the class filled.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show…") { showLog = true }
                }
            }
            Section("Account") {
                LabeledContent("Signed in as", value: engine.signedInAs ?? "—")
                Button("Sign out", role: .destructive) { Task { await engine.signOut() } }
            }
            GitHubBackupSection(engine: engine)
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showLog) { SheetFrame(close: { showLog = false }) { LogView(engine: engine) } }
        .task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            notifications = s.authorizationStatus == .authorized ? "allowed"
                : s.authorizationStatus == .denied ? "off — turn on in System Settings → Notifications → YMCA Booker"
                : "not decided yet"
        }
    }
}

// MARK: GitHub backup

/// The optional GitHub backup (Option B), folded away as "Advanced mode" at the
/// bottom of Settings since most people never use it, and always collapsed at
/// first. Off by default: the Mac books on its own and syncs to the iPhone
/// through iCloud, with no GitHub account needed.
struct GitHubBackupSection: View {
    @ObservedObject var engine: Engine
    @State private var expanded = false
    @State private var on = RepoSync.isEnabled
    @State private var token = ""
    @State private var repo = RepoSync.repo ?? ""

    private func save() {
        let t = token
        token = ""
        Task { await engine.setGitHub(repo: repo, token: t) }
    }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                Toggle("Also keep a GitHub backup", isOn: $on)
                    .onChange(of: on) { _, enabled in
                        if !enabled { repo = ""; token = ""; engine.turnOffGitHub() }
                    }
                Text("Not needed. YMCA Booker books from this Mac and shows everything on your iPhone and iPad through iCloud, without GitHub. Turn this on only if you also run the GitHub Actions booker (see the project README) as a backup for when the Mac is asleep or offline.")
                    .font(.caption).foregroundStyle(.secondary)
                if on {
                    TextField("Private repo", text: $repo, prompt: Text("owner/repo"))
                        .onSubmit(save)
                    SecureField("Token", text: $token, prompt: Text(RepoSync.token == nil ? "Paste a token" : "Saved — paste to replace"))
                        .onSubmit(save)
                    HStack {
                        if RepoSync.isEnabled { SyncStatus(engine: engine) }
                        Spacer()
                        Button("Save") { save() }
                            .disabled(repo.trimmingCharacters(in: .whitespaces).isEmpty
                                      || (repo.trimmingCharacters(in: .whitespaces) == (RepoSync.repo ?? "") && token.isEmpty))
                    }
                    Text("After each change the Mac writes a copy of your classes, away dates and one-day changes into that private repo's classes.yml, away.yml and swaps.yml, for the backup to follow. It never reads them back, so keep editing here or on the iPhone, not in the repo. Use a fine-grained token for that repo only, with Contents: Read and write. It's stored in this Mac's Keychain. Turning the backup off forgets the repo and token.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                // Collapsed even with the backup on, but a problem still shows.
                HStack {
                    Text("GitHub backup")
                    if RepoSync.isEnabled, engine.syncError != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help("The GitHub backup has a problem. Open to see it.")
                    }
                }
            }
        } header: { Text("Advanced mode") }
    }
}
#endif
