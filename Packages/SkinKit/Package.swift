// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkinKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkinKit", targets: ["SkinKit"]),
        .library(name: "SkinLibrary", targets: ["SkinLibrary"]),
        .library(name: "SkinBrowser", targets: ["SkinBrowser"]),
        .executable(name: "skintool", targets: ["skintool"]),
        .library(name: "WindowDocking", targets: ["WindowDocking"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "SkinKit",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        // Folder index in SQLite (system libsqlite3). Depends on SkinKit only; no UI, no audio, no network.
        .target(name: "SkinLibrary", dependencies: ["SkinKit"], linkerSettings: [.linkedLibrary("sqlite3")]),
        // Skins window and Skins menu view models. Foundation + Observation + CoreGraphics; no UI, no audio.
        .target(name: "SkinBrowser", dependencies: ["SkinLibrary", "SkinKit"]),
        .testTarget(name: "SkinBrowserTests", dependencies: ["SkinBrowser", "SkinLibrary", "SkinKit"]),
        .executableTarget(name: "skintool", dependencies: ["SkinKit", "SkinLibrary"]),
        // ZIPFoundation here so tests can write synthetic .wsz archives (#0043).
        .testTarget(name: "SkinKitTests", dependencies: ["SkinKit", .product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        // ZIPFoundation here so tests can write synthetic .wsz archives.
        .testTarget(
            name: "SkinLibraryTests",
            dependencies: ["SkinLibrary", "SkinKit", .product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        .target(name: "WindowDocking"),
        .testTarget(name: "WindowDockingTests", dependencies: ["WindowDocking"]),
    ]
)
