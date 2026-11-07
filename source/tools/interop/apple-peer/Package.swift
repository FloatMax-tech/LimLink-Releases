// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LimLinkInteropPeer",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../apple/LimLinkKit")],
    targets: [.executableTarget(name: "LimLinkInteropPeer", dependencies: [.product(name: "LimLinkKit", package: "LimLinkKit")])]
)
