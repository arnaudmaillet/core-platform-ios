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
            tiles: (0..<tiles).map { (index: Int) in
                SoundSheetViewController.Tile(
                    postID: PostID("p\(index)"), thumbnailURL: nil, caption: nil,
                    isCurrent: index == 0, isOriginal: original == .some(index)
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

    /// `unknown` posts are not loaded yet (`isMedia` nil); "text" is a text post.
    private func order(
        original: String?, using: [String], unknown: Set<String> = []
    ) -> (ids: [String], original: String?) {
        let result = SoundSheetViewController.gridPostIDs(
            current: PostID("cur"),
            original: original.map { PostID($0) },
            using: using.map { PostID($0) },
            isMedia: { (id: PostID) -> Bool? in
                unknown.contains(id.rawValue) ? nil : id.rawValue != "text"
            }
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

    /// A text post is no "original" of a sound: it keeps its place among the
    /// others, unmarked, and the current post leads.
    @Test func aTextOriginalIsNotMarked() {
        let text = order(original: "text", using: ["a", "text"])
        #expect(text.ids == ["cur", "a", "text"])
        #expect(text.original == nil)
    }

    /// Every post using the sound is listed, the feed's or not; an original
    /// not loaded yet holds the first place, unmarked until it is known.
    @Test func anUnloadedOriginalLeadsUnmarked() {
        let result = order(original: "orig", using: ["orig", "a", "b"], unknown: ["orig", "b"])
        #expect(result.ids == ["orig", "cur", "a", "b"])
        #expect(result.original == nil)
    }

    // MARK: - Placeholders

    /// Posts outside the feed arrive as placeholders and are filled in —
    /// reconfigured in place, a failed one removed, the counts following —
    /// and a placeholder's tap leads nowhere.
    @Test func placeholdersAreFilledInAndFailuresLeave() throws {
        let controller = SoundSheetViewController(
            sound: PostSound(id: "clip-01", title: nil, artist: nil, previewURL: nil, artworkURL: nil, duration: 30),
            authorHandle: "ava",
            fallbackArtworkURL: nil,
            tiles: (0..<6).map { (index: Int) in
                SoundSheetViewController.Tile(
                    postID: PostID("p\(index)"), thumbnailURL: nil, caption: nil,
                    isCurrent: index == 0, isLoaded: index < 2
                )
            },
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        var selected: [PostID] = []
        controller.onSelectPost = { selected.append($0) }
        _ = controller.wrappedInSheet()
        controller.loadViewIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(collection.numberOfItems(inSection: 2) == 3)

        // A placeholder (p3, first of row two) does nothing when tapped.
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 0, section: 2))
        #expect(selected.isEmpty)

        // p5 could not be loaded: it leaves; the others are filled in.
        controller.update(tiles: (0..<5).map { (index: Int) in
            SoundSheetViewController.Tile(
                postID: PostID("p\(index)"), thumbnailURL: nil, caption: "post \(index)", isCurrent: index == 0
            )
        })
        #expect(controller.tiles.count == 5)
        #expect(controller.tiles.allSatisfy { $0.isLoaded })
        #expect(collection.numberOfItems(inSection: 2) == 2)
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

    /// At the collapsed detent the sheet shows the sound, the WHOLE first row
    /// and "View all" above the toolbar — and the second row starts under
    /// "View all", behind the bar.
    ///
    /// Read off the laid-out CELLS against the view's safe area: the bar's
    /// top edge is the bottom safe area, which keeps its distance to the
    /// sheet's bottom at any height, and a collapsed sheet is the detent plus
    /// the window's bottom safe area tall. ⚠️ Not `toolbar.frame`: on iOS 27
    /// the bar's frame spans the whole view (measured 402×874), glass items
    /// floating in it. (Resizing the test window to the collapsed height
    /// instead changed the window's own safe area with it.)
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
        let collapsedSheet = collapsed + window.safeAreaInsets.bottom
        let toolbarTop = collapsedSheet - controller.view.safeAreaInsets.bottom
        #expect(controller.view.safeAreaInsets.bottom > window.safeAreaInsets.bottom, "no toolbar band")

        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        let visible = collection.visibleCells.map { ($0, $0.convert($0.bounds, to: controller.view)) }
        let more = try #require(visible.first { $0.0 is SoundSheetMoreCell })
        #expect((more.0 as? SoundSheetMoreCell)?.title == "View all 7 posts")
        #expect(more.1.maxY <= toolbarTop + 0.5, """
            View all is under the toolbar: more \(more.1) bar top \(toolbarTop) collapsed \(collapsed) \
            safe \(controller.view.safeAreaInsets) window \(window.safeAreaInsets)
            """)
        #expect(toolbarTop - more.1.maxY <= SoundSheetViewController.foldGap + 1, "the detent rests taller than its fold")

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
