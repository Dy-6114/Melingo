// swift-tools-version: 6.0
import PackageDescription

/// Local open-weight adapter. Inference uses mlx-swift-lm when the Metal toolchain
/// can resolve it; otherwise the provider stays present and reports `providerUnavailable`
/// until weights + runtime are ready (never fabricates answers).
let package = Package(
    name: "MLXAdapter",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MLXAdapter", targets: ["MLXAdapter"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../AIKit"),
    ],
    targets: [
        .target(
            name: "MLXAdapter",
            dependencies: [
                .product(name: "Domain", package: "Domain"),
                .product(name: "AIKit", package: "AIKit"),
            ]
        ),
        .testTarget(
            name: "MLXAdapterTests",
            dependencies: [
                "MLXAdapter",
                .product(name: "Domain", package: "Domain"),
                .product(name: "AIKit", package: "AIKit"),
            ]
        ),
    ]
)
