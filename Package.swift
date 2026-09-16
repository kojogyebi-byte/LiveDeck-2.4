// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LiveDeck",
    platforms: [.macOS(.v13)],
    targets: [
        // Presentation engine: model, library, songs, scripture (no UI; unit-tested)
        .target(
            name: "PresentationKit",
            path: "Sources/PresentationKit"
        ),
        // C bridge to the NDI® runtime (loaded at run time with dlopen; headers from the NDI SDK v6 for Apple)
        .target(
            name: "CNDI",
            path: "Sources/CNDI",
            exclude: ["ndi"],
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "LiveDeck",
            dependencies: ["PresentationKit", "CNDI"],
            path: "Sources/LiveDeck"
        ),
        .testTarget(
            name: "PresentationKitTests",
            dependencies: ["PresentationKit"],
            path: "Tests/PresentationKitTests"
        )
    ]
)
