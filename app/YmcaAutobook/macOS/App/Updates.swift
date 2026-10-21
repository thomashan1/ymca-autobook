#if os(macOS)
import Sparkle
import SwiftUI

/// Self-updating through Sparkle: checks the newest GitHub release's appcast
/// once a day (and on "Check for Updates…"), shows the usual Install / Later
/// window, and installs a build signed with the project's EdDSA key. It never
/// restarts the booker in the minutes around an opening.
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?
    /// Set once the app is up, to see when the next opening is.
    weak var engine: Engine?

    override init() {
        super.init()
        // Screenshot mode never checks or installs anything.
        if !MacSample.active {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }
    }

    var updater: SPUUpdater? { controller?.updater }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// When it's safe to restart again, if not now: from 10 minutes before an
    /// opening until 6 minutes after one (the booking, then the fill watch).
    nonisolated static func quietUntil(now: Date, nextOpening: Date?, lastOpening: Date?) -> Date? {
        if let next = nextOpening, next > now, next.timeIntervalSince(now) < 600 { return next.addingTimeInterval(360) }
        if let last = lastOpening, last <= now, now.timeIntervalSince(last) < 360 { return last.addingTimeInterval(360) }
        return nil
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            let wait = Self.quietUntil(now: Date(), nextOpening: engine?.openings.first?.openAt,
                                       lastOpening: engine?.log.last?.openAt)
            guard let wait else { return false }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, wait.timeIntervalSinceNow) * 1_000_000_000))
                installHandler()
            }
            return true
        }
    }
}

/// "Check for Updates…", in the app menu and in Settings.
struct CheckForUpdatesButton: View {
    var body: some View {
        Button("Check for Updates…") { Updates.shared.checkForUpdates() }
            .disabled(Updates.shared.updater == nil)
    }
}
#endif
