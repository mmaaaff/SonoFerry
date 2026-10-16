// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SonoFerry", platforms: [.macOS("26.0")], products: [
    .library(name: "SonoFerryCore", targets: ["SonoFerryCore"])
], targets: [
    .target(name: "SonoFerryCore", path: "Sources/Core"),
    .testTarget(name: "CoreTests", dependencies: ["SonoFerryCore"], path: "Tests/CoreTests")
])
