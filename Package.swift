// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "dust-serve-swift",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(
            name: "DustServe",
            targets: ["DustServe"]
        )
    ],
    dependencies: [
        .package(name: "dust-core-swift", path: "../dust-core-swift"),
    ],
    targets: [
        .target(
            name: "DustServe",
            dependencies: [
                .product(name: "DustCore", package: "dust-core-swift"),
            ],
            path: "Sources/DustServe"
        ),
        .testTarget(
            name: "DustServeTests",
            dependencies: ["DustServe"],
            path: "Tests/DustServeTests"
        )
    ]
)
