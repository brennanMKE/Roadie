// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkinKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkinKit", targets: ["SkinKit"]),
        .executable(name: "skintool", targets: ["skintool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "SkinKit",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        .executableTarget(name: "skintool", dependencies: ["SkinKit"]),
        .testTarget(name: "SkinKitTests", dependencies: ["SkinKit"]),
    ]
)
