import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import MediaCoreFixtures
@testable import PostSurfaces
import Testing
import UIKit
@testable import Feed
@testable import ThreadKit

/// **Full screen v2's column (#2408), behind `-snap-layout-v2`.**
///
/// ```
///   ╭♥╮   like pill — tap likes, hold stakes
///   ╰─╯
///   (☆)   save, gold once saved
///   (↗)   share
///   (◉)   the sound, on the caption's line (#2326)
/// ```
///
/// The column stacks upward from the sound, one `SnapActionColumn.gap`
/// between bubbles, and stands apart from the left block: the caption's
/// length never moves it. The emote wheel is not installed. With the comments
/// sheet up, everything folds into the sound. Flag off (the other suites),
/// nothing of this shows.
@MainActor
struct SnapLayoutV2ColumnTests {
    static let screen = CGRect(x: 0, y: 0, width: 390, height: 844)
    static let insets = UIEdgeInsets(top: 103, left: 0, bottom: 83, right: 0)
    static let shortCaption = "Hi"
    static let longCaption = "A caption long enough to run over three lines if the block let it, "
        + "which it never does: two lines and an ellipsis, whatever the post says about itself."

    static func model(caption: String = longCaption, mediaURL: URL? = URL(string: "mock://media/1")) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID("post-1"), authorID: ProfileID("profile-1"), authorName: "Ana",
            metaText: "@ana · 3m", avatarURL: nil, caption: caption,
            mediaURL: mediaURL, mediaKind: .image, thumbnailURL: nil, audioText: nil
        )
    }

    /// A page's chrome under the flag (or not), laid out at full screen.
    static func chrome(v2: Bool = true, caption: String = longCaption,
                       mediaURL: URL? = URL(string: "mock://media/1")) -> SnapChromeView {
        let chrome = SnapChromeView(frame: screen)
        chrome.setFixedInsets(insets)
        chrome.actionColumn.setLayoutV2(v2)
        chrome.configure(with: model(caption: caption, mediaURL: mediaURL))
        chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true))
        chrome.setSlotSharesPost(mediaURL != nil, holdArmsShare: mediaURL != nil)
        chrome.layoutIfNeeded()
        return chrome
    }

    /// The column's items, top to bottom by where they stand.
    static func itemsTopToBottom(_ chrome: SnapChromeView) -> [String] {
        chrome.debugColumnFrames.sorted { $0.value.minY < $1.value.minY }.map(\.key)
    }

    static func same(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    // MARK: - The column

    @Test func theColumnIsLikeSaveShareAndSoundInThatOrder() {
        let chrome = Self.chrome()
        typealias Item = SnapChromeActionColumn.ColumnItem
        #expect(Self.itemsTopToBottom(chrome) == [Item.like, Item.save, Item.share, Item.sound])
        // Each its own bubble: four shapes, none fused.
        #expect(chrome.debugColumnItems.count == 4)
        #expect(chrome.actionColumn.shareBubble.sharesPost, "the share bubble does not wear Share")
        #expect(chrome.actionColumn.shareBubble.accessibilityLabel == "Share")
        #expect(!chrome.debugSoundBubble.sharesPost, "the sound's bubble still wears Share: the sound left the column")
        #expect(chrome.debugSoundBubble.accessibilityLabel == "Sound")
        #expect(chrome.actionColumn.saveBubble.accessibilityLabel == "Save")
        #expect(chrome.actionColumn.saveBubble.configuration?.title == nil, "a count on ☆")
        for item in [chrome.actionColumn.shareBubble, chrome.actionColumn.saveBubble] as [UIView] {
            #expect(chrome.interactionRoots.contains { $0 === item }, "a tap on \(item) would toggle playback")
        }
    }

    /// The column stacks upward from the sound, one gap apart, the bubbles
    /// at the column's size, the like pill at its classic height.
    @Test func theColumnStacksUpwardFromTheSoundOneGapApart() throws {
        let chrome = Self.chrome()
        let classic = Self.chrome(v2: false)
        typealias Item = SnapChromeActionColumn.ColumnItem
        let frames = chrome.debugColumnFrames
        let sound = try #require(frames[Item.sound])
        let share = try #require(frames[Item.share])
        let save = try #require(frames[Item.save])
        let like = try #require(frames[Item.like])
        let gap = SnapActionColumn.gap
        #expect(abs(share.maxY + gap - sound.minY) < 0.5)
        #expect(abs(save.maxY + gap - share.minY) < 0.5)
        #expect(abs(like.maxY + gap - save.minY) < 0.5)
        for bubble in [share, save] {
            #expect(abs(bubble.width - SnapActionColumn.bubbleSize) < 0.5)
            #expect(abs(bubble.height - SnapActionColumn.bubbleSize) < 0.5)
            #expect(abs(bubble.maxX - sound.maxX) < 0.5)
        }
        // The sound keeps its classic place (#2326), the like pill its height.
        let classicFrames = classic.debugColumnFrames
        #expect(Self.same(sound, classicFrames[Item.sound]), "the sound moved")
        #expect(abs(like.height - (classicFrames[Item.like]?.height ?? 0)) < 0.5, "the like pill changed height")
        #expect(abs(like.maxX - sound.maxX) < 0.5)
    }

    /// ⚠️ TWO INDEPENDENT STACKS (#2407): a one-line and a long caption leave
    /// every bubble where it was.
    @Test func theCaptionsLengthNeverMovesTheColumn() {
        let short = Self.chrome(caption: Self.shortCaption).debugColumnFrames
        let long = Self.chrome(caption: Self.longCaption).debugColumnFrames
        #expect(short.count == 4)
        for (id, frame) in short {
            #expect(Self.same(frame, long[id]), "\(id) moved with the caption")
        }
    }

    @Test func theWheelIsNotInstalled() {
        let chrome = Self.chrome()
        #expect(!chrome.debugWheelInstalled, "the emote wheel is still in the column")
        #expect(!chrome.debugBoostButton.isHidden)
        // Back to the classic layout, the wheel comes back.
        chrome.actionColumn.setLayoutV2(false)
        #expect(chrome.debugWheelInstalled)
        #expect(Self.chrome(v2: false).debugWheelInstalled)
    }

    /// The flight's replica is built like the page's chrome: no wheel either.
    @Test func theFlightReplicaCarriesNoWheel() {
        let replica = SnapChromeView(frame: Self.screen)
        replica.markAsFlightReplica()
        replica.actionColumn.setLayoutV2(true)
        replica.configure(with: Self.model())
        // As `SnapZoomDestination.configureFlightChrome` does: the sound's face.
        replica.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true))
        replica.layoutIfNeeded()
        #expect(!replica.debugWheelInstalled)
        #expect(replica.debugColumnItems.count == 4)
    }

    /// Media pages only (#2407): a text page keeps its classic column and
    /// its wheel, the flag on.
    @Test func aTextPageKeepsItsClassicColumn() {
        let chrome = Self.chrome(mediaURL: nil)
        #expect(!chrome.actionColumn.isLayoutV2)
        #expect(chrome.debugWheelInstalled)
        #expect(chrome.actionColumn.shareBubble.isHidden)
        #expect(chrome.actionColumn.saveBubble.isHidden)
    }

    @Test func theStarTurnsGoldOnceSaved() {
        let chrome = Self.chrome()
        let star = chrome.actionColumn.saveBubble
        #expect(!star.isSaved)
        chrome.actionColumn.setSaved(true)
        #expect(star.isSaved)
        #expect(star.accessibilityLabel == "Saved")
        #expect(star.configuration?.image?.renderingMode == .alwaysOriginal, "the saved star is not in its own gold")
    }

    // MARK: - The comments

    /// The sheet leaves the resting page: the like, save and share fold into
    /// the sound; back at rest, they come out of it.
    @Test func theColumnFoldsIntoTheSoundWhileTheCommentsAreUp() {
        let chrome = Self.chrome()
        typealias Item = SnapChromeActionColumn.ColumnItem
        chrome.actionColumn.setCommentsSheetShare(0.3)
        #expect(chrome.actionColumn.isFoldedIntoSound)
        #expect(chrome.debugColumnItems == [[Item.sound]])
        chrome.actionColumn.setCommentsSheetShare(1)
        #expect(chrome.debugColumnItems == [[Item.sound]])
        chrome.actionColumn.setCommentsSheetShare(0)
        #expect(!chrome.actionColumn.isFoldedIntoSound)
        #expect(Self.itemsTopToBottom(chrome) == [Item.like, Item.save, Item.share, Item.sound])
    }

    /// The classic column never folds: its like stays out, as before.
    @Test func theClassicColumnDoesNotFold() {
        let chrome = Self.chrome(v2: false)
        chrome.actionColumn.setCommentsSheetShare(1)
        #expect(!chrome.actionColumn.isFoldedIntoSound)
        #expect(chrome.debugColumnItems.count == 2)
    }

    // MARK: - The screen

    static func feed(v2: Bool) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: V2SilentProvider(),
                                     unavailablePosts: UnavailablePosts(viewerEvents: ViewerEvents())),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            bookmarks: PostBookmarkStore(
                defaults: UserDefaults(suiteName: "snap.v2.tests.\(UUID().uuidString)")!,
                scope: StorageScope(owner: .member(account: "acc-1", profile: "prof-1"))
            ),
            savedSounds: SavedSoundStore(scope: StorageScope()),
            viewer: { nil }
        )
        controller.layoutV2 = v2
        controller.loadViewIfNeeded()
        controller.view.frame = screen
        controller.seedProjection([model()])
        controller.view.layoutIfNeeded()
        return controller
    }

    /// Save and the sound leave the toolbar (#2408): the media page's footer
    /// is the author, then repost alone.
    @Test func theToolbarKeepsOnlyTheRepostBesideTheAuthor() {
        let feed = Self.feed(v2: true)
        let items = feed.toolbarItems ?? []
        let ids = items.compactMap(\.identifier)
        #expect(!ids.contains(SnapFooterToolbar.ID.save), "☆ is still on the toolbar")
        #expect(!ids.contains(SnapFooterToolbar.ID.sound), "the sound is still on the toolbar")
        #expect(ids.last == SnapFooterToolbar.ID.repost, "the repost does not end the bar: \(ids)")
        #expect(items.first === feed.toolbarComposer.authorItem)
        // Flag off, the bar is as it was.
        let classic = Self.feed(v2: false).toolbarItems?.compactMap(\.identifier) ?? []
        #expect(classic.contains(SnapFooterToolbar.ID.save) && classic.last == SnapFooterToolbar.ID.sound)
    }

    /// The column's star saves the post its page shows, and draws it.
    @Test func theColumnsStarSavesThePost() {
        let feed = Self.feed(v2: true)
        let chrome = SnapChromeView(frame: Self.screen)
        let model = Self.model()
        feed.applyColumnLayout(to: chrome, for: model)
        chrome.configure(with: model)
        chrome.actionColumn.saveBubble.sendActions(for: .primaryActionTriggered)
        #expect(feed.bookmarks.isSaved(model.id.rawValue), "the tap did not save the post")
        feed.applyColumnLayout(to: chrome, for: model)
        #expect(chrome.actionColumn.saveBubble.isSaved, "the star does not draw the saved post")
    }
}

/// A repository that vends nothing: these tests are about the chrome.
private final class V2SilentProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(id: id, authorID: ProfileID("p"), caption: "", attachments: [],
                       publishedAt: Date(timeIntervalSince1970: 0)),
            author: AuthorSummary(id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil),
            likeCount: 0
        )
    }
}
