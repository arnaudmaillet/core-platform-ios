import CoreModels
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The sound sheet's rules: how it opens, that no detent — large included —
/// pauses the clip behind, the grid's order ("Original" first), and that the
/// collapsed detent ends right under "View all", above the toolbar.
@MainActor
struct SoundSheetTests {
    private func sheet(tiles: Int = 1, original: Int? = nil) -> SoundSheetViewController {
        SoundSheetViewController(
            sound: PostSound(
                id: "clip-01", title: "Veridis Quo", artist: "Daft Punk",
                previewURL: nil, artworkURL: nil, duration: 30
            ),
            authorHandle: "ava",
            fallbackArtworkURL: nil,
            tiles: (0..<tiles).map {
                SoundSheetViewController.Tile(
                    postID: PostID("p\($0)"), thumbnailURL: nil, caption: nil,
                    isCurrent: $0 == 0, isOriginal: $0 == original
                )
            },
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
    }

    @Test func itOpensCollapsedWithTwoDetents() throws {
        let controller = sheet()
        let navigation = controller.wrappedInSheet()
        let presentation = try #require(navigation.sheetPresentationController)
        #expect(presentation.detents.count == 2)
        #expect(presentation.selectedDetentIdentifier == SoundSheetViewController.collapsedDetent)
        #expect(presentation.prefersGrabberVisible)
        #expect(navigation.isNavigationBarHidden)
        #expect(!navigation.isToolbarHidden, "the actions live in the navigation controller's toolbar")
    }

    /// The actions are native bar items: "Use this sound" (prominent) and
    /// share — share alone when the sound cannot be used.
    @Test func theActionsAreToolbarItems() {
        let usable = sheet()
        usable.onUseSound = { _ in }
        _ = usable.wrappedInSheet()
        usable.loadViewIfNeeded()
        let items = usable.toolbarItems ?? []
        #expect(items.contains { $0.title == "Use this sound" && $0.style == .prominent })
        #expect(items.contains { $0.accessibilityLabel == "Share sound" })

        let shareOnly = sheet()
        _ = shareOnly.wrappedInSheet()
        shareOnly.loadViewIfNeeded()
        #expect(!(shareOnly.toolbarItems ?? []).contains { $0.title == "Use this sound" })
        #expect((shareOnly.toolbarItems ?? []).contains { $0.accessibilityLabel == "Share sound" })
    }

    /// Large leaves the clip behind playing, and so does coming back down to
    /// collapsed — and collapsed is still there to come back to.
    @Test func largeDoesNotCoverTheClip() throws {
        let controller = sheet()
        let presentation = try #require(controller.wrappedInSheet().sheetPresentationController)
        var covered: [Bool] = []
        controller.onCoverChanged = { covered.append($0) }

        presentation.selectedDetentIdentifier = .large
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        #expect(covered.isEmpty, "the clip behind paused at large")
        #expect(presentation.detents.count == 2, "large must keep collapsed to come back to")

        presentation.selectedDetentIdentifier = presentation.detents.first?.identifier
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        #expect(covered.isEmpty, "a detent change paused or resumed the clip behind")
    }

    /// The collapsed detent leaves the clip playing.
    @Test func collapsedDoesNotCover() throws {
        let controller = sheet()
        let presentation = try #require(controller.wrappedInSheet().sheetPresentationController)
        var covered: [Bool] = []
        controller.onCoverChanged = { covered.append($0) }

        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)

        #expect(covered.isEmpty)
    }

    @Test func theMetaLineIsDurationAndCount() {
        #expect(SoundSheetViewController.meta(duration: 30, posts: 1) == "0:30 · 1 post")
        #expect(SoundSheetViewController.meta(duration: 75.4, posts: 3) == "1:15 · 3 posts")
        #expect(SoundSheetViewController.meta(duration: nil, posts: 2) == "2 posts")
        #expect(SoundSheetViewController.moreTitle(posts: 7) == "View all 7 posts")
    }

    // MARK: - Order

    private static let showable = Set(["cur", "orig", "a", "b", "text"].map { PostID($0) })

    private func order(original: String?, using: [String]) -> (ids: [String], original: String?) {
        let text = PostID("text")
        let result = SoundSheetViewController.gridPostIDs(
            current: PostID("cur"),
            original: original.map { PostID($0) },
            using: using.map { PostID($0) },
            canShow: { (id: PostID) in Self.showable.contains(id) },
            isMedia: { (id: PostID) in id != text }
        )
        return (result.ids.map { (id: PostID) in id.rawValue }, result.original?.rawValue)
    }

