import Foundation
import RepoGuards
import Testing

/// NO NEW `shared` INSTANCE (#2519, `dev/engineering/ARCHITECTURE.md` § Dependency injection).
///
/// A type reached through `static let shared` / `static var shared` hides who
/// depends on it, and a test cannot hand it a stand-in. The composition root
/// builds what a feature needs and injects it (`ViewerStoreGuardTests` already
/// holds this for the viewer's stores). The instances that predate this rule
/// are in `baseline` and may only go away. A process-wide resource that holds
/// no viewer state (a render context, a hardware-bound player, a log) may be
/// shared: it goes in `processWide`, with the reason.
///
/// ⚠️ A FAILURE HERE IS EITHER A NEW `shared` — inject the instance instead,
/// or list it in `processWide` with its reason — OR ONE THAT WENT AWAY: lower
/// its file's count in `baseline` (or remove the file) in the same change.
struct SharedInstanceGuardTests {
    /// Files declaring a `shared` instance on 2026-11-21, and how many. A
    /// file's count may only go down.
    static let baseline: [String: Int] = [
        "App/Composition/AppContainer.swift": 1,
        "Packages/Core/CacheKit/Sources/CacheKit/UIAssetCaches.swift": 1,
        "Packages/Core/CoreNavigation/Sources/CoreNavigation/DrawerPull.swift": 1,
        "Packages/Core/CoreNavigation/Sources/DebugDashboard/ConsoleCapture.swift": 1,
        "Packages/Core/CoreNavigation/Sources/DebugDashboard/DebugInterfaceTools.swift": 3,
        "Packages/Core/CoreNavigation/Sources/DebugDashboard/FrameRateOverlay.swift": 1,
        "Packages/Core/CoreNavigation/Sources/Transitions/GrabFramePacing.swift": 1,
        "Packages/Core/CoreNavigation/Sources/Transitions/ZoomAnimator.swift": 1,
        "Packages/Core/CoreNavigation/Sources/Transitions/ZoomFlight.swift": 1,
        "Packages/Core/CoreNetworking/Sources/CoreNetworking/ConnectivityMonitor.swift": 1,
        "Packages/Core/CoreNetworking/Sources/CoreNetworking/NetworkLog.swift": 1,
        "Packages/Core/CoreNetworking/Sources/CoreNetworkingMocks/MockClipCatalog.swift": 1,
        "Packages/Core/CoreNetworking/Sources/CoreNetworkingMocks/MockPhotoCatalog.swift": 1,
        "Packages/Core/CoreNetworking/Sources/CoreNetworkingMocks/MockSongCatalog.swift": 1,
        "Packages/Core/CoreNetworking/Sources/CoreNetworkingMocks/MockVoiceCatalog.swift": 1,
        "Packages/Core/DebugTools/Sources/DebugTools/AccessoryCollapseAudit.swift": 1,
        "Packages/Core/DebugTools/Sources/DebugTools/DockTrace.swift": 1,
        "Packages/Core/DebugTools/Sources/DebugTools/HeroTransitionAudit.swift": 1,
        "Packages/Core/DebugTools/Sources/DebugTools/PillDragAudit.swift": 1,
        "Packages/Core/DebugTools/Sources/DebugTools/StatusBarBlurAudit.swift": 1,
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/LiquidLensRenderer.swift": 1,
        "Packages/Core/DesignSystem/Sources/DesignSystem/Foundation/HapticAudition.swift": 2,
        "Packages/Core/DesignSystem/Sources/DesignSystem/Foundation/IdleCalmMonitor.swift": 1,
        "Packages/Core/EmoteKit/Sources/EmoteKit/EmoteCatalog.swift": 1,
        "Packages/Core/EmoteKit/Sources/EmoteKit/EmoteEngine.swift": 1,
        "Packages/Core/EmoteKit/Sources/EmoteKit/EmoteLottieBaker.swift": 1,
        "Packages/Core/EmoteKit/Sources/EmoteKit/EmoteVisibility.swift": 1,
        "Packages/Core/EmoteKit/Sources/EmoteKit/Picker/EmoteKeyboardHeight.swift": 1,
        "Packages/Core/EmoteKit/Sources/EmoteKit/Picker/EmoteRecents.swift": 1,
        "Packages/Core/MediaCore/Sources/MediaCore/AnimatedAvatar/AnimatedAvatars.swift": 1,
        "Packages/Core/MediaPlayback/Sources/MediaPlayback/Editing/EditingRenderContext.swift": 1,
        "Packages/Core/MediaPlayback/Sources/MediaPlayback/Editing/OverlayRasterCache.swift": 1,
        "Packages/Core/MediaPlayback/Sources/MediaPlayback/FeedSoundSession.swift": 1,
        "Packages/Core/MediaPlayback/Sources/MediaPlayback/VideoFrameClock.swift": 1,
        "Packages/Core/MediaPlayback/Sources/MediaPlayback/VideoPlaybackController+PictureInPicture.swift": 1,
        "Packages/Core/PostGrid/Sources/PostGrid/Cells/LiveMediaBackdrop.swift": 1,
        "Packages/Core/StickerKit/Sources/StickerKit/StickerFrameBaker.swift": 1,
        "Packages/Core/VoiceKit/Sources/VoiceKit/VoiceAudioSession.swift": 1,
        "Packages/Core/VoiceKit/Sources/VoiceKit/VoiceFileCache.swift": 1,
        "Packages/Core/VoiceKit/Sources/VoiceKit/VoicePlayer.swift": 1,
        "Packages/Core/VoiceKit/Sources/VoiceKitUI/VoicePlaybackHub.swift": 1,
        "Packages/Features/Feed/Sources/Feed/Snap/MediaPlaybackPolicy.swift": 1,
        "Packages/Features/Maps/Sources/Maps/Countries/CountryAtlas.swift": 1,
        "Packages/Features/Maps/Sources/Maps/Views/MKAnnotationView+InstantTap.swift": 1,
        "Packages/Features/Upload/Sources/Upload/Views/MediaPickerViewController.swift": 1,
    ]

