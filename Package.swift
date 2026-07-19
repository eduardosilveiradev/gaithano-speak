// swift-tools-version: 6.2
import PackageDescription

// The app is built as an SPM executable and then wrapped into a signed .app
// bundle by Scripts/build-app.sh. This is the reliable way to build the whole
// thing headlessly from the CLI; an .xcodeproj can be generated later for GUI work.
let package = Package(
    name: "GaithanoSpeak",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(path: "Packages/SpeakCore"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "GaithanoSpeak",
            dependencies: [
                .product(name: "SpeakCore", package: "SpeakCore"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "GaithanoSpeak",
            exclude: [
                "Info.plist",
                "GaithanoSpeak.entitlements",
                "Resources/Assets.xcassets"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
