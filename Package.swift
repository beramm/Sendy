// swift-tools-version: 6.0
import PackageDescription

// This package exists so the pipeline in SendSociety/Core can be built and
// tested from the command line on macOS. The iOS app target compiles the same
// files directly via its file-system-synchronized group — the package is a
// second view onto the same sources, not a dependency of the app.
let package = Package(
    name: "VideoOverlapCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VideoOverlapCore", targets: ["VideoOverlapCore"])
    ],
    dependencies: [
        // Same ONNX Runtime the app target uses, so the RTMPose extractor can be
        // exercised from the command line and checked against the Python
        // implementation numericallyrather than trusted.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.0")
    ],
    targets: [
        .target(
            name: "VideoOverlapCore",
            path: "SendSociety/Core",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VideoOverlapRTMPose",
            dependencies: [
                "VideoOverlapCore",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
            ],
            path: "SendSociety/App/Pose",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "posecli",
            dependencies: ["VideoOverlapCore", "VideoOverlapRTMPose"],
            path: "Tools/PoseCLI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VideoOverlapCoreTests",
            dependencies: ["VideoOverlapCore"],
            path: "Tests/VideoOverlapCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