    /// `shared` instances allowed on purpose: a process-wide resource with no
    /// viewer state. Path → why it is shared.
    static let processWide: [String: String] = [:]

    @Test func noNewSharedInstance() throws {
        let found = try Self.counts()
        var problems: [String] = []
        for (path, count) in found.sorted(by: { $0.key < $1.key }) where Self.processWide[path] == nil {
            let allowed = Self.baseline[path] ?? 0
            if count > allowed {
                problems.append("\(path): \(count) `shared` (allowed \(allowed)) — inject the instance through the composition root, or list a process-wide resource in `processWide` with its reason")
            } else if count < allowed {
                problems.append("\(path): \(count), baseline \(allowed) — lower the baseline")
            }
        }
        for (path, allowed) in Self.baseline where found[path] == nil {
            problems.append("\(path): 0, baseline \(allowed) — remove it from the baseline")
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Every Swift source under `App/` and `Packages/` (tests left out), by
    /// repository-relative path, with how many `shared` instances it
    /// declares. Line comments are dropped first, so a comment that names
    /// the shape cannot fail the scan.
    private static func counts() throws -> [String: Int] {
        let regex = try Regex(#"static\s+(?:let|var)\s+shared\s*[:=]"#)
        let root = RepoRoot.url
        var result: [String: Int] = [:]
        for folder in ["App", "Packages"] {
            let base = root.appendingPathComponent(folder)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let path = url.resolvingSymlinksInPath().path
                guard !path.contains("/Tests/"), !path.contains("/.build/") else { continue }
                guard path.hasPrefix(root.path + "/") else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                    .joined(separator: "\n")
                let count = code.matches(of: regex).count
                if count > 0 { result[String(path.dropFirst(root.path.count + 1))] = count }
            }
        }
        return result
    }
}