    @Test func theOriginalMediaPostComesFirstThenTheCurrentOne() {
        let result = order(original: "orig", using: ["a", "orig", "cur", "b"])
        #expect(result.ids == ["orig", "cur", "a", "b"])
        #expect(result.original == "orig")
    }

    @Test func theCurrentPostCanBeItsOwnOriginal() {
        let result = order(original: "cur", using: ["a", "cur"])
        #expect(result.ids == ["cur", "a"])
        #expect(result.original == "cur")
    }

    /// A text post is no "original" of a sound, and a post this feed cannot
    /// show is not offered at all: the current post leads.
    @Test func aTextOrUnshowableOriginalIsNotMarked() {
        let text = order(original: "text", using: ["a", "text"])
        #expect(text.ids == ["cur", "a", "text"])
        #expect(text.original == nil)

        let elsewhere = order(original: "gone", using: ["gone", "a"])
        #expect(elsewhere.ids == ["cur", "a"])
        #expect(elsewhere.original == nil)
    }

    // MARK: - Collapsed detent

    /// The toolbar's band is what the detent adds under the fold — the
    /// bottom safe area ABOVE the window's, which the sheet adds by itself.
    @Test func theDetentExcludesTheWindowsBottomSafeArea() {
        #expect(SoundSheetViewController.collapsedDetentHeight(
            foldBottom: 300, bottomSafeArea: 34 + 49, windowBottomSafeArea: 34
        ) == 349)
        #expect(SoundSheetViewController.collapsedDetentHeight(
            foldBottom: 300.2, bottomSafeArea: 49, windowBottomSafeArea: 0
        ) == 350)
    }

    /// Hosted at the height the collapsed detent gives it, the sheet shows the
    /// sound, the WHOLE first row and "View all" above the toolbar — and the
    /// second row starts under "View all", behind the bar.
    @Test func atTheCollapsedHeightTheFirstRowAndViewAllSitAboveTheToolbar() throws {
        let controller = sheet(tiles: 7, original: 0)
        let navigation = controller.wrappedInSheet()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        navigation.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        let collapsed = try #require(controller.collapsedHeight)
        let windowBottom = window.safeAreaInsets.bottom
        window.frame.size.height = collapsed + windowBottom
        navigation.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        #expect(abs((controller.collapsedHeight ?? 0) - collapsed) < 0.5, "the fold moved with the height")

        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        let toolbarTop = navigation.toolbar.convert(navigation.toolbar.bounds, to: controller.view).minY
        let visible = collection.visibleCells.map { ($0, $0.convert($0.bounds, to: controller.view)) }
        let more = try #require(visible.first { $0.0 is SoundSheetMoreCell })
        #expect((more.0 as? SoundSheetMoreCell)?.title == "View all 7 posts")
        #expect(more.1.maxY <= toolbarTop + 0.5, "View all is under the toolbar")

        let tiles = visible.filter { $0.0 is SoundSheetTileCell }
        let firstRow = tiles.filter { $0.1.maxY <= more.1.minY + 0.5 }
        #expect(firstRow.count == SoundSheetViewController.columns, "the first row is not whole above View all")
        #expect(firstRow.allSatisfy { $0.1.minY >= 0 })
        let original = firstRow.min { $0.1.minX < $1.1.minX }?.0 as? SoundSheetTileCell
        #expect(original?.showsOriginalBadge == true, "the original is not the first tile")
        // Anything of row two is below View all: behind the bar, not above it.
        #expect(tiles.filter { $0.1.minY > more.1.minY }.allSatisfy { $0.1.minY >= more.1.maxY })
    }

    /// "View all" leaves the grid at large and comes back at collapsed; a
    /// sound with a single row has none.
    @Test func viewAllLeavesAtLargeAndComesBack() throws {
        let controller = sheet(tiles: 7)
        let presentation = try #require(controller.wrappedInSheet().sheetPresentationController)
        controller.loadViewIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(collection.numberOfSections == 3)

        presentation.selectedDetentIdentifier = .large
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        #expect(controller.isExpanded)
        #expect(collection.numberOfSections == 2, "View all stayed at large")

        presentation.selectedDetentIdentifier = SoundSheetViewController.collapsedDetent
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        #expect(collection.numberOfSections == 3, "View all did not come back at collapsed")

        let oneRow = sheet(tiles: 3)
        _ = oneRow.wrappedInSheet()
        oneRow.loadViewIfNeeded()
        let single = try #require(oneRow.view.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(single.numberOfSections == 1, "nothing more to view, yet View all is offered")
    }
}
