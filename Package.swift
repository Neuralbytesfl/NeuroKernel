// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NeuroKernel",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "neurok", targets: ["NeuroKernel"])
    ],
    dependencies: [
        // AUTO-IMPROVEMENT: provide cross-platform SHA256 on Linux where CryptoKit is unavailable.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .executableTarget(
            name: "NeuroKernel",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            exclude: [
                "MANUAL.md"
            ],
            swiftSettings: [
                // Enable extra safety during development if you like:
                // .unsafeFlags(["-Xfrontend", "-warn-concurrency"])
            ]
        )
    ]
)
