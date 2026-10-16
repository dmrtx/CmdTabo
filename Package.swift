// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CmdTabo",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CmdTabo", targets: ["CmdTabo"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "SwitcherCore", path: "Sources/SwitcherCore"),
        .executableTarget(name: "CmdTabo", dependencies: ["SwitcherCore", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/SwitcherApp"),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"], path: "tests/SwitcherCoreTests"),
        .testTarget(name: "SwitcherAppTests", dependencies: ["CmdTabo"], path: "tests/SwitcherAppTests")
    ]
)
