// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LlamaCppMobile",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(name: "LlamaCppMobile", targets: ["llama"])
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10066/llama-b10066-xcframework.zip",
            checksum: "40ec2842e0ecdbc3b0792bea7aa0fb0e342e4a815b07723cd51e30bb206fa88f"
        )
    ]
)
