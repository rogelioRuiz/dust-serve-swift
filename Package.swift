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
        .package(url: "https://github.com/rogelioRuiz/dust-core-swift.git", from: "0.1.0"),
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
    ],
    swiftLanguageVersions: [.v5]
)
