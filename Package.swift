// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexBar", targets: ["CodexBar"])],
    targets: [
        .executableTarget(name: "CodexBar", path: "Sources/CodexBar"),
        .testTarget(name: "CodexBarTests", dependencies: ["CodexBar"])
    ]
)
