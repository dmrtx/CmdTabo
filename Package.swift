// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CmdTabo",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CmdTabo", targets: ["CmdTabo"])],
    targets: [
        .target(name: "SwitcherCore", path: "Sources/SwitcherCore"),
        .executableTarget(name: "CmdTabo", dependencies: ["SwitcherCore"], path: "Sources/SwitcherApp"),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"], path: "Tests/SwitcherCoreTests")
    ]
)
