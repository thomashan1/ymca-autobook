import SwiftUI

struct MenuView: View {
    @ObservedObject var engine: Engine
    @Environment(\.openWindow) private var openWindow

    /// LIVE when every class books for real, SHADOW when none do, otherwise how many.
    private var modeBadge: (text: String, color: Color) {
        let live = engine.classes.filter(\.booksForReal).count
        if live == 0 { return ("SHADOW MODE", .orange) }
        if live == engine.classes.count { return ("LIVE", .green) }
        return ("LIVE · \(live) of \(engine.classes.count)", .green)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Y Booker").font(.headline)
                Text(modeBadge.text).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(modeBadge.color.opacity(0.2), in: Capsule())
                    .help("LIVE: the Mac books at the opening second, alongside GitHub. SHADOW: it only watches.")
                Spacer()
            }
            if engine.signedInAs == nil {
                SignInForm(engine: engine)
            } else {
                signedIn
            }
            Divider()
            HStack {
                if engine.signedInAs != nil {
                    Button("Re-plan") { Task { await engine.plan() } }
                    Button("Booking log…") { openWindow(id: "log"); NSApp.activate(ignoringOtherApps: true) }
                    Button("Settings…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    @ViewBuilder private var signedIn: some View {
        Text(engine.status).font(.caption).foregroundStyle(.secondary)

        if let next = engine.openings.first {
            VStack(alignment: .leading, spacing: 4) {
                Text("Next opening").font(.caption.bold()).foregroundStyle(.secondary)
                Text("\(next.klass.name) · \(next.occurrence.occursAt.formatted(.dateTime.weekday().month().day().hour().minute()))")
                    .font(.title3.bold())
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("opens in \(countdown(to: next.openAt, from: ctx.date)) · \(dayLabel(next.openAt)) \(next.openAt.formatted(date: .omitted, time: .standard))")
                        .monospacedDigit()
                }
            }
        }

        if engine.openings.count > 1 {
            VStack(alignment: .leading, spacing: 3) {
                Text("Upcoming").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(engine.openings.dropFirst().prefix(6)) { o in
                    HStack {
                        Text(o.klass.name).lineLimit(1)
                        Text(o.klass.branch).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if o.paused { Text("paused").font(.caption).foregroundStyle(.orange) }
                        Text(o.openAt.formatted(.dateTime.weekday().hour().minute())).font(.caption).monospacedDigit()
                    }
                }
            }
        }

        if !engine.log.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recent").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(engine.log.suffix(4).reversed()) { e in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(e.className) · \(e.occursAt.formatted(.dateTime.weekday().month().day()))")
                        Text(summary(e)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }

        Text("Signed in as \(engine.signedInAs ?? "")").font(.caption2).foregroundStyle(.tertiary)
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
