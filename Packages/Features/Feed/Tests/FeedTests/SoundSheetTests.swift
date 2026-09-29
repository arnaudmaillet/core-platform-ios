import CoreModels
import CoreStorage
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The sound sheet's rules: how it opens, that no detent — large included —
/// pauses the clip behind, the grid's order ("Original" first), the toolbar
/// ([Use this sound —][🔖][↑]), the one gutter, and that the collapsed detent
/// ends right under "View all", above the toolbar — at the SAME height at
/// every visit, with no layout pass ever re-asking the detents.
@MainActor
struct SoundSheetTests {
    private func sheet(
        tiles: Int = 1, original: Int? = nil, saved: SavedSoundStore? = nil
    ) -> SoundSheetViewController {
        SoundSheetViewController(
            sound: PostSound(
                id: "clip-01", title: "Veridis Quo", artist: "Daft Punk",
                previewURL: nil, artworkURL: nil, duration: 30
            ),
            authorHandle: "ava",
            fallbackArtworkURL: nil,
            tiles: Self.tiles(tiles, original: original),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            savedSounds: saved ?? Self.isolatedStore()
        )
    }

    private static func tiles(_ count: Int, original: Int? = nil) -> [SoundSheetViewController.Tile] {
        (0..<count).map { (index: Int) in
            SoundSheetViewController.Tile(
                postID: PostID("p\(index)"), thumbnailURL: nil, caption: nil,
                isCurrent: index == 0, isOriginal: original == .some(index)
            )
        }
    }

