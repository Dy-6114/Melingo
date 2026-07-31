// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TelegramKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TelegramKit", targets: ["TelegramKit"]),
        .executable(name: "telegram-export", targets: ["TelegramRemoteExporter"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/Swiftgram/TDLibKit.git",
            exact: "1.5.2-tdlib-1.8.66-d8d46dfa"
        ),
    ],
    targets: [
        .target(
            name: "TelegramKit",
            dependencies: [
                .product(name: "TDLibKit", package: "TDLibKit"),
            ]
        ),
        .executableTarget(
            name: "TelegramRemoteExporter",
            dependencies: ["TelegramKit"]
        ),
        .testTarget(
            name: "TelegramKitTests",
            dependencies: ["TelegramKit"]
        ),
    ]
)
