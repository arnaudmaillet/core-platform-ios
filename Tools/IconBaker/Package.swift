// swift-tools-version: 6.0
import PackageDescription

/// The publish-time icon baker.
///
/// Deliberately its OWN package, outside `Packages/`, and macOS-only: nothing
/// here ships. It turns designer-authored Lottie into what
/// `dev/issues/BACKEND_ANIMATED_PIN_ICONS.md` asks the backend to serve, so it
/// is the reference implementation of that contract as much as it is a tool —
/// if the pipeline is built elsewhere, this is what it has to agree with.
///
/// It uses lottie-ios, which the app already depends on (`Chat/Package.swift`),
/// and it uses it for the one job that library is genuinely good at here.
/// Measured earlier: lottie-ios needs 14.6 s of MAIN thread to rasterise 128
/// distinct 12-frame icons and crashed 3/3 attempts off-main. On a device that
/// disqualifies it. In a build step, running on the main thread of a process
/// that exists to do exactly this, it costs nothing anyone will notice.
let package = Package(
    name: "IconBaker",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.5.0")
    ],
    targets: [
        .executableTarget(
            name: "IconBaker",
            dependencies: [.product(name: "Lottie", package: "lottie-ios")]
        )
    ]
)
