// swift-tools-version: 6.0
import PackageDescription

// LimLinkKit links Network and Security, which do not exist on Linux.
// The manifest is evaluated on the host, so Linux `swift test` builds only
// LimLinkCoreLogic. macOS and the iOS Simulator build both targets.
#if os(Linux)
let platformProducts: [Product] = []
let platformTargets: [Target] = []
#else
let platformProducts: [Product] = [
    .library(name: "LimLinkKit", targets: ["LimLinkKit"]),
]
let platformTargets: [Target] = [
    .target(
        name: "LimLinkKit",
        dependencies: ["LimLinkCoreLogic"],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
        name: "LimLinkKitTests",
        dependencies: ["LimLinkKit"],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
]
#endif

let package = Package(
    name: "LimLinkKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LimLinkCoreLogic", targets: ["LimLinkCoreLogic"]),
    ] + platformProducts,
    targets: [
        .target(
            name: "LimLinkCoreLogic",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LimLinkCoreLogicTests",
            dependencies: ["LimLinkCoreLogic"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ] + platformTargets
)
