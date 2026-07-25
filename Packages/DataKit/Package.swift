// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DataKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DataKit", targets: ["DataKit"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
    ],
    targets: [
        .target(
            name: "DataKit",
            dependencies: [
                .product(name: "Domain", package: "Domain"),
            ]
        ),
        .testTarget(
            name: "DataKitTests",
            dependencies: ["DataKit"]
        ),
    ]
)
