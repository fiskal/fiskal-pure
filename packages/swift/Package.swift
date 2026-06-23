// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StatelessUI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "StatelessUI",
            targets: ["StatelessUI"]
        )
    ],
    targets: [
        .target(
            name: "StatelessUI",
            path: "Sources/StatelessUI"
        ),
        .testTarget(
            name: "StatelessUITests",
            dependencies: ["StatelessUI"],
            path: "Tests/StatelessUITests"
        )
    ]
)
