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

    /// The sheet as it rests: the navigation controller hosted in a phone-
    /// sized window, laid out.
    private func hosted(
        _ controller: SoundSheetViewController
    ) -> (window: UIWindow, navigation: UINavigationController) {
        let navigation = controller.wrappedInSheet()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        navigation.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        return (window, navigation)
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

    /// Laid out in a phone-width bar, "Use this sound" takes what save and
    /// share leave: far wider than its title, and ending before them.
    @Test func useThisSoundFillsTheBar() throws {
        let controller = sheet(tiles: 7)
        controller.onUseSound = { _ in }
        let (window, navigation) = hosted(controller)
        defer { window.isHidden = true }
        navigation.toolbar.layoutIfNeeded()
        let button = try #require(controller.useButton)
        let frame = button.convert(button.bounds, to: window)
        #expect(frame.width > window.bounds.width / 2, "Use this sound kept its title's width: \(frame)")
        #expect(frame.maxX < window.bounds.width - 2 * 44, "Use this sound runs over save and share: \(frame)")
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
    /// instead changed the window's own safe area with it.) ⚠️ The test
    /// window has a TOP safe area a sheet does not: positions are read from
    /// under it.
    @Test func atTheCollapsedHeightTheFirstRowAndViewAllSitAboveTheToolbar() throws {
        let controller = sheet(tiles: 7, original: 0)
        let (window, _) = hosted(controller)
        defer { window.isHidden = true }

        let collapsed = try #require(controller.collapsedHeight)
        let top = controller.view.safeAreaInsets.top
        let collapsedSheet = collapsed + window.safeAreaInsets.bottom
        let toolbarTop = collapsedSheet - controller.view.safeAreaInsets.bottom
        #expect(controller.view.safeAreaInsets.bottom > window.safeAreaInsets.bottom, "no toolbar band")

        let collection = try grid(of: controller)
        collection.layoutIfNeeded()
        let visible = collection.visibleCells.map { cell -> (UICollectionViewCell, CGRect) in
            (cell, cell.convert(cell.bounds, to: controller.view).offsetBy(dx: 0, dy: -top))
        }
        let more = try #require(visible.first { $0.0 is SoundSheetMoreCell })
        #expect((more.0 as? SoundSheetMoreCell)?.title == "View all 7 posts")
        #expect(more.1.maxY <= toolbarTop + 0.5, """
            View all is under the toolbar: more \(more.1) bar top \(toolbarTop) collapsed \(collapsed) \
            safe \(controller.view.safeAreaInsets) window \(window.safeAreaInsets)
            """)
        #expect(abs(toolbarTop - more.1.maxY - SoundSheetViewController.foldGap) <= 1,
                "the fold computed is not the fold laid out: more \(more.1) bar top \(toolbarTop)")

        let tiles = visible.filter { $0.0 is SoundSheetTileCell }
        let firstRow = tiles.filter { $0.1.maxY <= more.1.minY + 0.5 }
        #expect(firstRow.count == SoundSheetViewController.columns, "the first row is not whole above View all")
        #expect(firstRow.allSatisfy { $0.1.minY >= 0 })
        let original = firstRow.min { $0.1.minX < $1.1.minX }?.0 as? SoundSheetTileCell
        #expect(original?.showsOriginalBadge == true, "the original is not the first tile")
        // Anything of row two is below View all: behind the bar, not above it.
        #expect(tiles.filter { $0.1.minY > more.1.minY }.allSatisfy { $0.1.minY >= more.1.maxY })
    }

    /// ONE gutter: the sheet's side margin is the gap between tiles and
    /// between rows, and the header starts on the tiles' left edge, at the
    /// height the detent counted.
    @Test func oneGutterAlignsTheSheet() throws {
        let controller = sheet(tiles: 7)
        let (window, _) = hosted(controller)
        defer { window.isHidden = true }
        let collection = try grid(of: controller)
        // At large every row is in the grid.
        let presentation = try #require(controller.navigationController?.sheetPresentationController)
        presentation.selectedDetentIdentifier = .large
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        collection.layoutIfNeeded()

        let gutter = SoundSheetViewController.gutter
        let width = collection.bounds.width
        let frames = collection.visibleCells.compactMap { $0 as? SoundSheetTileCell }.map(\.frame)
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        try #require(frames.count >= 6)
        let rowOne = Array(frames.prefix(3))
        #expect(abs(rowOne[0].minX - gutter) < 0.5, "left margin \(rowOne[0].minX)")
        #expect(abs(width - rowOne[2].maxX - gutter) < 0.5, "right margin \(width - rowOne[2].maxX)")
        #expect(abs(rowOne[1].minX - rowOne[0].maxX - gutter) < 0.5, "gap between tiles")
        #expect(abs(frames[3].minY - rowOne[0].maxY - gutter) < 0.5, "gap between rows")

        let header = try #require(collection.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionHeader
        ).first)
        #expect(abs(header.frame.minX - gutter) < 0.5, "the header is off the tiles' edge")
        #expect(header.frame.height == controller.collapsedMetrics?.headerHeight)
    }

    /// ⚠️ The regression: #296 re-read the fold in `viewDidLayoutSubviews` and
    /// re-asked the detents from there — a stack overflow when dragged from
    /// the grabber, and a collapsed height that drifted between visits. Laying
    /// the sheet out at any height, large and back, must neither move the
    /// collapsed height nor re-ask the detents.
    @Test func layoutNeverInvalidatesTheDetentsAndCollapsedComesBackIdentical() throws {
        let controller = sheet(tiles: 7)
        let (window, navigation) = hosted(controller)
        defer { window.isHidden = true }
        let presentation = try #require(navigation.sheetPresentationController)
        let before = try #require(controller.collapsedHeight)
        let invalidations = controller.detentInvalidations

        // A drag, frame by frame: the sheet at every height from collapsed
        // to large, then large.
        for height in stride(from: before, through: 874, by: 37) {
            navigation.view.frame = CGRect(x: 0, y: 874 - height, width: 402, height: height)
            navigation.view.layoutIfNeeded()
            controller.view.layoutIfNeeded()
        }
        presentation.selectedDetentIdentifier = .large
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        navigation.view.layoutIfNeeded()
        // And back down, "View all" coming back while it travels.
        presentation.selectedDetentIdentifier = SoundSheetViewController.collapsedDetent
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        for height in stride(from: 874, through: before, by: -41) {
            navigation.view.frame = CGRect(x: 0, y: 874 - height, width: 402, height: height)
            navigation.view.layoutIfNeeded()
            controller.view.layoutIfNeeded()
        }

        #expect(controller.collapsedHeight == before, "the collapsed height drifted over a large round trip")
        #expect(controller.detentInvalidations == invalidations, "a layout pass re-asked the detents")
    }

    /// The detents are re-asked for a genuine content change — the count
    /// crossing the first row adds or removes "View all" — and not for one
    /// that moves nothing.
    @Test func onlyACountCrossingTheFirstRowReasksTheDetent() throws {
        let controller = sheet(tiles: 7)
        let (window, _) = hosted(controller)
        defer { window.isHidden = true }
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
