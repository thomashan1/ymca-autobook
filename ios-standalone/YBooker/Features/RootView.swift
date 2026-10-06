import SwiftUI

struct RootView: View {
    @State private var signedIn = FisikalClient.hasCredentials

    var body: some View {
        if signedIn {
            TabView {
                BookingsView()
                    .tabItem { Label("Bookings", systemImage: "calendar") }
                WakeLogView()
                    .tabItem { Label("Wake log", systemImage: "bolt.horizontal") }
                SettingsView(signedIn: $signedIn)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
        } else {
            SignInView(signedIn: $signedIn)
        }
    }
}
