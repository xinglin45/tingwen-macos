// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ListenText",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ListenText", targets: ["ListenText"])],
    targets: [
        .target(name: "ReaderCore"),
        .executableTarget(name: "ListenText", dependencies: ["ReaderCore"]),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"])
    ]
)
