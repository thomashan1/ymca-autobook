import ServiceManagement
import SwiftUI

@main
struct YBookerMacApp: App {
    init() {
        // Replaced by the combined YMCA Booker app (main, app/). Once retired, this
        // copy takes itself out of Login Items and quits whenever it's started.
        if UserDefaults.standard.bool(forKey: "retired") {
            try? SMAppService.mainApp.unregister()
            exit(0)
        }
    }

    @StateObject private var engine = Engine()

    var body: some Scene {
        MenuBarExtra {
            MenuView(engine: engine)
        } label: {
            Image(systemName: "figure.strengthtraining.traditional")
        }
        .menuBarExtraStyle(.window)

        Window("YMCA Booker — Booking log", id: "log") {
            LogView(engine: engine)
        }
        .defaultSize(width: 900, height: 520)

        Window("YMCA Booker — Settings", id: "settings") {
            SettingsView(engine: engine)
        }
        .windowResizability(.contentMinSize)
    }
}
