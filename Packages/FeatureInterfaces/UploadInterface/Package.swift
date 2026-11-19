// swift-tools-version: 6.0
import PackageDescription

// What the app opens from Upload (#2375): the "+" menu's screens. The shell
// reaches them through `UploadFeatureBuilding`; only the composition root
// names the Upload package.
let package = Package(
    name: "UploadInterface",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "UploadInterface", targets: ["UploadInterface"])
    ],
    dependencies: [
        // `PostEmbed`, the card a showcase post carries.
        .package(path: "../../Kit/CoreModels"),
        // `VideoSoundtrack`, the sound the camera opens with.
        .package(path: "../../Core/MediaPlayback")
    ],
    targets: [
        .target(name: "UploadInterface", dependencies: ["CoreModels", "MediaPlayback"])
    ]
)
