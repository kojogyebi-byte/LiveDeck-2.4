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
        .executableTarget(
            name: "LiveDeck",
            dependencies: ["PresentationKit"],
            path: "Sources/LiveDeck"
        ),
        .testTarget(
            name: "PresentationKitTests",
            dependencies: ["PresentationKit"],
            path: "Tests/PresentationKitTests"
        )
    ]
)
