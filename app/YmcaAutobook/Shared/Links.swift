import Foundation

/// Where to get the other half of the app: the Mac download (Sparkle keeps it
/// current after that) and the TestFlight invite for iPhone and iPad.
enum Links {
    static let macDownload = URL(string: "https://github.com/thomashan1/ymca-autobook/releases/latest")!
    static let testFlight = URL(string: "https://testflight.apple.com/join/bg4rZECr")!
}
