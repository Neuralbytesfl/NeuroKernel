// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NeuroKernel",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "neurok", targets: ["NeuroKernel"])
    ],
    targets: [
        .executableTarget(
            name: "NeuroKernel",
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
