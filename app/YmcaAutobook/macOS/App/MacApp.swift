#if os(macOS)
import SwiftUI


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
