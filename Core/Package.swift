// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TandemCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TandemCore", targets: ["TandemCore"]),
        .library(name: "TandemUI", targets: ["TandemUI"])
    ],
    dependencies: [
        // On-device Parakeet speech recognition (Core ML). Pinned to a commit: the 0.9.1 tag
        // doesn't build with Swift 6.3. No traits: Tandem only transcribes, so it leaves out
        // FluidAudio's NeMo text-normalization engine (a large prebuilt library for TTS/ITN).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "8145085136df11758cc1303ab54d8e032c12bd41", traits: [])
    ],
    targets: [
        // Networking, security, media, speech, AI clients, markdown parsing. No SwiftUI.
        .target(
            name: "TandemCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("Speech")
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
