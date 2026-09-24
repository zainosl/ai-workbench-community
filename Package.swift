// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AIWorkbenchNext",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AIWorkbenchCore", targets: ["AIWorkbenchCore"]),
        .executable(name: "AIWorkbenchNext", targets: ["AIWorkbenchNext"]),
        .executable(name: "AIWorkbenchCoreSelfTest", targets: ["AIWorkbenchCoreSelfTest"])
    ],
    targets: [
        .target(
            name: "AIWorkbenchCore",
            path: "Sources/AIWorkbenchCore"
        ),
        .executableTarget(
            name: "AIWorkbenchNext",
            dependencies: ["AIWorkbenchCore"],
            path: "Sources/AIWorkbenchNext"
        ),
        .executableTarget(
            name: "AIWorkbenchCoreSelfTest",
            dependencies: ["AIWorkbenchCore"],
            path: "Tests/AIWorkbenchCoreSelfTest"
        )
    ],
    swiftLanguageVersions: [.v5]
)
