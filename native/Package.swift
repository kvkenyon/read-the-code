// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadTheCodeNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RTCContracts", targets: ["RTCContracts"]),
        .library(name: "RTCTestSupport", targets: ["RTCTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.6.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.6.0"),
    ],
    targets: [
        .target(name: "RTCContracts"),
        .target(name: "RTCTestSupport", dependencies: ["RTCContracts"], path: "Tests/RTCTestSupport"),
        .executableTarget(name: "RTCContractTests", dependencies: ["RTCContracts", "RTCTestSupport"], path: "Tests/RTCContractTests"),
    ]
)
