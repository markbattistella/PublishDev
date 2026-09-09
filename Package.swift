// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PublishDev",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "publish-dev", targets: ["PublishDev"])],
    targets: [
        .executableTarget(name: "PublishDev"),
        .testTarget(name: "PublishDevTests", dependencies: ["PublishDev"]),
    ]
)