    /// A pile of its own, so a test never reads or writes the device's.
    private static func isolatedStore() -> SavedSoundStore {
        let suite = "SoundSheetTests.\(UUID().uuidString)"
        return SavedSoundStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    /// The sheet laid out at `height`, WITHOUT a window: a visible window in
    /// the test host costs render-server round trips on a headless CI
    /// simulator (the suite ran 148s there), and its safe areas are the test
    /// host's, not a sheet's. Everything asserted here is the layout and the
    /// detent's own inputs. The width is the one the sheet loaded with.
    @discardableResult
    private func laidOut(
        _ controller: SoundSheetViewController, height: CGFloat = 874
    ) throws -> UINavigationController {
        let navigation = controller.wrappedInSheet()
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        let width = try #require(controller.collapsedMetrics?.width)
        navigation.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        navigation.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        try grid(of: controller).layoutIfNeeded()
        return navigation
    }

    /// An item's or header's frame from the LAYOUT (content coordinates) —
    /// no cell has to be on screen for it.
    private func frame(
        of item: SoundSheetViewController.Item, in controller: SoundSheetViewController
    ) throws -> CGRect {
        let collection = try grid(of: controller)
        let path = try #require((collection.dataSource as? UICollectionViewDiffableDataSource<
            SoundSheetViewController.Section, SoundSheetViewController.Item
        >)?.indexPath(for: item))
        return try #require(collection.collectionViewLayout.layoutAttributesForItem(at: path)?.frame)
    }

    private func grid(of controller: SoundSheetViewController) throws -> UICollectionView {
        try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
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

    /// The actions are bar items, left to right: "Use this sound", save,
    /// share — save and share each in their own bubble (a zero-width fixed
    /// space between any two). "Use this sound" is a stretchable capsule of
    /// its own (no shared bubble around it). Without a way to use the sound,
    /// save and share keep the trailing edge.
    @Test func theToolbarIsUseSaveShare() throws {
        func label(_ item: UIBarButtonItem) -> String {
            (item.customView as? UIButton)?.configuration?.title ?? item.title ?? item.accessibilityLabel ?? "space"
        }
        let usable = sheet()
        usable.onUseSound = { _ in }
        _ = usable.wrappedInSheet()
        usable.loadViewIfNeeded()
        let items = usable.toolbarItems ?? []
        let labels = items.map(label)
        #expect(labels == ["Use this sound", "space", "Save sound", "space", "Share sound"], "\(labels)")
        let use = try #require(items.first)
        #expect(use.hidesSharedBackground, "a capsule in a bubble")
        let button = try #require(usable.useButton)
        #expect(button.contentHuggingPriority(for: .horizontal).rawValue <= 1, "it hugs its title: it will not fill")

        let shareOnly = sheet()
        _ = shareOnly.wrappedInSheet()
        shareOnly.loadViewIfNeeded()
        let trailing = (shareOnly.toolbarItems ?? []).map(label)
        #expect(trailing == ["space", "Save sound", "space", "Share sound"], "\(trailing)")
    }

    /// The bookmark saves the SOUND and toggles its glyph and label; a second
    /// sheet on the same sound opens already saved.
    @Test func theBookmarkSavesTheSound() throws {
        let store = Self.isolatedStore()
        let controller = sheet(saved: store)
        _ = controller.wrappedInSheet()
        controller.loadViewIfNeeded()
        let item = try #require(controller.bookmarkItem)
        #expect(controller.bookmarkSymbol == "bookmark")
        #expect(item.accessibilityLabel == "Save sound")
        let unsavedGlyph = item.image

        controller.debugToggleSaved()
        #expect(store.isSaved("clip-01"))
        #expect(controller.bookmarkSymbol == "bookmark.fill")
        #expect(item.accessibilityLabel == "Sound saved")
        #expect(item.image !== unsavedGlyph, "the glyph did not change")

        let again = sheet(saved: store)
        _ = again.wrappedInSheet()
        again.loadViewIfNeeded()
        #expect(again.bookmarkSymbol == "bookmark.fill")

        controller.debugToggleSaved()
        #expect(!store.isSaved("clip-01"))
        #expect(controller.bookmarkSymbol == "bookmark")
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

    /// ⚠️ The regression: #304's tiles were concentric with the sheet, and at
    /// large a tile scrolling past the screen's bottom corners took their
    /// radius and looked cropped. Every tile keeps one fixed corner.
    @Test func tilesKeepOneFixedCorner() {
        let cell = SoundSheetTileCell(frame: CGRect(x: 0, y: 0, width: 123, height: 164))
        #expect(cell.contentView.layer.cornerRadius == SoundSheetTileCell.cornerRadius)
        #expect(cell.contentView.layer.cornerCurve == .continuous)
        #expect(cell.contentView.clipsToBounds)
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

    /// The arithmetic: the fold is the inset under the grabber, the header,
    /// one row of tiles, then "View all" and its gap — and the toolbar's band
    /// is the bottom safe area ABOVE the window's, which the sheet adds by
    /// itself.
    @Test func theDetentIsTheFoldPlusTheToolbarsBand() {
        typealias Sheet = SoundSheetViewController
        #expect(Sheet.toolbarBand(bottomSafeArea: 34 + 52, windowBottomSafeArea: 34) == 52)
        #expect(Sheet.toolbarBand(bottomSafeArea: 20, windowBottomSafeArea: 34) == 0)
        // 402 wide: (402 - 4 × 8) / 3 = 123.33 → 3:4 → 164.4 → 164.
        #expect(Sheet.tileHeight(width: 402) == 164)
        let row = Sheet.topInset + 112 + 164
        #expect(Sheet.foldBottom(width: 402, headerHeight: 112, hasMore: false) == row + Sheet.singleRowFoldGap)
        #expect(Sheet.foldBottom(width: 402, headerHeight: 112, hasMore: true)
            == row + Sheet.gutter + SoundSheetMoreCell.height + Sheet.foldGap)
        let metrics = Sheet.CollapsedMetrics(width: 402, headerHeight: 112, hasMore: true, toolbarBand: 52.2)
        #expect(Sheet.collapsedDetentHeight(metrics)
            == (Sheet.foldBottom(width: 402, headerHeight: 112, hasMore: true) + 52.2).rounded(.up))
    }

    /// Only a bar-sized band is kept: none is a safe area without its bar,
    /// and one near the view's height is a safe area caught mid-setup (CI,
    /// iOS 26.2: the detent came out ~780pt above its fold).
    @Test func anImplausibleToolbarBandIsNotKept() {
        typealias Sheet = SoundSheetViewController
        #expect(Sheet.isPlausibleToolbarBand(52, viewHeight: 446))
        #expect(Sheet.isPlausibleToolbarBand(48, viewHeight: 812))
        #expect(!Sheet.isPlausibleToolbarBand(0, viewHeight: 446))
        #expect(!Sheet.isPlausibleToolbarBand(784, viewHeight: 874))
        #expect(!Sheet.isPlausibleToolbarBand(150, viewHeight: 874))
    }

    /// The detent's value is the fold the GRID lays out plus the band it was
    /// computed with: "View all" ends one `foldGap` above the band, the whole
    /// first row is above "View all", and row two starts under it (behind
    /// the bar).
    ///
    /// ⚠️ Read off the layout and the detent's own inputs, never off the
    /// toolbar's view or a window's safe areas: the bar's frame spans the
    /// whole view on iOS 27, and the test host's safe areas are not a sheet's
    /// (on CI, iOS 26.2, a window-hosted version of this test failed by
    /// ~780pt).
    @Test func theComputedFoldIsTheLaidOutFold() throws {
        let controller = sheet(tiles: 7, original: 0)
        try laidOut(controller)
        let metrics = try #require(controller.collapsedMetrics)
        let collapsed = try #require(controller.collapsedHeight)
        #expect(collapsed == SoundSheetViewController.collapsedDetentHeight(metrics))

        // Content coordinates start under the inset below the grabber.
        let top = SoundSheetViewController.topInset
        let more = try frame(of: .more, in: controller)
        let foldFromLayout = top + more.maxY + SoundSheetViewController.foldGap
        let fold = SoundSheetViewController.foldBottom(
            width: metrics.width, headerHeight: metrics.headerHeight, hasMore: metrics.hasMore
        )
        #expect(abs(foldFromLayout - fold) <= 0.5, "laid out \(foldFromLayout), computed \(fold)")
        #expect(abs(collapsed - (fold + metrics.toolbarBand)) <= 1)

        let firstRow = try (0..<3).map { try frame(of: .tile(PostID("p\($0)")), in: controller) }
        #expect(firstRow.allSatisfy { $0.maxY <= more.minY + 0.5 }, "the first row is not whole above View all")
        let rowTwo = try frame(of: .tile(PostID("p3")), in: controller)
        #expect(rowTwo.minY >= more.maxY, "row two starts above View all")
        #expect(controller.tiles.first?.isOriginal == true, "the original is not the first tile")
    }

    /// ONE gutter: the sheet's side margin is the gap between tiles and
    /// between rows, and the header starts on the tiles' left edge, at the
    /// height the detent counted.
    @Test func oneGutterAlignsTheSheet() throws {
        let controller = sheet(tiles: 7)
        try laidOut(controller)
        let gutter = SoundSheetViewController.gutter
        let width = try #require(controller.collapsedMetrics?.width)
        let row = try (0..<3).map { try frame(of: .tile(PostID("p\($0)")), in: controller) }
        #expect(abs(row[0].minX - gutter) < 0.5, "left margin \(row[0].minX)")
        #expect(abs(width - row[2].maxX - gutter) < 0.5, "right margin \(width - row[2].maxX)")
        #expect(abs(row[1].minX - row[0].maxX - gutter) < 0.5, "gap between tiles")
        #expect(abs(row[0].height - SoundSheetViewController.tileHeight(width: width)) < 0.5)
        // Rows two and three, in the rest of the grid.
        let rowTwo = try frame(of: .tile(PostID("p3")), in: controller)
        let rowThree = try frame(of: .tile(PostID("p6")), in: controller)
        #expect(abs(rowThree.minY - rowTwo.maxY - gutter) < 0.5, "gap between rows")

        let collection = try grid(of: controller)
        let header = try #require(collection.collectionViewLayout.layoutAttributesForSupplementaryView(
            ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 0)
        )?.frame)
        #expect(abs(header.minX - gutter) < 0.5, "the header is off the tiles' edge")
        #expect(header.height == controller.collapsedMetrics?.headerHeight)
    }

    /// ⚠️ The regression: #296 re-read the fold in `viewDidLayoutSubviews` and
    /// re-asked the detents from there — a stack overflow when dragged from
    /// the grabber, and a collapsed height that drifted between visits. Laying
    /// the sheet out at any height, large and back, must neither move the
    /// collapsed height nor re-ask the detents.
    @Test func layoutNeverInvalidatesTheDetentsAndCollapsedComesBackIdentical() throws {
        let controller = sheet(tiles: 7)
        let navigation = try laidOut(controller)
        let presentation = try #require(navigation.sheetPresentationController)
        let width = navigation.view.bounds.width
        let before = try #require(controller.collapsedHeight)
        let invalidations = controller.detentInvalidations

        func layOut(at height: CGFloat) {
            navigation.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            navigation.view.layoutIfNeeded()
            controller.view.layoutIfNeeded()
        }
        // A drag, frame by frame, from collapsed to large…
        for height in stride(from: before, through: 874, by: 61) { layOut(at: height) }
        presentation.selectedDetentIdentifier = .large
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        layOut(at: 874)
        // …and back down, "View all" coming back while it travels.
        presentation.selectedDetentIdentifier = SoundSheetViewController.collapsedDetent
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        for height in stride(from: 874, through: before, by: -67) { layOut(at: height) }

        #expect(controller.collapsedHeight == before, "the collapsed height drifted over a large round trip")
        #expect(controller.detentInvalidations == invalidations, "a layout pass re-asked the detents")
    }

    /// The detents are re-asked for a genuine content change — the count
    /// crossing the first row adds or removes "View all" — and not for one
    /// that moves nothing.
    @Test func onlyACountCrossingTheFirstRowReasksTheDetent() throws {
        let controller = sheet(tiles: 7)
        _ = controller.wrappedInSheet()
        controller.loadViewIfNeeded()
        let tall = try #require(controller.collapsedHeight)
        let invalidations = controller.detentInvalidations

        controller.update(tiles: Self.tiles(6))
        #expect(controller.collapsedHeight == tall)
        #expect(controller.detentInvalidations == invalidations, "a change that moves nothing re-asked the detents")

        controller.update(tiles: Self.tiles(2))
        let short = try #require(controller.collapsedHeight)
        #expect(short < tall, "View all left, the fold did not rise")
        #expect(controller.detentInvalidations == invalidations + 1)
    }

    /// "View all" leaves the grid at large and comes back at collapsed; a
    /// sound with a single row has none.
    @Test func viewAllLeavesAtLargeAndComesBack() throws {
        let controller = sheet(tiles: 7)
        let presentation = try #require(controller.wrappedInSheet().sheetPresentationController)
        controller.loadViewIfNeeded()
        let collection = try grid(of: controller)
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
        let single = try grid(of: oneRow)
        #expect(single.numberOfSections == 1, "nothing more to view, yet View all is offered")
    }
}
