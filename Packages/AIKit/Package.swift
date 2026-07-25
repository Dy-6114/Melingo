// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AIKit", targets: ["AIKit"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../SharedTestSupport"),
    ],
    targets: [
        .target(
            name: "AIKit",
            dependencies: [
                .product(name: "Domain", package: "Domain"),
            ]
        ),
        .testTarget(
            name: "AIKitTests",
            dependencies: [
                "AIKit",
                .product(name: "Domain", package: "Domain"),
                .product(name: "SharedTestSupport", package: "SharedTestSupport"),
            ]
        ),
    ]
)
