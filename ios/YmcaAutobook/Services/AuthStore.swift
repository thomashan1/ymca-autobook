import SwiftUI

/// Tracks whether a GitHub token is present. The token itself lives only in the
/// Keychain (`KeychainStore`); this just drives the UI's signed-in/out state.
@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var hasToken: Bool

    init() { hasToken = KeychainStore.token() != nil || SampleMode.active }

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
}
