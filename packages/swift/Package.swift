// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Antifragile",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "Antifragile",
            targets: ["Antifragile"]
        )
    ],
    targets: [
        .target(
            name: "Antifragile",
            path: "Sources/Antifragile"
        ),
        .testTarget(
            name: "AntifragileTests",
            dependencies: ["Antifragile"],
            path: "Tests/AntifragileTests"
        )
    ]
)
