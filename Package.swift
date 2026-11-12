// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

// A copy of the parts of Apple's FoundationModels that AgentKit and ClaudeForFoundationModels use,
// for platforms without Apple's. Depend on it only where Apple's isn't, as in:
//
//     #if !canImport(Darwin)
//     .package(url: "https://github.com/imben123/FoundationModelsLinux", exact: "...")
//     #endif
let package = Package(
    name: "FoundationModelsLinux",
    products: [
        .library(name: "FoundationModels", targets: ["FoundationModels"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        .target(
            name: "FoundationModels",
            dependencies: ["FoundationModelsMacros"]
        ),
        .macro(
            name: "FoundationModelsMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "FoundationModelsTests",
            dependencies: ["FoundationModels"]
        ),
    ]
)
