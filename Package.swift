// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyLlamaSpeechAssistant",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Dependencies/speech-swift"),
    ],
    targets: [
        .executableTarget(
            name: "MyLlamaSpeechAssistant",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
            ],
            path: "Sources",
            exclude: ["LlamaStreamingDemo.entitlements", "Info.plist", "OpenCodeTest.swift"],
            linkerSettings: [
                .linkedFramework("MediaPlayer"),
            ]
        ),
        .executableTarget(
            name: "OpenCodeTest",
            path: "Sources",
            sources: ["OpenCodeTest.swift"],
            linkerSettings: [
            ]
        ),
    ]
)
