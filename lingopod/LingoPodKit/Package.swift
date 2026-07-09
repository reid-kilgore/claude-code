// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LingoPodKit",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "LingoPodKit",
            targets: ["LingoPodKit"]
        )
    ],
    targets: [
        .target(
            name: "LingoPodKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "LingoPodKitTests",
            dependencies: ["LingoPodKit"],
            resources: [
                // M1: ships RSS/JSON fixtures with the test bundle (spec
                // §1). Also available for other modules' fixtures (e.g.
                // M3's SRT/VTT/JSON transcript samples).
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
