#if os(macOS)
import SwiftUI

/// A Book or Cancel clicked on this Mac: what's happening now, then how it went.
struct BookingActivity: Identifiable, Equatable {
    struct Result: Equatable {
        let ok: Bool
        let message: String
    }
    let id: Int            // occurrence id
    let cancelling: Bool
    let what: String       // "Cycle Sculpt · Thu, 12/3, 10:15 AM"
    var step = "Starting…"
    var result: Result?

    /// The booking log's outcome, said for a person: "not booked — HTTP 422"
    /// becomes a sentence, and a reason the YMCA gave is kept.
    static func reason(_ verdict: String) -> String {
        var s = verdict
        for prefix in ["not booked — ", "error — "] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("gave up after") {
            return "The YMCA turned down every try without saying why (\(s)). The session may have been changed or closed to bookings."
        }
        if s.contains("full") || s.contains("no_spaces") { return "The class is full." }
        return s.prefix(1).uppercased() + s.dropFirst() + (s.hasSuffix(".") ? "" : ".")
    }
}

struct BookingActivitySheet: View {
    let activity: BookingActivity
    let done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let r = activity.result {
                    Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundColor(r.ok ? .green : .orange)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(height: 40)
            Text(title).font(.headline)
            Text(activity.what).foregroundColor(.secondary)
            Text(activity.result?.message ?? activity.step)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
            Button(activity.result == nil ? "Hide" : "OK", action: done)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
            if activity.result == nil {
                Text("Booking keeps going if you hide this.")
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
            }
        }
        .padding(24)
        // One size for every step, so the window never has to resize.
        .frame(width: 400, height: 300)
    }

    private var title: String {
        switch (activity.cancelling, activity.result?.ok) {
        case (false, nil): return "Booking…"
        case (false, true?): return "Booked"
        case (false, false?): return "Couldn't book"
        case (true, nil): return "Cancelling…"
        case (true, true?): return "Cancelled"
        case (true, false?): return "Couldn't cancel"
        }
    }
}
#endif

#if os(macOS)
import AppKit
import Combine

/// Shows the booking dialog in its own small window in front of everything.
/// A sheet on the main window waited behind the popover or sheet the click
/// came from (macOS shows one sheet per window at a time).
@MainActor
final class BookingActivityPanel: NSObject, NSWindowDelegate {
    static let shared = BookingActivityPanel()
    private var panel: NSPanel?
    private var watching: AnyCancellable?
    private weak var engine: Engine?

    func watch(_ engine: Engine) {
        self.engine = engine
        watching = engine.$activity.receive(on: RunLoop.main).sink { [weak self] a in self?.show(a) }
    }

    private func show(_ a: BookingActivity?) {
        guard let a else { panel?.close(); panel = nil; return }
        let view = BookingActivitySheet(activity: a) { [weak self] in self?.engine?.activity = nil }
        if let panel {
            (panel.contentViewController as? NSHostingController<BookingActivitySheet>)?.rootView = view
            return
        }
        let p = NSPanel(contentViewController: NSHostingController(rootView: view))
        p.styleMask = [.titled, .closable]
        p.title = "YMCA Booker"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.delegate = self
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) ?? NSApp.mainWindow {
            let f = main.frame, s = p.frame.size
            p.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: f.midY - s.height / 2))
        } else {
            p.center()
        }
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    /// The close button does what OK / Hide do.
    func windowWillClose(_ notification: Notification) {
        panel = nil
        if engine?.activity != nil { engine?.activity = nil }
    }
}
#endif
