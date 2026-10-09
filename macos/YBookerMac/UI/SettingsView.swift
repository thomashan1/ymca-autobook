import SwiftUI
import UserNotifications

struct SettingsView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        TabView {
            CatalogView(engine: engine).tabItem { Label("Browse", systemImage: "magnifyingglass") }
            ClassesEditor(engine: engine).tabItem { Label("My classes", systemImage: "list.bullet") }
            StatsView(engine: engine).tabItem { Label("Stats", systemImage: "chart.bar") }
            PausesEditor(engine: engine).tabItem { Label("Pauses", systemImage: "pause.circle") }
            GeneralSettings(engine: engine).tabItem { Label("General", systemImage: "gearshape") }
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

// MARK: Pauses

struct PausesEditor: View {
    @ObservedObject var engine: Engine
    @State private var from = Date()
    @State private var to = Date()
    @State private var keep: Set<String> = []
    @State private var showPast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show past pauses", isOn: $showPast)
            List {
                ForEach(engine.pauses.filter { showPast || !$0.isPast }.sorted { $0.start < $1.start }) { p in
                    HStack {
                        Text(p.start == p.end ? withWeekday(p.start) : "\(withWeekday(p.start)) → \(withWeekday(p.end))")
                            .monospacedDigit()
                        if let ex = p.except, !ex.isEmpty {
                            Text("keep: \(ex.map(className).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            engine.update(pauses: engine.pauses.filter { $0.id != p.id })
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                    .foregroundStyle(p.isPast ? .secondary : .primary)
                }
            }
            GroupBox("Add a pause (no auto-booking on these days)") {
                VStack(alignment: .leading) {
                    HStack {
                        DatePicker("From", selection: $from, displayedComponents: .date)
                        DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
                        Spacer()
                        Button("Add") {
                            engine.update(pauses: engine.pauses + [Pause(start: Pause.day(from), end: Pause.day(max(from, to)),
                                                                          except: keep.isEmpty ? nil : keep.sorted())])
                            keep = []
                        }
                    }
                    DisclosureGroup("Still book these classes on those days (optional)") {
                        ScrollView {
                            VStack(alignment: .leading) {
                                ForEach(engine.classes) { k in
                                    Toggle("\(k.name) — \(k.weekday) \(k.start)", isOn: Binding(
                                        get: { keep.contains(k.key) },
                                        set: { if $0 { keep.insert(k.key) } else { keep.remove(k.key) } }))
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
            }
        }
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

// MARK: General

struct GeneralSettings: View {
    @ObservedObject var engine: Engine
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var notifications = "…"

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open Y Booker at login", isOn: $launchAtLogin)
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
                Text("One notification per opening with what shadow mode saw, plus a warning if the YMCA can't be reached.")
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
                : s.authorizationStatus == .denied ? "off — turn on in System Settings → Notifications → Y Booker"
                : "not decided yet"
        }
    }
}
