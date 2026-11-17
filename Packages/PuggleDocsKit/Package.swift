// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PuggleDocsKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PuggleDocsKit", targets: ["PuggleDocsKit"]),
    ],
    targets: [
        .target(name: "PuggleDocsKit"),
        .testTarget(name: "PuggleDocsKitTests", dependencies: ["PuggleDocsKit"]),
    ]
)
