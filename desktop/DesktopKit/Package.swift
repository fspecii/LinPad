// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DesktopKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "DesktopKit", targets: ["DesktopKit"]),
    ],
    targets: [
        .target(name: "DesktopKit", resources: [.copy("Resources/Wallpapers"), .copy("Resources/ColorThemes")]),
        .testTarget(name: "DesktopKitTests", dependencies: ["DesktopKit"], exclude: ["Fixtures"]),
    ]
)
