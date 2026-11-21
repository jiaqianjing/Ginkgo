// swift-tools-version: 6.2
// UI-free logic for Ginkgo. Builds for macOS too, so `swift test` runs without a simulator.
import PackageDescription

let package = Package(
    name: "GinkgoKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "GinkgoCore", targets: ["GinkgoCore"]),
    ],
    targets: [
        .target(name: "GinkgoCore"),
        .testTarget(name: "GinkgoCoreTests", dependencies: ["GinkgoCore"]),
    ]
)
