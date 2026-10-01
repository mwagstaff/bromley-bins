// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BinsCore",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "BinsCore", targets: ["BinsCore"]),
    ],
    targets: [
        .target(
            name: "BinsCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BinsCoreTests",
            dependencies: ["BinsCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
