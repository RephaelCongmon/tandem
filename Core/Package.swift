// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TandemCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TandemCore", targets: ["TandemCore"]),
        .library(name: "TandemUI", targets: ["TandemUI"])
    ],
    targets: [
        // Networking, security, media, AI clients, markdown parsing. No SwiftUI.
        .target(
            name: "TandemCore",
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        // Reusable SwiftUI/AppKit components: design system, markdown view,
        // snapshot markup editor, global hotkeys.
        .target(
            name: "TandemUI",
            dependencies: ["TandemCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(name: "TandemCoreTests", dependencies: ["TandemCore"]),
        .testTarget(name: "TandemUITests", dependencies: ["TandemUI"])
    ],
    swiftLanguageModes: [.v5]
)
