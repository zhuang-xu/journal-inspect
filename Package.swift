// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JournalInspect", platforms: [.macOS(.v14)],
    products: [
        .library(name: "JournalCore", targets: ["JournalCore"]),
        .library(name: "JournalEmbeddings", targets: ["JournalEmbeddings"]),
        .library(name: "JournalGeneration", targets: ["JournalGeneration"]),
    ],
    targets: [
        .target(name: "JournalCore"),
        .binaryTarget(
            name: "LlamaFramework", path: "vendor/llama.cpp/build-apple/llama.xcframework"),
        .target(name: "JournalLlama", dependencies: ["LlamaFramework"]),
        .target(
            name: "JournalEmbeddings",
            dependencies: ["JournalCore", "LlamaFramework", "JournalLlama"]),
        .target(
            name: "JournalGeneration",
            dependencies: ["JournalCore", "LlamaFramework", "JournalLlama"]),
        .testTarget(
            name: "JournalGenerationTests", dependencies: ["JournalGeneration", "JournalCore"]),
        .testTarget(name: "JournalEmbeddingsTests", dependencies: ["JournalEmbeddings"]),
        .testTarget(
            name: "JournalCoreTests",
            dependencies: ["JournalCore", "JournalEmbeddings", "JournalGeneration"]),
    ])
