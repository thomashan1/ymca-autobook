// swift-tools-version:5.9
// Sparkle (sparkle-project.org), the Mac app's updater. scripts/fetch_sparkle.sh puts the
// official framework next to this file; it isn't checked in.
import PackageDescription

let package = Package(
    name: "Sparkle",
    platforms: [.macOS(.v10_13)],
    products: [.library(name: "Sparkle", targets: ["Sparkle"])],
    targets: [.binaryTarget(name: "Sparkle", path: "Sparkle.xcframework")]
)
