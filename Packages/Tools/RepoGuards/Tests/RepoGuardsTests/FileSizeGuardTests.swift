import Foundation
import RepoGuards
import Testing

/// NO SOURCE FILE PAST 1,000 LINES MAY GROW (#2519, `dev/engineering/COMPONENTS.md` § Sizes).
///
/// A new file stays at or under 1,000 lines. A file that was already past
/// 1,000 lines on 2026-11-21 is in `baseline` with its length then, and may
/// only get shorter: split what a change adds into a new type, a collaborator
/// behind a host protocol (ADR 0011) or an extension in its own file.
/// Generated contracts (`/Generated/`) and tests are left out.
///
/// ⚠️ A FAILURE HERE IS EITHER A FILE THAT GREW — move what you added into a
/// new type — OR A FILE THAT GOT SHORTER: lower its number below to the new
/// length (or remove it once it is at or under 1,000) in the same change, so
/// the baseline keeps shrinking.
struct FileSizeGuardTests {
    /// The most lines a source file may have, unless it is in `baseline`.
    static let limit = 1_000

    /// Files past `limit` on 2026-11-21, with their length (newlines, as
    /// `wc -l` counts them). A file's number may only go down.
    static let baseline: [String: Int] = [
        "Packages/Core/CoreNavigation/Sources/Transitions/InteractiveSlideDismissal.swift": 1194,
        "Packages/Core/CoreNavigation/Sources/Transitions/RevealTransition.swift": 2011,
        "Packages/Core/CoreNavigation/Sources/Transitions/ZoomAnimator.swift": 1655,
        "Packages/Core/CoreNavigation/Sources/Transitions/ZoomDismissInteractionController.swift": 1291,
        "Packages/Core/CoreNetworking/Sources/CoreNetworkingMocks/MockEngagementServices.swift": 1114,
        "Packages/Core/CoreNetworking/Sources/CoreNetworkingMocks/MockSocialDataset.swift": 1189,
        "Packages/Core/CoreNetworking/Sources/CoreNetworkingMocks/MockSocialServices.swift": 1330,
        "Packages/Core/CoreStorage/Sources/CoreStorage/WalletStore.swift": 1430,
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/AppButton.swift": 1437,
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/HeroBannerFade.swift": 1365,
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/PagedTabBar.swift": 3076,
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/PressFeedback.swift": 1019,
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/SelectorLiquidLens.swift": 1167,
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/ToastView.swift": 2138,
        "Packages/Core/HeroPage/Sources/HeroPage/HeroHeaderView.swift": 2065,
        "Packages/Core/MediaPlayback/Sources/MediaPlayback/VideoExporter.swift": 1194,
        "Packages/Core/MediaPlayback/Sources/MediaPlayback/VideoPlaybackController+Lookahead.swift": 1056,
        "Packages/Core/MediaPlayback/Sources/MediaPlayback/VideoPlaybackController.swift": 1746,
        "Packages/Core/MediaPlayback/Sources/MediaPlayback/VideoRenderView.swift": 1246,
        "Packages/Core/PostGrid/Sources/PostGrid/Cells/MediaCarouselView.swift": 1625,
        "Packages/Core/PostGrid/Sources/PostGrid/Cells/PostGridCells.swift": 1341,
        "Packages/Core/PostGrid/Sources/PostGrid/Cells/PostHistoryRowCell.swift": 1116,
        "Packages/Core/PostGrid/Sources/PostGrid/Playback/GridVideoPlaybackCoordinator.swift": 1650,
        "Packages/Core/PostSurfaces/Sources/PostSurfaces/Grid/PostGridFlightCard.swift": 1084,
        "Packages/Core/PostSurfaces/Sources/PostSurfaces/Grid/PostGridPageView.swift": 4727,
        "Packages/Core/PostSurfaces/Sources/PostSurfaces/Grid/Shelf/PostShelf/PostShelfSection.swift": 1416,
        "Packages/Core/ShareSheet/Sources/ShareSheet/ShareSheetViewController.swift": 1030,
        "Packages/Core/ThreadKit/Sources/ThreadKit/CommentRowView.swift": 1770,
        "Packages/Core/ThreadKit/Sources/ThreadKit/CommentsInputBar.swift": 3133,
        "Packages/Core/VoiceKit/Sources/VoiceKitUI/VoiceView.swift": 2271,
        "Packages/Features/Chat/Sources/Chat/Data/ChatRepository.swift": 1044,
        "Packages/Features/Chat/Sources/Chat/Thread/ConversationThreadViewController.swift": 3021,
        "Packages/Features/Feed/Sources/Feed/PostDetail/CommentStream.swift": 2495,
        "Packages/Features/Feed/Sources/Feed/PostDetail/PostDetailViewController.swift": 1121,
        "Packages/Features/Feed/Sources/Feed/PostDetail/PostDetailViewModel.swift": 1388,
        "Packages/Features/Feed/Sources/Feed/Snap/SnapChromeView.swift": 1176,
        "Packages/Features/Feed/Sources/Feed/Snap/SnapCommentTickerView.swift": 1311,
        "Packages/Features/Feed/Sources/Feed/Snap/SnapCommentsCoordinator.swift": 1097,
        "Packages/Features/Feed/Sources/Feed/Snap/SnapCommentsSheet.swift": 2212,
        "Packages/Features/Feed/Sources/Feed/Snap/SnapFeedCell.swift": 1485,
        "Packages/Features/Feed/Sources/Feed/Snap/SnapFeedViewController.swift": 3035,
        "Packages/Features/Feed/Sources/Feed/Snap/SnapMediaCardView.swift": 1246,
        "Packages/Features/Feed/Sources/Feed/Snap/SnapMediaPageBarView.swift": 1445,
        "Packages/Features/Feed/Sources/Feed/Snap/Sound/SoundSheetViewController.swift": 2477,
        "Packages/Features/Maps/Sources/Maps/Countries/ShopStorefrontViewController.swift": 1566,
        "Packages/Features/Maps/Sources/Maps/MapsViewController+MapViewDelegate.swift": 1121,
        "Packages/Features/Maps/Sources/Maps/MapsViewController.swift": 1071,
        "Packages/Features/Maps/Sources/Maps/Views/MapSubFilterBarView.swift": 1032,
        "Packages/Features/Maps/Sources/Maps/Views/PinCardView.swift": 2094,
        "Packages/Features/Place/Sources/Place/PlaceProfileViewController.swift": 2577,
        "Packages/Features/Profile/Sources/Profile/Views/ProfileViewController.swift": 1170,
        "Packages/Features/Search/Sources/Search/ViewModels/SearchViewModel.swift": 1239,
        "Packages/Features/Search/Sources/Search/Views/SearchResultsViewController.swift": 1021,
        "Packages/Features/Search/Sources/Search/Views/SearchViewController.swift": 1213,
        "Packages/Features/Settings/Sources/Settings/Views/Settings/TwoStepViewController.swift": 1056,
        "Packages/Features/Upload/Sources/Upload/Capture/CaptureViewController.swift": 2004,
        "Packages/Features/Upload/Sources/Upload/Data/MediaTimelining.swift": 1887,
        "Packages/Features/Upload/Sources/Upload/Views/MediaEditorViewController.swift": 2100,
        "Packages/Features/Upload/Sources/Upload/Views/MediaPickerViewController.swift": 1211,
        "Packages/Features/Upload/Sources/Upload/Views/MediaTimelineTrackView.swift": 1941,
        "Packages/Features/Upload/Sources/Upload/Views/NewPostCells.swift": 1085,
        "Packages/Features/Upload/Sources/Upload/Views/NewPostViewController.swift": 1725,
    ]

