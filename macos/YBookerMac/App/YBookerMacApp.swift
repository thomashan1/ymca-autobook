import SwiftUI

@main
struct YBookerMacApp: App {
    @StateObject private var engine = Engine()

    var body: some Scene {
        MenuBarExtra {
            MenuView(engine: engine)
        } label: {
            Image(systemName: "figure.strengthtraining.traditional")
        }
        .menuBarExtraStyle(.window)

        Window("Y Booker — Booking log", id: "log") {
            LogView(engine: engine)
        }
        .defaultSize(width: 900, height: 520)

        Window("Y Booker — Settings", id: "settings") {
            SettingsView(engine: engine)
        }
        .windowResizability(.contentMinSize)
    }
}
