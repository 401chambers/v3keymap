// swift-tools-version:6.0
import PackageDescription

// Command Line Tools only: the Swift Testing macro plugin is not always discovered by the build,
// so point the compiler at it explicitly.
let testingPlugin: [SwiftSetting] = [
    .unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])
]

let package = Package(
    name: "Keymap",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "ViaKit", resources: [.copy("Resources")]),
        .target(name: "KeymapCore", dependencies: ["ViaKit"]),
        .executableTarget(name: "KeymapApp", dependencies: ["KeymapCore"]),
        .testTarget(name: "KeymapCoreTests", dependencies: ["KeymapCore", "ViaKit", "ViaKitTestSupport"], swiftSettings: testingPlugin),
        .target(name: "ViaKitTestSupport", dependencies: ["ViaKit"], path: "Tests/ViaKitTestSupport", resources: [.copy("Fixtures")]),
        .testTarget(name: "ViaKitTests", dependencies: ["ViaKit", "ViaKitTestSupport"], swiftSettings: testingPlugin),
    ],
    swiftLanguageModes: [.v5]
)
