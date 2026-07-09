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
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
