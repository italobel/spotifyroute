// swift-tools-version:6.0
import PackageDescription

// Swift 5 language mode is deliberate. Real-time Core Audio IOProc callbacks use
// patterns that predate strict concurrency; Swift 6 mode would demand a scattering of
// @unchecked Sendable annotations for no real safety gain in a design where shared
// state is already guarded by an explicit lock.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "SpotifyRoute",
    // 14.2 exactly, not 14.0: that is where AudioHardwareCreateProcessTap landed.
    // Declaring 14.0 would force an #available guard around every tap call.
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "SpotifyRouteCore", swiftSettings: swift5),
        .executableTarget(name: "SpotifyRouteApp",
                          dependencies: ["SpotifyRouteCore"], swiftSettings: swift5),
        .executableTarget(name: "spotroute",
                          dependencies: ["SpotifyRouteCore"], swiftSettings: swift5),
        .executableTarget(name: "SpotifyRouteTests",
                          dependencies: ["SpotifyRouteCore"], swiftSettings: swift5),
    ]
)
