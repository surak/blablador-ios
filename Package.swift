// swift-tools-version:5.9
// Unit tests for the app's logic on macOS: `swift test`. The app itself is built with Blablador.xcodeproj.
import PackageDescription

let package = Package(
    name: "Blablador",
    platforms: [.macOS(.v14)],
    targets: [
        // The app's sources without its entry point, as a library the tests can import.
        .target(
            name: "BlabladorCore",
            path: "Blablador/Blablador",
            exclude: ["BlabladorApp.swift", "Info.plist", "Blablador.entitlements", "Assets.xcassets"]
        ),
        .testTarget(name: "BlabladorTests", dependencies: ["BlabladorCore"], path: "Tests/BlabladorTests"),
    ]
)
