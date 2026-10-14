#if os(iOS)
import SwiftUI

/// Tracks whether a GitHub token is present, and which data source the app
/// reads from. The token itself lives only in the Keychain (`KeychainStore`);
/// this just drives the UI's signed-in/out state.
@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var hasToken: Bool
    @Published private(set) var source: DataSource

    init() {
        hasToken = KeychainStore.token() != nil || SampleMode.active
        source = DataSource.current
    }

    /// iCloud needs no token: the Mac app publishes to the user's own iCloud.
    var isConnected: Bool { hasToken || source == .icloud }
    var isCloud: Bool { source == .icloud && !SampleMode.active }

    func save(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStore.save(token: trimmed)
        hasToken = true
    }

    func signOut() {
        KeychainStore.clear()
        hasToken = false
    }

    func use(_ s: DataSource) {
        DataSource.current = s
        source = s
        Task {
            if s == .icloud { await CloudSource.shared.refresh() } else { await CloudSource.shared.removeAlerts() }
        }
    }
}
#endif
