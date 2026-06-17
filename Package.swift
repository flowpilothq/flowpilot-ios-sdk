// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FlowPilotSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "FlowPilotSDK",
            targets: ["FlowPilotSDK"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-ios.git", .upToNextMajor(from: "4.5.0"))
    ],
    targets: [
        .target(
            name: "FlowPilotSDK",
            dependencies: [
                .product(name: "Lottie", package: "lottie-ios")
            ],
            path: "Sources/FlowPilotSDK",
            resources: [
                // Apple-required privacy manifest, copied verbatim into the
                // resource bundle so apps integrating the SDK pass App Store review.
                .copy("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
