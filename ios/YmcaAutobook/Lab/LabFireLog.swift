import Foundation
import UIKit

/// LAB — Spike A instrumentation: did an unattended trigger actually fire, and
/// could it still do useful work?
///
/// A booking is only correct if the app can (a) be woken at a precise moment,
/// (b) hold runtime long enough to wait for the exact instant, and (c) complete
/// a network call — all while the phone is locked in a pocket. Each run records
/// enough to judge all three.
enum LabFireLog {

    struct Entry: Codable, Identifiable {
        var firedAt: Date
        var waitSeconds: Int
        var completedAt: Date?
        var lockedAtFire: Bool          // inferred from protected-data availability
        var sleepSurvived: Bool
        var httpStatusOK: Bool
        var occurrences: Int?
        var detail: String
        var reAuthed: Bool

        var id: TimeInterval { firedAt.timeIntervalSince1970 }

        /// The bar: woke, held runtime through the wait, and finished the call.
        var fullySucceeded: Bool { sleepSurvived && httpStatusOK }
    }

    private static let key = "lab.fires"
    private static let limit = 60

    static func load() -> [Entry] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return v
    }

    static func save(_ entries: [Entry]) {
        if let d = try? JSONEncoder().encode(Array(entries.prefix(limit))) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// Whether the device was locked when we woke. `isProtectedDataAvailable`
    /// goes false while locked — the Keychain items we rely on are stored
    /// `AfterFirstUnlock` precisely so they stay readable in that state, so this
    /// is the signal that a run was genuinely unattended rather than done with
    /// the phone open in your hand.
    @MainActor private static func deviceIsLocked() -> Bool {
        !UIApplication.shared.isProtectedDataAvailable
    }

    /// The unattended path end to end: wake → wait for the exact instant →
    /// authenticated call, re-authenticating silently if the session lapsed.
    static func run(waitSeconds: Int) async {
        let locked = await deviceIsLocked()
        var entry = Entry(firedAt: Date(), waitSeconds: waitSeconds, completedAt: nil,
                          lockedAtFire: locked, sleepSurvived: false, httpStatusOK: false,
                          occurrences: nil, detail: "started", reAuthed: false)
        // Persist immediately: if iOS suspends us mid-wait, the surviving record
        // showing sleepSurvived == false is itself the finding.
        save([entry] + load())

        if waitSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(waitSeconds) * 1_000_000_000)
        }
        entry.sleepSurvived = true

        guard var session = GymCredentialStore.session else {
            entry.detail = "no stored session"
            entry.completedAt = Date()
            replaceHead(with: entry)
            return
        }

        var outcome = await YmcaSessionClient.validate(session)

        // Session lapsed — the silent re-login proven in Spike C, now exercised
        // in the unattended path where it actually has to work.
        if case .expired = outcome {
            entry.reAuthed = true
            if let refreshed = await silentReAuth() {
                session = refreshed
                GymCredentialStore.saveSession(refreshed)
                outcome = await YmcaSessionClient.validate(session)
            } else {
                entry.detail = "session expired and silent re-login failed"
            }
        }

        switch outcome {
        case .ok(let n, let ms):
            entry.httpStatusOK = true
            entry.occurrences = n
            entry.detail = "ok in \(ms)ms" + (entry.reAuthed ? " (after re-auth)" : "")
        case .expired(let status):
            entry.detail = "expired (HTTP \(status))"
        case .failed(let why):
            entry.detail = why
        }
        entry.completedAt = Date()
        replaceHead(with: entry)
    }

    private static func silentReAuth() async -> StoredSession? {
        guard let u = GymCredentialStore.username,
              let p = GymCredentialStore.password else { return nil }
        let controller = await LabLoginController()
        return try? await controller.start(mode: .scripted(username: u, password: p), timeout: 90)
    }

    private static func replaceHead(with entry: Entry) {
        var all = load()
        if !all.isEmpty { all.removeFirst() }
        save([entry] + all)
    }
}
