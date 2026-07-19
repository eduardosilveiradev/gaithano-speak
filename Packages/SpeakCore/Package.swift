// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpeakCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SpeakCore", targets: ["SpeakCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "SpeakCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SpeakCoreTests",
            dependencies: ["SpeakCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
