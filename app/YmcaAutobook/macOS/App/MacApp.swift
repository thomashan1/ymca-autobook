#if os(macOS)
import SwiftUI

/// A regular Mac app (Dock icon, opens its window like any other app) with a
/// menu bar extra for a glance at the next opening. Closing the window doesn't
/// quit, so booking carries on; only Quit stops it.
struct MacApp: App {
    @StateObject private var engine = Engine()

    var body: some Scene {
        MenuBarExtra {
            MenuView(engine: engine)
        } label: {
            Image(systemName: "figure.strengthtraining.traditional")
        }
        .menuBarExtraStyle(.window)

        Window("YMCA Booker", id: "main") {
            SettingsView(engine: engine)
        }
        .windowResizability(.contentMinSize)
    }
}
#endif
