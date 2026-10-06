import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Binding var signedIn: Bool
    @State private var token = UserDefaults.standard.string(forKey: "apnsToken")
    @State private var tokenError = UserDefaults.standard.string(forKey: "apnsError")
    @State private var notifications = "…"
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("egym", value: Keychain.string("egym.username") ?? "—")
                    Button("Sign out", role: .destructive) {
                        Task {
                            await FisikalClient.shared.signOut()
                            signedIn = false
                        }
                    }
                }
                Section {
                    LabeledContent("Notifications", value: notifications)
                    if let token {
                        Text(token).font(.caption.monospaced()).textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy device token") {
                            UIPasteboard.general.string = token
                            copied = true
                        }
                    } else if let tokenError {
                        Text(tokenError).foregroundStyle(.red)
                    } else {
                        Text("Registering for push…").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Push (for the wake-up relay)")
                } footer: {
                    Text("Development token — only valid with Apple's sandbox push server.")
                }
            }
            .navigationTitle("Settings")
            .task { await refreshNotificationStatus() }
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.tokenChanged)) { _ in
                token = UserDefaults.standard.string(forKey: "apnsToken")
                tokenError = UserDefaults.standard.string(forKey: "apnsError")
            }
        }
    }

    private func refreshNotificationStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        let auth: String
        switch s.authorizationStatus {
        case .authorized: auth = "allowed"
        case .denied: auth = "denied"
        case .notDetermined: auth = "not asked yet"
        case .provisional, .ephemeral: auth = "provisional"
        @unknown default: auth = "unknown"
        }
        let ts = s.timeSensitiveSetting == .enabled ? ", time-sensitive on" : ""
        notifications = auth + ts
    }
}
