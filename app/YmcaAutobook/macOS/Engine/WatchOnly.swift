#if os(macOS)
import Foundation

/// "Don't book on this Mac": a second Mac (or a try-out) that signs in and shows
/// everything but acts on nothing. It never books, cancels or takes the iPhone's
/// requests, and never writes to iCloud or the GitHub backup, so the Mac that
/// books stays the only one doing it. Per Mac, off by default.
enum WatchOnly {
    static let key = "watchOnly"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}
#endif
