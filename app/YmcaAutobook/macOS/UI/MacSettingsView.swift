#if os(macOS)
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        TabView {
            MacBookView(engine: engine).tabItem { Label("Book", systemImage: "calendar.badge.plus") }
            CatalogView(engine: engine).tabItem { Label("Browse", systemImage: "magnifyingglass") }
            ClassesEditor(engine: engine).tabItem { Label("My classes", systemImage: "list.bullet") }
            StatsView(engine: engine).tabItem { Label("Stats", systemImage: "chart.bar") }
            PausesView(engine: engine).tabItem { Label("Away & swaps", systemImage: "airplane") }
            GeneralSettings(engine: engine).tabItem { Label("General", systemImage: "gearshape") }
            AdvancedSettings(engine: engine).tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .padding()
        .frame(minWidth: 960, minHeight: 560)
    }
}

private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
private let branches = [(1392, "Southwest"), (1388, "Northwest")]

// MARK: Classes

struct ClassesEditor: View {
    @ObservedObject var engine: Engine
    @State private var name = ""
    @State private var weekday = "Mon"
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
    @State private var branch = 1392

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(sorted) { k in
                    HStack {
                        Image(systemName: engine.isOnSchedule(k) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(engine.isOnSchedule(k) ? .green : .orange)
                            .help(engine.isOnSchedule(k) ? "Found on the YMCA schedule"
                                  : "No matching class on the YMCA schedule in the next 16 days — check the name and time")
                        Text(k.name).bold()
                        Text("\(k.weekday) \(k.start) · \(k.branch)").foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            engine.update(classes: engine.classes.filter { $0.key != k.key })
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }
            GroupBox("Add a class") {
                HStack {
                    TextField("Exact class name, e.g. BODYPUMP", text: $name)
                    Picker("", selection: $weekday) { ForEach(weekdays, id: \.self) { Text($0) } }.frame(width: 80)
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute).frame(width: 90)
                    Picker("", selection: $branch) { ForEach(branches, id: \.0) { Text($0.1).tag($0.0) } }.frame(width: 120)
                    Button("Add") { add() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Use the name exactly as the YMCA schedule shows it. A ⚠️ after adding means nothing on the schedule matched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sorted: [RecurringClass] {
        engine.classes.sorted { (weekdays.firstIndex(of: $0.weekday) ?? 9, $0.start) < (weekdays.firstIndex(of: $1.weekday) ?? 9, $1.start) }
    }

    private func add() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        engine.addClass(name: name.trimmingCharacters(in: .whitespaces), weekday: weekday,
                        start: String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0), branchId: branch)
        name = ""
    }
}

// MARK: Away dates (edited here; the GitHub backup gets a copy)

struct PausesView: View {
    @ObservedObject var engine: Engine
    @State private var showPast = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var note = ""
    @State private var keep: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Add away dates") {
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
                        Button("Add") { add() }.keyboardShortcut(.defaultAction)
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
                    let pauses = engine.pauses.filter { showPast || !$0.isPast }.sorted { $0.start < $1.start }
                    if pauses.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(pauses) { p in
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
                            Button(role: .destructive) { engine.removePause(p) } label: { Image(systemName: "trash") }
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
        let s = Pause.day(start), e = Pause.day(max(start, end))
        let n = note.trimmingCharacters(in: .whitespaces)
        engine.addPause(Pause(start: s, end: e, except: keep.isEmpty ? nil : keep.sorted(), note: n.isEmpty ? nil : n))
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

    var body: some View {
        Form {
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
                Text("Your classes, away dates, swaps, booking results and fill stats go to your own iCloud so the iPhone app can show them. Booking never waits on iCloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Account") {
                LabeledContent("Signed in as", value: engine.signedInAs ?? "—")
                Button("Sign out", role: .destructive) { Task { await engine.signOut() } }
            }
        }
        .formStyle(.grouped)
        .task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            notifications = s.authorizationStatus == .authorized ? "allowed"
                : s.authorizationStatus == .denied ? "off — turn on in System Settings → Notifications → YMCA Booker"
                : "not decided yet"
        }
    }
}

// MARK: Advanced

/// The optional GitHub backup (Option B). Off by default: the Mac books on its
/// own and syncs to the iPhone through iCloud, with no GitHub account needed.
struct AdvancedSettings: View {
    @ObservedObject var engine: Engine
    @State private var on = RepoSync.isEnabled
    @State private var token = ""
    @State private var repo = RepoSync.repo ?? ""

    private func save() {
        let t = token
        token = ""
        Task { await engine.setGitHub(repo: repo, token: t) }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Also keep a GitHub backup", isOn: $on)
                    .onChange(of: on) { _, enabled in
                        if !enabled { repo = ""; token = ""; engine.turnOffGitHub() }
                    }
                Text("Not needed. YMCA Booker books from this Mac and shows everything on your iPhone and iPad through iCloud, without GitHub. Turn this on only if you also run the GitHub Actions booker (see the project README) as a backup for when the Mac is asleep or offline.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("GitHub backup") }
            if on {
                Section {
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
                    Text("After each change the Mac writes a copy of your classes, away dates and one-day changes into that private repo's classes.yml, pauses.yml and swaps.yml, for the backup to follow. It never reads them back, so keep editing here or on the iPhone, not in the repo. Use a fine-grained token for that repo only, with Contents: Read and write. It's stored in this Mac's Keychain. Turning the backup off forgets the repo and token.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
#endif
