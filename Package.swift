// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LiveDeck",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LiveDeck", targets: ["LiveDeck"]),
        // used by the Mac App Store Xcode project (AppStore/project.yml)
        .library(name: "PresentationKit", targets: ["PresentationKit"]),
        .library(name: "CNDI", targets: ["CNDI"]),
        .library(name: "CDeckLink", targets: ["CDeckLink"])
    ],
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
        // C++ bridge to Blackmagic DeckLink / UltraStudio (DeckLink SDK 12 headers; driver loaded at run time)
        .target(
            name: "CDeckLink",
            path: "Sources/CDeckLink",
            exclude: ["sdk"],
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "LiveDeck",
            dependencies: ["PresentationKit", "CNDI", "CDeckLink"],
            path: "Sources/LiveDeck"
        ),
        .testTarget(
            name: "PresentationKitTests",
            dependencies: ["PresentationKit"],
            path: "Tests/PresentationKitTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)
