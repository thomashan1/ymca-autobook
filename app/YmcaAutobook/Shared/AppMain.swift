import SwiftUI

/// One app, two roles: on the Mac it books from the menu bar; on iPhone and
/// iPad it shows what the Mac (or GitHub) did. Under XCTest neither starts,
/// so the tests never log in, book or touch iCloud.
@main
enum AppMain {
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            TestHostApp.main()
            return
        }
        #if os(macOS)
        LegacySettings.migrate()
        MacApp.main()
        #else
        YmcaAutobookApp.main()
        #endif
    }
}

private struct TestHostApp: App {
    var body: some Scene {
        WindowGroup { Text("Running tests") }
    }
}
