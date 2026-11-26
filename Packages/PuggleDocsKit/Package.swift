// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PuggleDocsKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PuggleDocsKit", targets: ["PuggleDocsKit"]),
        // Keeping the app up to date: shared by the app and its update installer service.
        .library(name: "PuggleUpdate", targets: ["PuggleUpdate"]),
    ],
    targets: [
        .target(name: "PuggleDocsKit"),
        .target(name: "PuggleUpdate"),
        .testTarget(name: "PuggleDocsKitTests", dependencies: ["PuggleDocsKit"]),
        .testTarget(name: "PuggleUpdateTests", dependencies: ["PuggleUpdate"]),
    ]
)
