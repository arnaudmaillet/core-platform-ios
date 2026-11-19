// swift-tools-version: 6.0
import PackageDescription

// The profile's and the account's data (#2382, stage 3): the repositories the
// app builds (`ProfileRepository`, `AccountRepository`, the sessions, the
// gallery, the relationships…), the capability protocols they answer and
// their value types, with the two pieces of UI the profile and Settings both
// draw (`RelationshipListCell`, `EditFieldViewController`) and the
// relationship list's model.
//
// Profile and Settings both read it, and a feature never depends on another
// feature, so it is a package of its own under both. It sits in this layer,
// not in Core, for one reason: the repositories resolve the viewer through
// AuthInterface's session (`AuthSessionProviding`, `ViewerProviding`,
// `ViewerScoped`) and Settings → Passkeys speaks its request types. Moving
// those down to Core is what would let this package follow.
let package = Package(
    name: "ProfileData",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "ProfileData", targets: ["ProfileData"])
    ],
    dependencies: [
        .package(path: "../../Kit/CoreContracts"),
        .package(path: "../../Kit/CoreModels"),
        .package(path: "../../FeatureInterfaces/AuthInterface"),
        .package(path: "../../Core/CacheKit"),
        .package(path: "../../Core/CoreNavigation"),
        .package(path: "../../Core/CoreNetworking"),
        .package(path: "../../Core/CoreStorage"),
        .package(path: "../../Core/DesignSystem"),
        // The relationship lists on the device (#1776).
        .package(path: "../../Core/LocalStore"),
        .package(path: "../../Core/MediaCore"),
        .package(path: "../../Core/PostGrid"),
        .package(path: "../../Core/ShareSheet"),
        // Tests only: the follow channel's suite drives the app's EntityStore
        // and the post surfaces' rows.
        .package(path: "../../Core/EntityStore"),
        .package(path: "../../Core/PostSurfaces")
    ],
    targets: [
        .target(
            name: "ProfileData",
            dependencies: [
                "CoreContracts",
                "CoreModels",
                "AuthInterface",
                "CacheKit",
                "CoreNavigation",
                "CoreNetworking",
                "CoreStorage",
                "DesignSystem",
                "LocalStore",
                "MediaCore",
                .product(name: "MediaUI", package: "MediaCore"),
                "PostGrid",
                "ShareSheet"
            ]
        ),
        .testTarget(
            name: "ProfileDataTests",
            dependencies: [
                "ProfileData",
                "AuthInterface",
                "CoreContracts",
                "CoreModels",
                "CoreNetworking",
                .product(name: "CoreNetworkingMocks", package: "CoreNetworking"),
                "CoreStorage",
                "EntityStore",
                "LocalStore",
                "MediaCore",
                "PostGrid",
                "PostSurfaces"
            ]
        )
    ]
)
