// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mac-voice-dictation",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VoiceDictation", targets: ["VoiceDictation"]),
        .library(name: "DictationCore", targets: ["DictationCore"]),
    ],
    targets: [
        // Pure, headless-testable logic: WAV encoding, whisper HTTP client,
        // config model, and the scoped TLS trust delegate. No AppKit here so it
        // stays unit-testable and free of UI/permission side effects.
        .target(
            name: "DictationCore"
        ),
        // The AppKit menu-bar application. Depends on DictationCore for all the
        // logic that can be exercised without a UI.
        .executableTarget(
            name: "VoiceDictation",
            dependencies: ["DictationCore"]
        ),
        .testTarget(
            name: "DictationCoreTests",
            dependencies: ["DictationCore"]
        ),
    ]
)