    @Test func noFilePastTheLimitGrows() throws {
        let lengths = try Self.lengths()
        var problems: [String] = []
        for (path, length) in lengths.sorted(by: { $0.key < $1.key }) {
            if let allowed = Self.baseline[path] {
                if length > allowed {
                    problems.append("\(path): \(length) lines, baseline \(allowed) — it may not grow: move what you added into a new type")
                } else if length <= Self.limit {
                    problems.append("\(path): \(length) lines — at or under \(Self.limit) now: remove it from the baseline")
                } else if length < allowed {
                    problems.append("\(path): \(length) lines, baseline \(allowed) — lower the baseline to \(length)")
                }
            } else if length > Self.limit {
                problems.append("\(path): \(length) lines — a file may not pass \(Self.limit): split it by responsibility")
            }
        }
        for path in Self.baseline.keys.sorted() where lengths[path] == nil {
            problems.append("\(path): gone — remove it from the baseline")
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Every Swift source under `App/` and `Packages/` (tests and generated
    /// code left out), by repository-relative path, with its line count.
    private static func lengths() throws -> [String: Int] {
        let root = RepoRoot.url
        var result: [String: Int] = [:]
        for folder in ["App", "Packages"] {
            let base = root.appendingPathComponent(folder)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let path = url.resolvingSymlinksInPath().path
                guard !path.contains("/Tests/"), !path.contains("/.build/"), !path.contains("/Generated/") else {
                    continue
                }
                guard path.hasPrefix(root.path + "/") else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                result[String(path.dropFirst(root.path.count + 1))] = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            }
        }
        return result
    }
}
