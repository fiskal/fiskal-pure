// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftDemo",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
    ],
    dependencies: [
        .package(path: "../../packages/swift"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftDemoApp",
            dependencies: [
                .product(name: "Antifragile", package: "swift"),
            ],
            path: "Sources/SwiftDemoApp"
        ),
    ]
)
