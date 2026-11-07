// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LimLinkAppSupport",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LimLinkAppSupport", targets: ["LimLinkAppSupport"])],
    dependencies: [.package(path: "../../LimLinkKit")],
    targets: [
        .target(
            name: "LimLinkAppSupport",
            dependencies: [.product(name: "LimLinkCoreLogic", package: "LimLinkKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LimLinkAppSupportTests",
            dependencies: ["LimLinkAppSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
