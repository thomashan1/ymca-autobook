#if os(macOS)
import SwiftUI

/// A regular Mac app (Dock icon, opens its window like any other app) with a
/// menu bar extra for a glance at the next opening. Closing the window doesn't
/// quit, so booking carries on; only Quit stops it.
struct MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = Engine()

    var body: some Scene {
        MenuBarExtra {
            MenuView(engine: engine)
        } label: {
            MenuBarIcon(engine: engine)
        }
        .menuBarExtraStyle(.window)

        Window("YMCA Booker", id: "main") {
            SettingsView(engine: engine)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        }
    }
}

/// The menu bar icon. It's the one view that exists from launch on, so it's
/// where the app gets hold of SwiftUI's openWindow for the Dock and launch.
private struct MenuBarIcon: View {
    let engine: Engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "figure.strengthtraining.traditional")
            .task {
                Updates.shared.engine = engine   // starts the daily update check
                MainWindow.open = {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                if MainWindow.showAtLaunch { MainWindow.open?() }
                if MacSample.active, let dir = UserDefaults.standard.string(forKey: "screenshotDir") {
                    await MacSample.captureAndQuit(to: dir)
                }
            }
    }
}

/// Opens the app's window. SwiftUI shows neither at launch nor on a Dock
/// click when a menu bar extra is the first scene, so this does both.
enum MainWindow {
    @MainActor static var open: (() -> Void)?

    /// Not when macOS starts the app at login: the booker should just run.
    /// Set from the launch event, which is only readable while launching.
    @MainActor static var showAtLaunch = true
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor func applicationWillFinishLaunching(_ notification: Notification) {
        if let e = NSAppleEventManager.shared().currentAppleEvent, e.eventID == kAEOpenApplication,
           e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            MainWindow.showAtLaunch = false
        }
    }

    /// A click on the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainWindow.open?() }
        return true
    }
}
#endif
