#if os(macOS)
import SwiftUI

struct MenuView: View {
    @ObservedObject var engine: Engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("YMCA Booker").font(.headline)
                Spacer()
                Text(version).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            if engine.signedInAs == nil {
                Divider()
                SignInForm(engine: engine)
            } else {
                signedIn
            }
            Divider()
            HStack {
                if engine.signedInAs != nil {
                    Button("Schedule…") { open(MacTab.schedule) }
                    Button("Classes…") { open(MacTab.classes) }
                    Button("Settings…") { open(MacTab.settings) }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder private var signedIn: some View {
        // The next opening already says what "Next: …" would; show the status only
        // when it says something else (planning, an error, an opening under way).
        if !engine.status.hasPrefix("Next:") {
            Text(engine.status).font(.caption).foregroundStyle(.secondary)
        }

        if let next = engine.openings.first {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    header("Next opening")
                    Spacer()
                    Button { Task { await engine.plan() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Re-plan")
                }
                Text("\(next.klass.name) · \(next.occurrence.occursAt.formatted(.dateTime.weekday().month(.defaultDigits).day().hour().minute()))")
                    .font(.title3.bold())
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Opens \(dayLabel(next.openAt)) \(next.openAt.formatted(date: .omitted, time: .shortened)) · in \(countdown(to: next.openAt, from: ctx.date))")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }

        if engine.openings.count > 1 {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                header("Then")
                ForEach(engine.openings.dropFirst().prefix(4)) { o in
                    HStack {
                        Text(o.klass.name).lineLimit(1)
                        if o.away { Text("away").font(.caption).foregroundStyle(.orange) }
                        Spacer()
                        Text(o.openAt.formatted(.dateTime.weekday().hour().minute()))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }

        if !engine.log.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                header("Recent")
                ForEach(engine.log.suffix(3).reversed()) { e in
                    HStack {
                        Image(systemName: e.booking?.booked == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(e.booking?.booked == true ? .green : .orange)
                        Text(e.className).lineLimit(1)
                        Spacer()
                        Text(e.occursAt.formatted(.dateTime.weekday().month(.defaultDigits).day()))
                            .foregroundStyle(.secondary)
                    }
                    .help(summary(e))
                }
            }
        }

        Text("Signed in as \(engine.signedInAs ?? "")").font(.caption2).foregroundStyle(.tertiary)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption.bold()).foregroundStyle(.secondary)
    }

    /// Opens the app's window on a tab, named as in the window (and on the iPhone).
    /// The tab keeps whichever segment was last picked.
    private func open(_ tab: String) {
        UserDefaults.standard.set(tab, forKey: MacTab.key)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// "1.0 (20261020.1)": the same version and build TestFlight and the release page show.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInTomorrow(date) { return "tomorrow" }
        return date.formatted(.dateTime.weekday(.wide))
    }

    private func countdown(to date: Date, from now: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        return d > 0 ? "\(d)d \(h)h \(m)m" : String(format: "%d:%02d:%02d", h, m, sec)
    }
}

func summary(_ e: ShadowEntry) -> String {
    var parts = [e.verdict]
    if let s = e.sendLag { parts.append(String(format: "sent %+.0f ms", s * 1000)) }
    if let lag = e.fireLag { parts.append(String(format: "reply %+.0f ms", lag * 1000)) }
    if let f = e.fillSeconds { parts.append(String(format: "filled after %.0fs", f)) }
    return parts.joined(separator: " · ")
}

struct SignInForm: View {
    @ObservedObject var engine: Engine
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in with your YMCA (egym) account. Stored only in this Mac's Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Email", text: $email).textContentType(.username)
            SecureField("Password", text: $password).textContentType(.password)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Sign in") {
                    Task {
                        busy = true; error = nil
                        do { try await engine.signIn(username: email, password: password) }
                        catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || email.isEmpty || password.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}
#endif
