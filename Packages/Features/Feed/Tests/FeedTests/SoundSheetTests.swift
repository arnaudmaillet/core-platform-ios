import AVFoundation
import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The sound sheet's rules: how it opens (the close item in its bar, the
/// content behind the bar, the sound `headerInset` under its top edge and
/// from its side, the app's section gap under it), that no detent — large
/// included — pauses the clip behind, the sections (the Popular row with
/// "Original" first ONLY when the provider gives one, then the Recent grid of
/// every post the row does not show, newest first — never empty), the
/// toolbar ([Use this sound —][🔖][↑]), the one gutter and the app's section
/// gap before each title, that the collapsed detent ends a little into the
/// Recent grid's first row under a Popular row — after its whole first row
/// without one — over the toolbar, at the SAME height at every visit and for
/// any number of posts of one shape, with no layout pass ever re-asking the
/// detents — that the expanded detent fits a short content, the reveal (the
/// Recent title and grid as one under a Popular row, the rows after the
/// first without one; faint at collapsed), that the posts do not scroll below
/// the fullest detent, and Popular's title + chevron.
@MainActor
struct SoundSheetTests {
    private typealias Sheet = SoundSheetViewController

    private func sheet(
        tiles count: Int = 1, popular: Bool = true, original: Int? = nil, saved: SavedSoundStore? = nil
    ) -> SoundSheetViewController {
        let content = Self.content(count, popular: popular, original: original)
        return SoundSheetViewController(
            sound: PostSound(
                id: "clip-01", title: "Veridis Quo", artist: "Daft Punk",
                previewURL: nil, artworkURL: nil, duration: 30
            ),
            authorHandle: "ava",
            fallbackArtworkURL: nil,
            sections: content.sections,
            tiles: content.tiles,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            savedSounds: saved ?? Self.isolatedStore()
        )
    }

    private static func ids(_ count: Int) -> [PostID] {
        (0..<count).map { PostID("p\($0)") }
    }

    /// Two different orders over `count` posts: popular = p0, p1, …; recent =
    /// the reverse. Without `popular`, the provider gives no Popular section.
    /// The post the fixture's sheet opens over: in no ranking.
    private static let watched = PostID("watched")

    private static func rankings(_ count: Int, popular: Bool = true) -> PostSoundRankings {
        let ids = ids(count)
        return PostSoundRankings(popular: popular ? ids : [], recent: ids.reversed())
    }

    /// The sections over `count` posts, opened over a post outside them (the
    /// post watched is in no section, #1147), and a tile for each post. With `popular`, the row takes p0…p7 and "Recent" the rest —
    /// a sound of 8 posts or fewer has none left for "Recent", and so no row.
    private static func content(
        _ count: Int, popular: Bool = true, original: Int? = nil, loaded: (Int) -> Bool = { _ in true }
    ) -> (sections: [SoundSheetSection], tiles: [SoundSheetViewController.Tile]) {
        let dealt = SoundSheetSections.make(
            rankings: rankings(count, popular: popular), current: Self.watched,
            original: original.map { PostID("p\($0)") }, isMedia: { _ in true }
        )
        let tiles = (0..<count).map { (index: Int) in
            SoundSheetViewController.Tile(
                postID: PostID("p\(index)"), thumbnailURL: nil, caption: nil, isOriginal: dealt.original == PostID("p\(index)"),
                isLoaded: loaded(index)
            )
        }
        return (dealt.sections, tiles)
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
        let width = try #require(controller.detentMetrics?.width)
        navigation.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        navigation.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        try grid(of: controller).layoutIfNeeded()
        return navigation
    }

    /// An item's frame from the LAYOUT (content coordinates) — no cell has
    /// to be on screen for it.
    private func frame(of item: Sheet.Item, in controller: SoundSheetViewController) throws -> CGRect {
        let collection = try grid(of: controller)
        let path = try #require(dataSource(of: controller).indexPath(for: item))
        return try #require(collection.collectionViewLayout.layoutAttributesForItem(at: path)?.frame)
    }

    private func headerFrame(of kind: SoundSheetSection.Kind, in controller: SoundSheetViewController) throws -> CGRect {
        let collection = try grid(of: controller)
        let section = try #require(dataSource(of: controller).snapshot().indexOfSection(.posts(kind)))
        return try #require(collection.collectionViewLayout.layoutAttributesForSupplementaryView(
            ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)
        )?.frame)
    }

    private func dataSource(
        of controller: SoundSheetViewController
    ) throws -> UICollectionViewDiffableDataSource<Sheet.Section, Sheet.Item> {
        try #require(try grid(of: controller).dataSource as? UICollectionViewDiffableDataSource<Sheet.Section, Sheet.Item>)
    }

    private func grid(of controller: SoundSheetViewController) throws -> UICollectionView {
        try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
    }

    private func tileIDs(in kind: SoundSheetSection.Kind, of controller: SoundSheetViewController) throws -> [String] {
        try dataSource(of: controller).snapshot().itemIdentifiers(inSection: .posts(kind)).compactMap {
            if case .tile(let id, _) = $0 { id.rawValue } else { nil }
        }
    }

    @Test func itOpensCollapsedWithTwoDetents() throws {
        let controller = sheet()
        let navigation = controller.wrappedInSheet()
        let presentation = try #require(navigation.sheetPresentationController)
        #expect(presentation.detents.count == 2)
        #expect(presentation.selectedDetentIdentifier == SoundSheetViewController.collapsedDetent)
        #expect(presentation.prefersGrabberVisible)
        #expect(!navigation.isNavigationBarHidden, "the close item lives in the navigation bar")
        #expect(!navigation.isToolbarHidden, "the actions live in the navigation controller's toolbar")
    }

    /// A sound with nothing under it — its one post the one watched — has
    /// ONE detent: a second opened an empty band under the sound (#1162; the
    /// owner, on a device). Posts arriving bring the expanded detent back.
    @Test func aSoundWithNothingBelowHasOneDetent() throws {
        let controller = sheet(tiles: 0, popular: false)
        let navigation = controller.wrappedInSheet()
        controller.loadViewIfNeeded()
        let presentation = try #require(navigation.sheetPresentationController)
        #expect(controller.hasNothingBelow)
        #expect(presentation.detents.map(\.identifier) == [Sheet.collapsedDetent])
        #expect(controller.expandedDetentIdentifier == Sheet.collapsedDetent)

        let content = Self.content(12)
        controller.update(sections: content.sections, tiles: content.tiles)
        #expect(!controller.hasNothingBelow)
        #expect(presentation.detents.count == 2)
    }

    /// The bar's one item is the close button, at its trailing end; the
    /// content starts BEHIND the bar — no inset from it, the sound
    /// `topInset` under the grabber, as far as from the sheet's side — with no
    /// blur over it.
    @Test func theBarHoldsTheCloseItemAndTheContentStartsBehindIt() throws {
        let controller = sheet(tiles: 23)
        try laidOut(controller)
        let close = try #require(controller.closeItem)
        #expect(controller.navigationItem.rightBarButtonItems == [close])
        #expect(controller.navigationItem.leftBarButtonItems?.isEmpty ?? true)
        #expect(controller.navigationItem.title == nil)
        #expect(close.accessibilityIdentifier == "sound.close")
        let collection = try grid(of: controller)
        #expect(collection.contentInsetAdjustmentBehavior == .never, "the bar would push the sound down")
        #expect(collection.contentInset.top == Sheet.topInset)
        #expect(Sheet.topInset == Sheet.headerInset, "the header's top margin is not its side margin")
        let metrics = try #require(controller.detentMetrics)
        #expect(Sheet.soundBottom(metrics) - metrics.headerHeight >= Sheet.headerInset,
                "less room under the sound than above it")
        #expect(Sheet.headerInset == 2 * Sheet.gutter, "the sound has no more room than a tile")
        #expect(collection.topEdgeEffect.isHidden, "a blur over the sound at rest")
        #expect(controller.contentScrollView(for: .top) === collection)
    }

    /// The header's lines stop short of the close button and hold ONE line
    /// each, truncated: a long name neither runs under the ✕ nor makes the
    /// header — and so the collapsed detent — taller.
    @Test func theHeaderClearsTheCloseButtonAndTruncates() throws {
        let width: CGFloat = 402 - 2 * Sheet.headerInset
        func height(_ title: String) -> CGFloat {
            SoundSheetHeaderView.fittingHeight(
                width: width, title: title, subtitle: "Daft Punk", meta: "0:30 · 23 posts", canToggle: true
            )
        }
        let long = String(repeating: "Veridis Quo ", count: 12)
        #expect(height(long) == height("Veridis Quo"), "a long name made the header taller")

        let header = SoundSheetHeaderView(frame: CGRect(x: 0, y: 0, width: width, height: height(long)))
        header.configure(title: long, subtitle: long, meta: "0:30 · 23 posts", canToggle: true)
        header.layoutIfNeeded()
        let labels = allSubviews(of: header).compactMap { $0 as? UILabel }.filter { $0.text == long }
        #expect(labels.count == 2)
        for label in labels {
            let frame = label.convert(label.bounds, to: header)
            #expect(frame.maxX <= width - SoundSheetHeaderView.closeClearance + 0.5,
                    "a line runs under the close button: \(frame.maxX)")
            #expect(label.numberOfLines == 1)
        }
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(allSubviews)
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
        #expect(controller.bookmarkSymbol == AppSymbol.save.rawValue)
        #expect(item.accessibilityLabel == "Save sound")
        let unsavedGlyph = item.image

        controller.debugToggleSaved()
        #expect(store.isSaved("clip-01"))
        #expect(controller.bookmarkSymbol == AppSymbol.saved.rawValue)
        #expect(item.accessibilityLabel == "Sound saved")
        #expect(item.image !== unsavedGlyph, "the glyph did not change")

        let again = sheet(saved: store)
        _ = again.wrappedInSheet()
        again.loadViewIfNeeded()
        #expect(again.bookmarkSymbol == AppSymbol.saved.rawValue)

        controller.debugToggleSaved()
        #expect(!store.isSaved("clip-01"))
        #expect(controller.bookmarkSymbol == AppSymbol.save.rawValue)
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

    // MARK: - The tile's foot

    private static func views<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        root.subviews.flatMap { child -> [T] in
            if let match = child as? T { return [match] }
            return views(type, in: child)
        }
    }

    private static func isShown(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let each = current {
            if each.isHidden || each.alpha == 0 { return false }
            current = each.superview
        }
        return true
    }

    /// A mark's capsule, found by its words.
    private static func mark(_ text: String, in root: UIView) -> CGRect? {
        views(UILabel.self, in: root)
            .first { ($0.attributedText?.string ?? $0.text ?? "").contains(text) && isShown($0) }
            .flatMap { label in label.superview.map { $0.convert($0.bounds, to: root) } }
    }

    private static func likes(in root: UIView) -> CGRect? {
        views(PostMetricLabel.self, in: root).first(where: isShown).map { $0.convert($0.bounds, to: root) }
    }

    /// The tile at rest, drawn the way a twin draws it — synchronously.
    private static func restingTile(
        _ tile: Sheet.Tile, size: CGSize = CGSize(width: 123, height: 164)
    ) throws -> SoundSheetTileCell {
        let card = SoundSheetTileCell.makeStandIn(
            for: tile, cover: tile.thumbnailURL == nil ? nil : UIImage(), size: size,
            traits: UITraitCollection(userInterfaceStyle: .light)
        )
        return try #require(card.subviews.first as? SoundSheetTileCell)
    }

    /// "Original" stands BOTTOM-leading on the foot, and the likes close the
    /// foot BOTTOM-trailing at the flight card's own insets — asked for
    /// 2026-09-30 (evening). No "Watching" any more (#1147).
    @Test func theMarksAndTheLikesStandOnTheFoot() throws {
        let tile = Sheet.Tile(
            postID: PostID("m"), thumbnailURL: URL(string: "https://example.com/m.jpg"), caption: nil, isOriginal: true, likeCount: 3
        )
        let cell = try Self.restingTile(tile)
        let size = cell.bounds.size
        let original = try #require(Self.mark("Original", in: cell.contentView))
        #expect(Self.mark("Watching", in: cell.contentView) == nil, "a tile still says Watching")
        let likes = try #require(Self.likes(in: cell.contentView))
        #expect(cell.debugLikes == "3")
        #expect(cell.debugFootLift == 0, "a short count shares the foot with the marks")
        #expect(abs(original.maxY - (size.height - 6)) < 0.5, "Original at \(original)")
        #expect(abs(original.minX - 6) < 0.5)
        #expect(abs(likes.maxX - (size.width - 8)) < 0.5 && abs(likes.maxY - (size.height - 7)) < 0.5)
        #expect(!likes.intersects(original))
    }

    /// A text post's words read from the TOP, not the middle; its count is
    /// on the foot too.
    @Test func aTextTilesWordsStartAtItsHead() throws {
        let tile = Sheet.Tile(
            postID: PostID("t"), thumbnailURL: nil, caption: "A few words about the sound", likeCount: 12
        )
        let cell = try Self.restingTile(tile)
        let caption = try #require(Self.views(UILabel.self, in: cell.contentView).first { $0.text == tile.caption })
        let frame = caption.convert(caption.bounds, to: cell.contentView)
        #expect(abs(frame.minY - Spacing.sm) < 0.5, "the words at \(frame)")
        let likes = try #require(Self.likes(in: cell.contentView))
        #expect(likes.minY > frame.maxY)
        #expect(cell.debugLikes == "12")
    }

    /// ⚠️ A row's tile is too narrow for a mark AND a long count on one line:
    /// the marks step up onto the count's line rather than run under it —
    /// and the flight card's overlay, which draws only the marks, stands them
    /// exactly there, at every size the card grows through.
    @Test func aNarrowTileLiftsItsMarksAndTheFlightCardAgrees() throws {
        let size = CGSize(width: 104, height: 139)
        let tile = Sheet.Tile(
            postID: PostID("r"), thumbnailURL: URL(string: "https://example.com/r.jpg"), caption: nil, isOriginal: true, likeCount: 12_345
        )
        let cell = try Self.restingTile(tile, size: size)
        let original = try #require(Self.mark("Original", in: cell.contentView))
        let likes = try #require(Self.likes(in: cell.contentView))
        #expect(cell.debugFootLift > 0)
        #expect(!original.intersects(likes), "the mark ran under the count: \(original) / \(likes)")
        #expect(original.maxY <= likes.minY)

        let overlay = try #require(SoundSheetTileCell.makeBadgeOverlay(for: tile, size: size))
        let flown = try #require(Self.mark("Original", in: overlay))
        #expect(abs(flown.minX - original.minX) < 0.5 && abs(flown.maxY - original.maxY) < 0.5)
        // Grown with the card, the marks ride its foot at the SAME lift — a
        // re-decided lift would drop them onto the foot mid-flight.
        overlay.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        overlay.layoutIfNeeded()
        let grown = try #require(Self.mark("Original", in: overlay))
        #expect(abs((874 - grown.maxY) - (size.height - original.maxY)) < 0.5)
    }

    // MARK: - Hero

    private static func galleryPost(_ id: String, kind: GalleryPost.Kind) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(id).jpg"),
            caption: "words \(id)", publishedAtMS: 1
        )
    }

    private static func tile(for post: GalleryPost) -> Sheet.Tile {
        Sheet.Tile(
            postID: post.id, thumbnailURL: post.thumbnailURL, caption: post.caption, isOriginal: true
        )
    }

    /// ⚠️ THE STANDARD TILE (#1280, epic #1269): a loaded MEDIA post is
    /// `PostGridTileCell` — its words by size (`PostTileInfo`), "Original"
    /// across its top edge for the post the sound was first published with —
    /// and a text post keeps the sheet's own tile.
    @Test func aLoadedMediaPostIsTheStandardTileAndWordsKeepTheirOwn() throws {
        let controller = sheet(tiles: 3, original: 0)
        let content = Self.content(3, original: 0)
        let tiles = content.tiles.enumerated().map { index, tile in
            let post = Self.galleryPost(tile.postID.rawValue, kind: index == 1 ? .text : .photo)
            return Sheet.Tile(
                postID: tile.postID, thumbnailURL: post.thumbnailURL, caption: post.caption,
                isOriginal: tile.isOriginal, post: post
            )
        }
        controller.update(sections: content.sections, tiles: tiles)
        try laidOut(controller)
        let collection = try grid(of: controller)
        collection.layoutIfNeeded()
        func cell(_ id: String) throws -> UICollectionViewCell {
            let path = try #require(try dataSource(of: controller).indexPath(for: .tile(PostID(id), .popular)))
            return try #require(collection.cellForItem(at: path))
        }

        let original = try #require(try cell("p0") as? PostGridTileCell, "a media post kept the sheet's own tile")
        #expect(original.infoVariant == PostTileInfo.variant(for: original.bounds.size), "not the words by size")
        let ribbon = try #require(original.debugRibbonFrame, "the original wears no mark")
        #expect(abs(ribbon.midY) < 0.5, "the mark does not straddle the top edge")
        #expect(abs(ribbon.midX - original.bounds.midX) < 0.5)

        let photo = try #require(try cell("p2") as? PostGridTileCell)
        #expect(photo.debugRibbonFrame == nil, "a post that is not the original wears the mark")

        #expect(try cell("p1") is SoundSheetTileCell, "a text post lost its own tile")
    }

    /// ⚠️ THE ONE TILE CONTRACT (#1280, epic #1269): a video tile's card takes
    /// off on the tile's own surface, and a close onto the same post hands it
    /// back, the card waiting for the tile to draw.
    @Test func aVideoTilesFlightCarriesTheWholeTileContract() throws {
        let controller = sheet(tiles: 3)
        try laidOut(controller)
        let post = Self.galleryPost("p1", kind: .video)
        let tile = SoundSheetViewController.Tile(
            postID: post.id, thumbnailURL: post.thumbnailURL, caption: nil,
            videoURL: URL(string: "mock://video/p1")
        )
        let origin = controller.heroOrigin(for: tile, post: post, stream: [post], source: .sheet(.recent))
        #expect(origin.donateLiveMedia != nil, "the card takes off as a still")
        #expect(origin.adoptLandingLiveMedia != nil, "a same-post close restarts the clip")
        #expect(origin.landingMediaIsReady != nil)
        #expect(origin.returnLiveMedia != nil && origin.adoptReturnLiveMedia != nil)
    }

    /// ⚠️ The regression: the flight card rounded as a For You brick (16pt)
    /// and landed on a 12pt tile, so the corners jumped in the frame the card
    /// was taken away — the flash at the end of every close. The card lands
    /// on the tile's own corner AND curve.
    @Test func aTilesFlightLandsOnTheTilesOwnCorner() throws {
        let controller = sheet(tiles: 3)
        try laidOut(controller)
        let post = Self.galleryPost("p1", kind: .photo)
        let origin = controller.heroOrigin(for: Self.tile(for: post), post: post, stream: [post], source: .sheet(.recent))
        #expect(origin.cornerRadius == SoundSheetTileCell.cornerRadius)
        #expect(origin.cornerCurve == .continuous)
        let card = try #require(ExternalHeroZoomSource(origin: origin).makeZoomFlightCard() as? PostGridFlightCard)
        #expect(card.zoomRestingCornerRadius == SoundSheetTileCell.cornerRadius)
        #expect(card.layer.cornerRadius == SoundSheetTileCell.cornerRadius)
        #expect(card.layer.cornerCurve == .continuous, "the card landed a circle's corner on a squircle")
    }

    /// A TEXT tile opens as a window out of the tile and closes back onto it
    /// — For You's Following cards' arrangement — and a MEDIA tile keeps its
    /// flight but carries the same window for a close from a words page.
    @Test func everyTileCarriesItsWindowAndOnlyWordsOpenThroughIt() throws {
        let controller = sheet(tiles: 3)
        try laidOut(controller)
        let text = Self.galleryPost("p1", kind: .text)
        let words = controller.heroOrigin(for: Self.tile(for: text), post: text, stream: [text], source: .sheet(.recent))
        #expect(words.hasHero == false, "a text tile has no picture to fly")
        let window = try #require(words.textReveal, "a text tile opened with the plain push")
        #expect(window.cornerRadius == SoundSheetTileCell.cornerRadius)
        #expect(window.alignsPageToSource == false)
        #expect(window.pageFit == .covering)
        #expect(window.fill.map { Self.alpha(of: $0) } == 1, "the window's ground is see-through")

        let photo = Self.galleryPost("p2", kind: .photo)
        let media = controller.heroOrigin(for: Self.tile(for: photo), post: photo, stream: [photo], source: .sheet(.recent))
        #expect(media.textReveal != nil, "a media tile paged onto words has nowhere to close")
    }

    /// The stand-in is the tile at both ends: on an OPAQUE ground (the tile's
    /// own is translucent over the sheet), a picture filling the window as it
    /// grows, words staying at the tile's size and wrap, centred.
    @Test func aTilesStandInFillsWithAPictureAndKeepsItsWords() throws {
        let size = CGSize(width: 120, height: 160)
        let page = CGRect(x: 0, y: 0, width: 402, height: 874)
        let traits = UITraitCollection(userInterfaceStyle: .dark)

        let words = SoundSheetTileCell.makeStandIn(
            for: Self.tile(for: Self.galleryPost("t", kind: .text)), cover: nil, size: size, traits: traits
        )
        #expect(words.backgroundColor.map { Self.alpha(of: $0) } == 1)
        #expect(words.layer.cornerRadius == SoundSheetTileCell.cornerRadius)
        words.frame = page
        words.layoutIfNeeded()
        let wordsTwin = try #require(words.subviews.first)
        #expect(wordsTwin.bounds.size == size, "the words re-wrapped at the window's size")
        #expect(abs(wordsTwin.center.x - page.midX) < 0.5 && abs(wordsTwin.center.y - page.midY) < 0.5)

        let picture = SoundSheetTileCell.makeStandIn(
            for: Self.tile(for: Self.galleryPost("m", kind: .photo)), cover: UIImage(), size: size, traits: traits
        )
        picture.frame = page
        picture.layoutIfNeeded()
        #expect(try #require(picture.subviews.first).frame == page, "the picture did not fill the window")
    }

    private static func alpha(of color: UIColor) -> CGFloat {
        var alpha: CGFloat = 0
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return alpha
    }

    // MARK: - Order

    /// `unknown` posts are not loaded yet (`isMedia` nil); "text" is a text post.
    private func order(
        original: String?, using: [String], unknown: Set<String> = []
    ) -> (ids: [String], original: String?) {
        let result = SoundSheetViewController.gridPostIDs(
            original: original.map { PostID($0) },
            using: using.map { PostID($0) },
            isMedia: { (id: PostID) -> Bool? in
                unknown.contains(id.rawValue) ? nil : id.rawValue != "text"
            }
        )
        return (result.ids.map { (id: PostID) in id.rawValue }, result.original?.rawValue)
    }

    @Test func theOriginalMediaPostComesFirst() {
        let result = order(original: "orig", using: ["a", "orig", "b"])
        #expect(result.ids == ["orig", "a", "b"])
        #expect(result.original == "orig")
    }

    /// Opened from the original itself, the sheet leaves it out like any
    /// post watched (#1147): unmarked, in no section.
    @Test func theWatchedOriginalIsLeftOut() {
        let dealt = SoundSheetSections.make(
            rankings: Self.rankings(12), current: PostID("p3"), original: PostID("p3"), isMedia: { _ in true }
        )
        #expect(dealt.original == nil)
        #expect(!dealt.sections.contains { $0.all.contains(PostID("p3")) })
        #expect(dealt.sections.first?.ids.first == PostID("p0"), "the ranking leads once the original is out")
    }

    /// A text post is no "original" of a sound: it keeps its place among the
    /// others, unmarked.
    @Test func aTextOriginalIsNotMarked() {
        let text = order(original: "text", using: ["a", "text"])
        #expect(text.ids == ["a", "text"])
        #expect(text.original == nil)
    }

    /// Every post using the sound is listed, the feed's or not; an original
    /// not loaded yet holds the first place, unmarked until it is known.
    @Test func anUnloadedOriginalLeadsUnmarked() {
        let result = order(original: "orig", using: ["orig", "a", "b"], unknown: ["orig", "b"])
        #expect(result.ids == ["orig", "a", "b"])
        #expect(result.original == nil)
    }

    // MARK: - Sections

    /// 23 posts, a row of 8: Popular is the original, then the most engaged;
    /// Recent is every OTHER post, newest first — a post shows once — and
    /// the post watched is in neither (#1147). Popular's chevron is its whole ranking; Recent — which
    /// shows everything it holds — has none.
    @Test func recentLeavesOutWhatTheRowShows() throws {
        let rankings = Self.rankings(23)
        let dealt = SoundSheetSections.make(
            rankings: rankings, current: PostID("p5"), original: PostID("p9"), isMedia: { _ in true }, rowLimit: 8
        )
        #expect(dealt.sections.map(\.kind) == [.popular, .recent])
        #expect(dealt.original == PostID("p9"))
        let popular = dealt.sections[0], recent = dealt.sections[1]
        #expect(popular.ids.map(\.rawValue) == ["p9", "p0", "p1", "p2", "p3", "p4", "p6", "p7"])
        #expect(popular.all.count == 22 && popular.all.prefix(8) == popular.ids.prefix(8))
        #expect(recent.ids == rankings.recent.filter { !popular.ids.contains($0) && $0 != PostID("p5") },
                "Recent is not every other post in date order")
        #expect(recent.ids.count == 14)
        #expect(recent.ids.first == PostID("p22"))
        #expect(recent.all == recent.ids)
        #expect(Set(popular.ids).isDisjoint(with: Set(recent.ids)), "a post the row shows is in Recent too")
        #expect(Set(popular.ids).union(recent.ids) == Set(Self.ids(23)).subtracting([PostID("p5")]),
                "a post is on neither")
        #expect(!popular.all.contains(PostID("p5")), "the post watched is in the pushed ranking")
        #expect(popular.hasMore)
        #expect(!recent.hasMore, "the grid offers a chevron")
        #expect(SoundSheetSection.Kind.allCases == [.popular, .recent])
        #expect(SoundSheetSection.Kind.recent.title == "Recent")
        #expect(SoundSheetSection.Kind.popular.isRow && !SoundSheetSection.Kind.recent.isRow)
    }

    /// No Popular from the provider, no Popular on the sheet: every OTHER
    /// post in "Recent", newest first — the original included and still
    /// marked, the post watched left out (#1147).
    @Test func withoutPopularFromTheProviderRecentHoldsEveryOtherPost() {
        let rankings = Self.rankings(7, popular: false)
        #expect(!rankings.hasPopular)
        let dealt = SoundSheetSections.make(
            rankings: rankings, current: PostID("p5"), original: PostID("p2"), isMedia: { _ in true }
        )
        #expect(dealt.sections.map(\.kind) == [.recent])
        #expect(dealt.sections.first?.ids == rankings.recent.filter { $0 != PostID("p5") })
        #expect(dealt.original == PostID("p2"))
    }

    /// A post the date order leaves out (a ranking that lags) is still
    /// recent: at the grid's end.
    @Test func aPostTheDateOrderMissesJoinsTheGridsEnd() {
        let popular = Self.ids(12)
        let dealt = SoundSheetSections.make(
            rankings: PostSoundRankings(popular: popular, recent: Array(popular.dropLast().reversed())),
            current: PostID("p0"), original: nil, isMedia: { _ in true }, rowLimit: 8
        )
        // The row: p1…p8 (p0 is watched). Recent: p10, p9 by date, then p11.
        #expect(dealt.sections.last?.kind == .recent)
        #expect(dealt.sections.last?.ids.map(\.rawValue) == ["p10", "p9", "p11"])
    }

    /// A section with nothing to show is not there (#1147): every other post
    /// fits the row, so no "Recent"; no other post at all, no section — the
    /// sheet is the sound alone.
    @Test func aSectionWithNothingToShowIsNotThere() {
        let dealt = SoundSheetSections.make(
            rankings: Self.rankings(5), current: PostID("p0"), original: nil, isMedia: { _ in true }, rowLimit: 8
        )
        #expect(dealt.sections.map(\.kind) == [.popular], "an empty Recent is still there")
        #expect(dealt.sections.first?.ids.map(\.rawValue) == ["p1", "p2", "p3", "p4"])

        let alone = SoundSheetSections.make(
            rankings: .empty, current: PostID("cur"), original: nil, isMedia: { _ in true }
        )
        #expect(alone.sections.isEmpty)

        let onlyTheWatched = SoundSheetSections.make(
            rankings: PostSoundRankings(popular: [PostID("cur")], recent: [PostID("cur")]),
            current: PostID("cur"), original: PostID("cur"), isMedia: { _ in true }
        )
        #expect(onlyTheWatched.sections.isEmpty, "the sound's only post is the one watched")
        #expect(onlyTheWatched.original == nil)
    }

    /// A post that could not be loaded leaves every section, and the row
    /// fills up again behind it — from what "Recent" held.
    @Test func anExcludedPostLeavesAndTheRowRefills() throws {
        let dealt = SoundSheetSections.make(
            rankings: Self.rankings(23), current: PostID("p0"), original: nil, isMedia: { _ in true },
            excluding: [PostID("p2"), PostID("p22")], rowLimit: 8
        )
        #expect(!dealt.sections.contains { $0.all.contains(PostID("p2")) || $0.all.contains(PostID("p22")) })
        #expect(dealt.sections[0].ids.map(\.rawValue) == ["p1", "p3", "p4", "p5", "p6", "p7", "p8", "p9"])
        #expect(dealt.sections[1].ids.count == 12)
        #expect(dealt.sections[1].ids.first == PostID("p21"))
    }

    /// The sheet lays the sections out in order, under the sound: the row,
    /// then the grid — each post once — or the grid alone.
    @Test func theSheetShowsTheSectionsInOrder() throws {
        let controller = sheet(tiles: 23, original: 0)
        try laidOut(controller)
        let snapshot = try dataSource(of: controller).snapshot()
        #expect(snapshot.sectionIdentifiers == [.sound, .posts(.popular), .posts(.recent)])
        #expect(try tileIDs(in: .popular, of: controller).first == "p0")
        #expect(try tileIDs(in: .recent, of: controller).count == 15)
        #expect(snapshot.indexOfItem(.tile(PostID("p0"), .popular)) != nil)
        #expect(snapshot.indexOfItem(.tile(PostID("p0"), .recent)) == nil, "the row's post is in Recent too")
        #expect(controller.tiles.first { $0.postID == PostID("p0") }?.isOriginal == true)
        let items = snapshot.itemIdentifiers
        #expect(Set(items).count == items.count)

        let alone = sheet(tiles: 7, popular: false)
        try laidOut(alone)
        let recentOnly = try dataSource(of: alone).snapshot()
        #expect(recentOnly.sectionIdentifiers == [.sound, .posts(.recent)])
        #expect(try tileIDs(in: .recent, of: alone).count == 7)
    }

    // MARK: - Placeholders

    /// Posts outside the feed arrive as placeholders and are filled in —
    /// reconfigured in place, a failed one removed and the sections dealt
    /// again, the count following — and a placeholder's tap leads nowhere.
    @Test func placeholdersAreFilledInAndFailuresLeave() throws {
        let content = Self.content(12, loaded: { $0 < 2 })
        let controller = SoundSheetViewController(
            sound: PostSound(id: "clip-01", title: nil, artist: nil, previewURL: nil, artworkURL: nil, duration: 30),
            authorHandle: "ava",
            fallbackArtworkURL: nil,
            sections: content.sections,
            tiles: content.tiles,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        var selected: [PostID] = []
        controller.onSelectPost = { selected.append($0) }
        _ = controller.wrappedInSheet()
        controller.loadViewIfNeeded()
        let collection = try grid(of: controller)
        #expect(try tileIDs(in: .popular, of: controller).count == 8)

        // A placeholder (p2, third in Popular) does nothing when tapped.
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 2, section: 1))
        #expect(selected.isEmpty)

        // p11 could not be loaded: it leaves; the others are filled in.
        let dealt = SoundSheetSections.make(
            rankings: Self.rankings(12), current: Self.watched, original: nil, isMedia: { _ in true },
            excluding: [PostID("p11")]
        )
        controller.update(sections: dealt.sections, tiles: (0..<11).map { (index: Int) in
            SoundSheetViewController.Tile(
                postID: PostID("p\(index)"), thumbnailURL: nil, caption: "post \(index)"
            )
        })
        #expect(controller.tiles.count == 11)
        #expect(controller.tiles.allSatisfy { $0.isLoaded })
        #expect(try !tileIDs(in: .recent, of: controller).contains("p11"))
        // The row keeps p0…p7; Recent is the rest, newest first.
        #expect(try tileIDs(in: .recent, of: controller) == ["p10", "p9", "p8"])
    }

    // MARK: - The post's record (#1148)

    /// The record mirrors the post: it turns while the post plays — muted
    /// too — with ❚❚, stops with ▶︎, and wears the mute badge while the
    /// sound is off.
    @Test func theRecordFollowsThePost() throws {
        let controller = sheet(tiles: 3)
        try laidOut(controller)
        let header = try #require(controller.debugHeader)
        #expect(!header.debugIsSpinning && !header.debugShowsPause && !header.debugShowsMutedBadge)

        controller.setPostPlayback(.init(playing: true, muted: false, available: true))
        #expect(header.debugIsSpinning && header.debugShowsPause)
        #expect(!header.debugShowsMutedBadge)

        controller.setPostPlayback(.init(playing: true, muted: true, available: true))
        #expect(header.debugIsSpinning, "a muted post that plays stood still")
        #expect(header.debugShowsMutedBadge)

        controller.setPostPlayback(.init(playing: false, muted: true, available: true))
        #expect(!header.debugIsSpinning && !header.debugShowsPause)
        // Paused, the middle offers ▶︎ even muted (2026-10-16).
        #expect(!header.debugShowsMutedBadge, "a paused post kept 🔇 over ▶︎")

        controller.setPostPlayback(.init(playing: false, muted: false, available: true))
        #expect(!header.debugShowsMutedBadge, "unmuting left the badge")
    }

    /// Muted, the button in the middle says 🔇 in place of ❚❚ or ▶︎ (the
    /// owner, 2026-10-16), and gives it back when the sound returns.
    @Test func muteTakesTheMiddleGlyph() throws {
        let controller = sheet(tiles: 3)
        controller.setPostPlayback(.init(playing: true, muted: false, available: true))
        try laidOut(controller)
        let header = try #require(controller.debugHeader)
        #expect(header.debugShownGlyph == "pause.fill")
        controller.setPostPlayback(.init(playing: true, muted: true, available: true))
        #expect(header.debugShownGlyph == "speaker.slash.fill")
        #expect(header.debugCoverDimmed, "the cover is not dimmed behind 🔇")
        // Paused: ▶︎, muted or not — 🔇 shows only while the post plays.
        controller.setPostPlayback(.init(playing: false, muted: true, available: true))
        #expect(header.debugShownGlyph == "play.fill")
        #expect(!header.debugCoverDimmed)
        controller.setPostPlayback(.init(playing: false, muted: false, available: true))
        #expect(header.debugShownGlyph == "play.fill")
    }

    /// A long press on the record mutes or unmutes the post, as the post's
    /// own sound bubble does (the owner, 2026-10-16).
    @Test func aHoldOnTheRecordTogglesTheMute() throws {
        let controller = sheet(tiles: 3)
        try laidOut(controller)
        var mutes = 0, plays = 0
        controller.onToggleMute = { mutes += 1 }
        controller.onTogglePlayback = { plays += 1 }
        controller.debugHoldRecord()
        #expect(mutes == 1)
        #expect(plays == 0, "the hold also played or paused")
    }

    /// ▶︎ ⇄ ❚❚ is one glyph view swapping its symbol (a symbol replace, the
    /// owner 2026-10-15), and the same state twice swaps nothing.
    @Test func theRecordsGlyphFollowsThePlayback() throws {
        let controller = sheet(tiles: 3)
        controller.setPostPlayback(.init(playing: false, muted: false, available: true))
        try laidOut(controller)
        let header = try #require(controller.debugHeader)
        #expect(header.debugShownGlyph == "play.fill")
        controller.setPostPlayback(.init(playing: true, muted: false, available: true))
        #expect(header.debugShownGlyph == "pause.fill")
        #expect(header.debugShowsPause)
        controller.setPostPlayback(.init(playing: false, muted: false, available: true))
        #expect(header.debugShownGlyph == "play.fill")
        #expect(!header.debugShowsPause)
    }

    /// ⚠️ The replace's smoothness (the owner, 2026-10-15: "it lags, as if
    /// at 30 fps"): the glyph stays IN the glass (2026-10-16), and every
    /// symbol it is handed already carries the glyph's size and weight — a
    /// bare one flew in at the default size and jumped at the end.
    @Test func theGlyphReplacesAConfiguredSymbolInTheGlass() throws {
        let controller = sheet(tiles: 3)
        controller.setPostPlayback(.init(playing: false, muted: false, available: true))
        try laidOut(controller)
        let header = try #require(controller.debugHeader)
        #expect(header.debugGlyphIsInTheGlass)
        func configured(_ name: String) -> CGSize? {
            UIImage(systemName: name, withConfiguration: SoundSheetHeaderView.glyphConfiguration)?.size
        }
        // The witness: a bare symbol is drawn at another size.
        #expect(UIImage(systemName: "pause.fill")?.size != configured("pause.fill"))
        #expect(header.debugGlyphImage?.size == configured("play.fill"))
        controller.setPostPlayback(.init(playing: true, muted: false, available: true))
        #expect(header.debugGlyphImage?.size == configured("pause.fill"))
    }

    /// The record's tap toggles the POST, once — the sheet has no player of
    /// its own any more.
    @Test func aTapTogglesThePostOnce() throws {
        let controller = sheet(tiles: 3)
        try laidOut(controller)
        var toggles = 0
        controller.onTogglePlayback = { toggles += 1 }
        let header = try #require(controller.debugHeader)
        header.debugTapRecord()
        #expect(toggles == 1)
        #expect(!Mirror(reflecting: controller).children.contains { $0.value is AVPlayer },
                "the sheet holds a player of its own")
    }

    /// ⚠️ THE WHOLE RECORD TAKES THE TAP (#1162): its upper half, under the
    /// sheet's bar, never did — the tap is the sheet's now, and it begins
    /// anywhere on the disc, not only on the glyph; never beside it.
    @Test func theWholeRecordTakesTheTap() throws {
        let controller = sheet(tiles: 3)
        controller.setPostPlayback(.init(playing: true, muted: false, available: true))
        try laidOut(controller)
        let header = try #require(controller.debugHeader)
        let record = header.debugRecordFrame
        let radius = record.width / 2
        let centre = CGPoint(x: record.midX, y: record.midY)
        #expect(controller.recordTakesTap(at: centre, in: header), "the glyph")
        #expect(controller.recordTakesTap(at: CGPoint(x: centre.x, y: record.minY + 6), in: header), "the upper edge")
        #expect(controller.recordTakesTap(at: CGPoint(x: record.maxX - 6, y: centre.y), in: header), "the side")
        #expect(!controller.recordTakesTap(at: CGPoint(x: record.minX + 2, y: record.minY + 2), in: header),
                "a corner of its square is off the disc")
        #expect(!controller.recordTakesTap(at: CGPoint(x: centre.x + radius + 20, y: centre.y), in: header), "beside it")

        let navigation = try #require(controller.navigationController)
        navigation.pushViewController(UIViewController(), animated: false)
        #expect(!controller.recordTakesTap(at: centre, in: header), "a pushed screen covers the record")
        navigation.popViewController(animated: false)

        controller.setPostPlayback(.init(playing: false, muted: false, available: false))
        #expect(!controller.recordTakesTap(at: centre, in: header), "a post with no sound takes no tap")
    }

    /// A post with no audio: the record without its glyph, refusing taps, and
    /// no badge.
    @Test func aPostWithNoAudioCannotBeToggled() throws {
        let controller = sheet(tiles: 3)
        controller.setPostPlayback(.init(playing: false, muted: true, available: false))
        try laidOut(controller)
        var toggles = 0
        controller.onTogglePlayback = { toggles += 1 }
        let header = try #require(controller.debugHeader)
        #expect(!header.debugCanToggle)
        #expect(!header.debugShowsMutedBadge)
        header.debugTapRecord()
        #expect(toggles == 0)
    }

    // MARK: - Collapsed detent

    /// The arithmetic: the fold is the inset under the grabber, the header
    /// and the section gap under it, the Popular title and its row when there
    /// is one, the section gap, then the Recent title and the top of its
    /// first row — its whole first row and the gutter under it without a
    /// Popular row; the toolbar's band is the bottom safe area ABOVE the
    /// window's, which the sheet adds by itself. The reveal's line is the
    /// Recent title's top under a row, the first row's foot without one. The
    /// fitted height is the whole content.
    @Test func theDetentsAreComputed() {
        #expect(Sheet.toolbarBand(bottomSafeArea: 34 + 52, windowBottomSafeArea: 34) == 52)
        #expect(Sheet.toolbarBand(bottomSafeArea: 20, windowBottomSafeArea: 34) == 0)
        // 402 wide: (402 - 4 × 8) / 3 = 123.33 → 3:4 → 164.4 → 164.
        #expect(Sheet.tileHeight(width: 402) == 164)
        // A row: (402 - 4 × 8) / 3.4 = 108.8 → 108 → 3:4 → 144.
        #expect(Sheet.rowTileWidth(width: 402) == 108)
        #expect(Sheet.rowTileHeight(width: 402) == 144)
        #expect(Sheet.recentPeekHeight(width: 402) == 41)
        let gap: CGFloat = 18
        let metrics = Sheet.DetentMetrics(
            width: 402, headerHeight: 96, sectionHeaderHeight: 44, sectionGap: gap, toolbarBand: 52.2,
            hasPopular: true
        )
        #expect(Sheet.soundBottom(metrics) == 96 + gap)
        #expect(Sheet.popularRowBottom(metrics) == 96 + gap + 44 + Sheet.ribbonRoom + 144)
        #expect(Sheet.recentTitleTop(metrics) == 96 + gap + 44 + Sheet.ribbonRoom + 144 + gap,
                "no section gap between the row and the Recent title")
        #expect(Sheet.foldBottom(metrics) == Sheet.topInset + 96 + gap + 44 + Sheet.ribbonRoom + 144 + gap + 44 + 41)
        #expect(Sheet.collapsedDetentHeight(metrics) == (Sheet.foldBottom(metrics) + 52.2).rounded(.up))
        #expect(Sheet.revealLine(metrics) == Sheet.recentTitleTop(metrics), "the Recent title does not fade")

        // The grid: rows of 164, a gutter between.
        #expect(Sheet.gridHeight(width: 402, count: 1) == 164)
        #expect(Sheet.gridHeight(width: 402, count: 3) == 164)
        #expect(Sheet.gridHeight(width: 402, count: 4) == 2 * 164 + Sheet.gutter)
        #expect(Sheet.contentHeight(metrics, recentCount: 5)
                == 96 + gap + 44 + Sheet.ribbonRoom + 144 + gap + 44 + 2 * 164 + Sheet.gutter + Sheet.contentBottom)
        #expect(Sheet.fittedDetentHeight(metrics, recentCount: 5)
                == (Sheet.topInset + Sheet.contentHeight(metrics, recentCount: 5) + 52.2).rounded(.up))
        // One post: still taller than collapsed — the sheet always grows.
        #expect(Sheet.fittedDetentHeight(metrics, recentCount: 1) > Sheet.collapsedDetentHeight(metrics))

        // Without Popular: Recent on the sound's gap, its WHOLE first row and
        // the gutter under it at collapsed — the fold is where the second row
        // starts — and the rows after the first fading.
        var alone = metrics
        alone.hasPopular = false
        #expect(Sheet.recentTitleTop(alone) == 96 + gap)
        #expect(Sheet.revealLine(alone) == 96 + gap + 44 + 164, "the line is not the first row's foot")
        #expect(Sheet.foldBottom(alone) == Sheet.topInset + 96 + gap + 44 + 164 + Sheet.gutter)
        #expect(Sheet.contentHeight(alone, recentCount: 1) == 96 + gap + 44 + 164 + Sheet.contentBottom)
        // One row: the collapsed sheet shows it all; the sheet still grows.
        #expect(Sheet.fittedDetentHeight(alone, recentCount: 1) == Sheet.collapsedDetentHeight(alone) + 1)
        #expect(Sheet.fittedDetentHeight(alone, recentCount: 4)
                == Sheet.collapsedDetentHeight(alone) + 164 + Sheet.gutter)
        #expect(Sheet.collapsedDetentHeight(alone) < Sheet.collapsedDetentHeight(metrics))

        // The sound alone (#1147): the collapsed sheet ends under the sound
        // with the usual gutter, and growing it reveals nothing.
        var soundOnly = alone
        soundOnly.hasRecent = false
        #expect(Sheet.foldBottom(soundOnly) == Sheet.topInset + 96 + Sheet.contentBottom)
        #expect(Sheet.revealLine(soundOnly) == 96 + Sheet.contentBottom, "something below the sound fades")
        #expect(Sheet.fittedDetentHeight(soundOnly, recentCount: 0) == Sheet.collapsedDetentHeight(soundOnly) + 1)

        // The row alone: the sound and the whole row, then the gutter.
        var rowOnly = metrics
        rowOnly.hasRecent = false
        #expect(Sheet.foldBottom(rowOnly) == Sheet.topInset + 96 + gap + 44 + Sheet.ribbonRoom + 144 + Sheet.contentBottom)
        #expect(Sheet.fittedDetentHeight(rowOnly, recentCount: 0) == Sheet.collapsedDetentHeight(rowOnly) + 1)
        #expect(Sheet.collapsedDetentHeight(soundOnly) < Sheet.collapsedDetentHeight(rowOnly))

        // Expanded is the fitted detent or large, never collapsed.
        #expect(Sheet.isExpanded(.large) && Sheet.isExpanded(Sheet.fittedDetent))
        #expect(!Sheet.isExpanded(Sheet.collapsedDetent) && !Sheet.isExpanded(nil))
    }

    /// Only a bar-sized band is kept: none is a safe area without its bar,
    /// and one near the view's height is a safe area caught mid-setup (CI,
    /// iOS 26.2: the detent came out ~780pt above its fold).
    @Test func anImplausibleToolbarBandIsNotKept() {
        #expect(Sheet.isPlausibleToolbarBand(52, viewHeight: 446))
        #expect(Sheet.isPlausibleToolbarBand(48, viewHeight: 812))
        #expect(!Sheet.isPlausibleToolbarBand(0, viewHeight: 446))
        #expect(!Sheet.isPlausibleToolbarBand(784, viewHeight: 874))
        #expect(!Sheet.isPlausibleToolbarBand(150, viewHeight: 874))
    }

    /// The detent's value is the fold the LAYOUT lays out plus the band it
    /// was computed with: the sound and its room, the Popular row whole above
    /// it, the Recent title right on the row's foot and whole above it too,
    /// the top of the grid's first row, and the reveal's line on that title's
    /// TOP — the title fades with its grid.
    ///
    /// ⚠️ Read off the layout and the detent's own inputs, never off the
    /// toolbar's view or a window's safe areas: the bar's frame spans the
    /// whole view on iOS 27, and the test host's safe areas are not a sheet's
    /// (on CI, iOS 26.2, a window-hosted version of this test failed by
    /// ~780pt).
    @Test func theComputedFoldIsTheLaidOutFold() throws {
        let controller = sheet(tiles: 23, original: 0)
        try laidOut(controller)
        let metrics = try #require(controller.detentMetrics)
        #expect(metrics.hasPopular)
        let collapsed = try #require(controller.collapsedHeight)
        #expect(collapsed == Sheet.collapsedDetentHeight(metrics))

        let sound = try frame(of: .sound, in: controller)
        #expect(sound.minY == 0 && sound.height == metrics.headerHeight)
        let title = try headerFrame(of: .popular, in: controller)
        #expect(abs(title.minY - sound.maxY - metrics.sectionGap) < 0.5, "the Popular title is off the sound's gap")
        #expect(title.height == metrics.sectionHeaderHeight)
        let popular = try tileIDs(in: .popular, of: controller)
        let row = try popular.prefix(4).map { try frame(of: .tile(PostID($0), .popular), in: controller) }
        // The row leaves "Original"'s overhang clear under its title (#1280).
        #expect(row.allSatisfy { abs($0.minY - title.maxY - Sheet.ribbonRoom) < 0.5 },
                "the row is not one line under its title")
        let recent = try headerFrame(of: .recent, in: controller)
        #expect(abs(recent.minY - row[0].maxY - metrics.sectionGap) < 0.5,
                "no section gap between the row and the Recent title")
        #expect(abs(recent.minY - Sheet.recentTitleTop(metrics)) < 0.5)
        let line = Sheet.revealLine(metrics)
        #expect(abs(line - recent.minY) < 0.5, "the reveal's line is off the Recent title's top")

        let firstID = try #require(try tileIDs(in: .recent, of: controller).first)
        let first = try frame(of: .tile(PostID(firstID), .recent), in: controller)
        #expect(abs(first.minY - recent.maxY) < 0.5, "the Recent grid is not one line under its title")
        // Content coordinates start under the inset below the grabber.
        let foldFromLayout = Sheet.topInset + first.minY + Sheet.recentPeekHeight(width: metrics.width)
        #expect(abs(foldFromLayout - Sheet.foldBottom(metrics)) <= 0.5,
                "laid out \(foldFromLayout), computed \(Sheet.foldBottom(metrics))")
        #expect(Sheet.foldBottom(metrics) < Sheet.topInset + first.maxY, "the fold shows the whole first row")
        #expect(abs(collapsed - (Sheet.foldBottom(metrics) + metrics.toolbarBand)) <= 1)
    }

    /// Without Popular, the Recent title stands on the sound's gap, the
    /// collapsed fold shows its WHOLE first row and ends where the second
    /// starts, and the reveal's line is the first row's foot — as laid out.
    @Test func withoutPopularTheFoldIsTheLaidOutFoldToo() throws {
        let controller = sheet(tiles: 7, popular: false)
        try laidOut(controller)
        let metrics = try #require(controller.detentMetrics)
        #expect(!metrics.hasPopular)
        let sound = try frame(of: .sound, in: controller)
        let recent = try headerFrame(of: .recent, in: controller)
        #expect(abs(recent.minY - sound.maxY - metrics.sectionGap) < 0.5, "the Recent title is off the sound's gap")
        #expect(abs(recent.minY - Sheet.recentTitleTop(metrics)) < 0.5)
        let ids = try tileIDs(in: .recent, of: controller)
        #expect(ids.count == 7)
        let first = try frame(of: .tile(PostID(ids[0]), .recent), in: controller)
        let second = try frame(of: .tile(PostID(ids[Sheet.columns]), .recent), in: controller)
        #expect(abs(first.minY - recent.maxY) < 0.5, "the Recent grid is not one line under its title")
        #expect(abs(Sheet.revealLine(metrics) - first.maxY) < 0.5, "the reveal's line is off the first row's foot")
        #expect(abs(Sheet.topInset + second.minY - Sheet.foldBottom(metrics)) <= 0.5,
                "laid out \(Sheet.topInset + second.minY), computed \(Sheet.foldBottom(metrics))")
        #expect(Sheet.topInset + first.maxY < Sheet.foldBottom(metrics), "the first row is not whole at collapsed")
        #expect(controller.collapsedHeight == Sheet.collapsedDetentHeight(metrics))
    }

    /// ONE section gap: every title's LINE stands `Spacing.section` under
    /// what is above it and `Spacing.sectionTitle` over its posts — the
    /// distances For You's rows and its pushed lists keep too.
    @Test func theTitlesKeepTheAppsSectionGap() throws {
        let controller = sheet(tiles: 23)
        try laidOut(controller)
        let metrics = try #require(controller.detentMetrics)
        let line = UIFont.preferredFont(forTextStyle: .title3).lineHeight
        let air = (metrics.sectionHeaderHeight - line) / 2
        #expect(abs(air - Spacing.sectionTitle) <= 0.5, "the title's line is \(air) over its posts")
        #expect(abs(metrics.sectionGap + air - Spacing.section) <= 0.5,
                "the title's line is \(metrics.sectionGap + air) under what is above it")
    }

    /// The fitted height is the content the LAYOUT lays out — its whole
    /// height, the grid's rows counted from its posts — plus the inset under
    /// the grabber and the toolbar's band; and it follows the post count, in
    /// both shapes.
    @Test func theFittedHeightIsTheLaidOutContent() throws {
        // (0, _): the sound alone; (5, true): the row alone (#1147).
        for (count, popular) in [(0, false), (1, false), (7, false), (5, true), (23, true)] {
            let controller = sheet(tiles: count, popular: popular)
            try laidOut(controller)
            let metrics = try #require(controller.detentMetrics)
            let snapshot = try dataSource(of: controller).snapshot()
            let recentCount = snapshot.sectionIdentifiers.contains(.posts(.recent))
                ? snapshot.numberOfItems(inSection: .posts(.recent)) : 0
            let content = try grid(of: controller).collectionViewLayout.collectionViewContentSize.height
            #expect(abs(content - Sheet.contentHeight(metrics, recentCount: recentCount)) < 0.5, """
                \(count) posts (popular \(metrics.hasPopular)): laid out \(content), \
                computed \(Sheet.contentHeight(metrics, recentCount: recentCount))
                """)
            #expect(controller.fittedHeight == Sheet.fittedDetentHeight(metrics, recentCount: recentCount))
        }
    }

    /// ONE gutter: the sheet's side margin is the gap between tiles and
    /// between rows, and the titles start on the tiles' left edge. The sound
    /// stands further in, `headerInset`. A row shows three tiles and the
    /// fourth peeking.
    @Test func oneGutterAlignsTheSheet() throws {
        let controller = sheet(tiles: 23)
        try laidOut(controller)
        let gutter = Sheet.gutter
        let width = try #require(controller.detentMetrics?.width)

        let popular = try tileIDs(in: .popular, of: controller)
        let row = try popular.prefix(4).map { try frame(of: .tile(PostID($0), .popular), in: controller) }
        #expect(abs(row[0].minX - gutter) < 0.5, "left margin \(row[0].minX)")
        #expect(abs(row[1].minX - row[0].maxX - gutter) < 0.5, "gap between tiles in a row")
        #expect(abs(row[0].width - Sheet.rowTileWidth(width: width)) < 0.5)
        #expect(row[2].maxX < width && row[3].minX < width && row[3].maxX > width, "no peek of a fourth tile")

        let recent = try tileIDs(in: .recent, of: controller)
        let grid = try recent.prefix(4).map { try frame(of: .tile(PostID($0), .recent), in: controller) }
        #expect(abs(grid[0].minX - gutter) < 0.5, "grid left margin \(grid[0].minX)")
        #expect(abs(width - grid[2].maxX - gutter) < 0.5, "grid right margin \(width - grid[2].maxX)")
        #expect(abs(grid[1].minX - grid[0].maxX - gutter) < 0.5, "gap between grid tiles")
        #expect(abs(grid[3].minY - grid[0].maxY - gutter) < 0.5, "gap between grid rows")
        #expect(abs(grid[0].height - Sheet.tileHeight(width: width)) < 0.5)

        let sound = try frame(of: .sound, in: controller)
        #expect(abs(sound.minX - Sheet.headerInset) < 0.5, "the sound has no room on its leading side")
        let title = try headerFrame(of: .recent, in: controller)
        #expect(abs(title.minX - gutter) < 0.5, "a title is off the tiles' edge")
    }

    /// ⚠️ The regression: #296 re-read the fold in `viewDidLayoutSubviews` and
    /// re-asked the detents from there — a stack overflow when dragged from
    /// the grabber, and a collapsed height that drifted between visits. Laying
    /// the sheet out at any height, large and back, must neither move the
    /// collapsed height nor re-ask the detents.
    @Test func layoutNeverInvalidatesTheDetentsAndCollapsedComesBackIdentical() throws {
        let controller = sheet(tiles: 23)
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
        // …and back down.
        presentation.selectedDetentIdentifier = SoundSheetViewController.collapsedDetent
        controller.sheetPresentationControllerDidChangeSelectedDetentIdentifier(presentation)
        for height in stride(from: 874, through: before, by: -67) { layOut(at: height) }

        #expect(controller.collapsedHeight == before, "the collapsed height drifted over a large round trip")
        #expect(controller.detentInvalidations == invalidations, "a layout pass re-asked the detents")
    }

    /// The fold counts no posts: twelve posts or twenty-three, the collapsed
    /// detent is the same, and the posts arriving never re-ask it. The
    /// fitted height follows them.
    @Test func thePostCountNeverMovesTheCollapsedDetent() throws {
        let many = sheet(tiles: 23)
        _ = many.wrappedInSheet()
        many.loadViewIfNeeded()
        let few = sheet(tiles: 12)
        _ = few.wrappedInSheet()
        few.loadViewIfNeeded()
        #expect(many.collapsedHeight == few.collapsedHeight)

        let invalidations = many.detentInvalidations
        let content = Self.content(12)
        many.update(sections: content.sections, tiles: content.tiles)
        #expect(many.collapsedHeight == few.collapsedHeight)
        #expect(many.detentInvalidations == invalidations, "a change of posts re-asked the detents")
        let metrics = try #require(many.detentMetrics)
        #expect(many.fittedHeight == Sheet.fittedDetentHeight(metrics, recentCount: 4))
    }

    /// The SHAPES differ, and only a change of shape re-asks the collapsed
    /// detent: posts that could not be loaded leaving the row with every
    /// other post, "Recent" goes (#1147) — an input, answered once.
    @Test func losingRecentReasksTheCollapsedDetentOnce() throws {
        let controller = sheet(tiles: 12)
        _ = controller.wrappedInSheet()
        controller.loadViewIfNeeded()
        let before = try #require(controller.collapsedHeight)
        let invalidations = controller.detentInvalidations

        let content = Self.content(8)
        controller.update(sections: content.sections, tiles: content.tiles)
        #expect(content.sections.map(\.kind) == [.popular])
        let metrics = try #require(controller.detentMetrics)
        #expect(metrics.hasPopular && !metrics.hasRecent)
        #expect(controller.collapsedHeight == Sheet.collapsedDetentHeight(metrics))
        #expect(controller.collapsedHeight != before)
        #expect(controller.detentInvalidations > invalidations, "the new shape did not re-ask the detents")
        #expect(Sheet.revealLine(metrics) == Sheet.popularRowBottom(metrics) + Sheet.contentBottom,
                "something under the row still fades")
    }

    // MARK: - Reveal

    /// The reveal is a pure function of the sheet's height: 0 at collapsed
    /// and below, 1 from `reach` of the way to large, linear between — the
    /// same height always reading the same.
    @Test func theRevealFollowsTheHeight() {
        let collapsed: CGFloat = 400, large: CGFloat = 800
        func progress(_ height: CGFloat) -> CGFloat {
            SoundSheetReveal.progress(height: height, collapsed: collapsed, expanded: large)
        }
        #expect(progress(300) == 0)
        #expect(progress(400) == 0)
        let whole = collapsed + (large - collapsed) * SoundSheetReveal.reach
        #expect(abs(progress((collapsed + whole) / 2) - 0.5) < 0.001)
        #expect(progress(whole) == 1)
        #expect(progress(800) == 1)
        let heights = stride(from: CGFloat(380), through: 820, by: 7).map(progress)
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 }, "the reveal went backwards")
        // A sheet with nowhere to grow is whole above collapsed.
        #expect(SoundSheetReveal.progress(height: 401, collapsed: 400, expanded: 400) == 1)
    }

    /// The reveal masks the sheet's screen while under 1 — the fading band
    /// FAINT at collapsed, never gone, and whole at 1 — and takes the mask
    /// off at 1, so a sheet at its expanded detent pays no offscreen pass.
    @Test func theRevealMasksUntilWhole() throws {
        let controller = sheet(tiles: 23)
        try laidOut(controller)
        let reveal = controller.reveal
        reveal.set(0)
        #expect(reveal.isMasking)
        #expect(abs(CGFloat(reveal.fadingOpacity) - SoundSheetReveal.restingOpacity) < 0.001)
        #expect(SoundSheetReveal.restingOpacity > 0 && SoundSheetReveal.restingOpacity < 0.5,
                "the Recent title is gone, or plainly legible, at collapsed")
        reveal.set(0.4)
        #expect(reveal.isMasking)
        #expect(abs(CGFloat(reveal.fadingOpacity) - SoundSheetReveal.opacity(progress: 0.4)) < 0.001)
        #expect(SoundSheetReveal.opacity(progress: 1) == 1)
        reveal.set(1)
        #expect(!reveal.isMasking, "a whole sheet still wears the mask")
        reveal.set(0.2)
        #expect(reveal.isMasking)
    }

    /// Without a Popular row, the rows after "Recent"'s first fade — the
    /// mask on at collapsed — and only the first row answers a tap there;
    /// under a row, the whole of "Recent" is faint and answers none.
    @Test func withoutPopularTheRowsAfterTheFirstFade() throws {
        let controller = sheet(tiles: 7, popular: false)
        try laidOut(controller)
        controller.reveal.set(0)
        #expect(controller.reveal.isMasking, "the rows after the first are not faint at collapsed")
        #expect(controller.isRevealed(.recent, item: 0) && controller.isRevealed(.recent, item: Sheet.columns - 1),
                "the first row does not answer at collapsed")
        #expect(!controller.isRevealed(.recent, item: Sheet.columns), "a faint tile answers a tap")
        controller.reveal.set(1)
        #expect(!controller.reveal.isMasking)
        #expect(controller.isRevealed(.recent, item: 6))

        let withRow = sheet(tiles: 23)
        try laidOut(withRow)
        withRow.reveal.set(0)
        #expect(withRow.reveal.isMasking)
        #expect(!withRow.isRevealed(.recent, item: 0), "a faint tile answers a tap")
        #expect(withRow.isRevealed(.popular, item: 5))
    }

    // MARK: - Scrolling

    /// The posts scroll only at the fullest detent: UIKit's scroll-to-expand
    /// on (a drag below it grows the sheet), no bounce of their own (a
    /// content that fits its sheet leaves the drag to the sheet — the bounce
    /// slid a one-post sound under the ✕), and the posts resting at their top
    /// — never pushed down from a pull.
    @Test func thePostsScrollOnlyAtTheFullestDetent() throws {
        let controller = sheet(tiles: 23)
        let navigation = try laidOut(controller)
        let collection = try grid(of: controller)
        #expect(navigation.sheetPresentationController?.prefersScrollingExpandsWhenScrolledToEdge == true)
        #expect(!collection.alwaysBounceVertical, "a content that fits bounces under the ✕")
        #expect(controller.isAtFullestDetent, "off a presented sheet the posts must scroll")
        controller.showSection(.popular)
        let gallery = try #require(navigation.topViewController as? SoundSheetGalleryViewController)
        gallery.loadViewIfNeeded()
        #expect(!gallery.grid.alwaysBounceVertical, "the pushed section bounces under its bar")

        let list = UIScrollView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        list.contentInsetAdjustmentBehavior = .never
        list.contentInset.top = Sheet.topInset
        list.contentSize = CGSize(width: 100, height: 1000)
        list.contentOffset.y = 240
        Sheet.restAtTop(list)
        #expect(list.contentOffset.y == -Sheet.topInset)
        list.contentOffset.y = -Sheet.topInset - 30
        Sheet.restAtTop(list)
        #expect(list.contentOffset.y == -Sheet.topInset - 30, "a pull down was pushed back")
    }

    // MARK: - Chevron

    /// The sheet's titles are the app's ONE section title (`SectionTitleView`,
    /// 2026-09-30): the chevron RIGHT AFTER the title, not at the header's far
    /// end, and the whole bar one control that pushes; a section that shows
    /// everything is a plain title. And the title stands the app's one inset
    /// from the SHEET's edge, though its header lies in the tiles' 8pt gutter.
    @Test func theChevronFollowsTheTitle() throws {
        let controller = sheet(tiles: 23, original: 0)
        try laidOut(controller)
        let collection = try grid(of: controller)
        func head(_ kind: SoundSheetSection.Kind) throws -> SectionTitleSupplementaryView {
            let section = try #require(dataSource(of: controller).snapshot().indexOfSection(.posts(kind)))
            let view = try #require(collection.supplementaryView(
                forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)
            ) as? SectionTitleSupplementaryView)
            view.layoutIfNeeded()
            return view
        }
        let popular = try head(.popular).titleView
        #expect(popular.debugTitleText == "Popular")
        #expect(popular.debugShowsChevron)
        #expect(popular.accessibilityTraits.contains(.button))
        let frames = popular.debugFrames
        let titleInSheet = popular.convert(frames.title, to: collection).minX - collection.bounds.minX
        #expect(abs(titleInSheet - SectionTitleView.Metrics.surfaceInset) < 0.5,
                "the title stands \(titleInSheet) from the sheet's edge")
        #expect(abs(frames.chevron.minX - frames.title.maxX - SectionTitleView.Metrics.titleToChevron) < 0.5,
                "the chevron is not right after the title")
        #expect(frames.chevron.maxX < collection.bounds.width / 2, "the chevron sits at the header's far end")
        #expect(!allSubviews(of: popular).compactMap { $0 as? UILabel }.contains { $0.text == "View all" })

        let recent = try head(.recent).titleView
        #expect(recent.debugTitleText == "Recent")
        #expect(!recent.debugShowsChevron, "a section that shows everything offers a chevron")
        #expect(recent.accessibilityTraits.contains(.header))
        #expect(!recent.accessibilityTraits.contains(.button))
    }

    /// Popular's title and chevron push its WHOLE ranking inside the sheet — a
    /// grid under a titled bar with UIKit's SOFT top edge, the sheet's
    /// toolbar kept — and leaves the sheet at its detent: collapsed stays
    /// collapsed. A save made there shows on the sheet's own bookmark.
    @Test func viewAllPushesPopularAtTheSameDetent() throws {
        let store = Self.isolatedStore()
        let controller = sheet(tiles: 23, saved: store)
        let navigation = try laidOut(controller)
        let presentation = try #require(navigation.sheetPresentationController)
        controller.reveal.set(0)
        controller.showSection(.popular)

        let gallery = try #require(navigation.topViewController as? SoundSheetGalleryViewController)
        #expect(controller.pushedGallery === gallery)
        #expect(gallery.title == "Popular")
        let popular = try #require(controller.sections.first { $0.kind == .popular })
        #expect(gallery.ids == popular.all, "the gallery is not the whole ranking")
        gallery.loadViewIfNeeded()
        #expect(gallery.grid.numberOfItems(inSection: 0) == popular.all.count)
        #expect(!controller.isExpanded, "the push raised the sheet")
        #expect(presentation.selectedDetentIdentifier == SoundSheetViewController.collapsedDetent,
                "the push moved the sheet off collapsed")
        #expect(!navigation.isNavigationBarHidden)
        #expect(!gallery.grid.topEdgeEffect.isHidden && gallery.grid.topEdgeEffect.style == .soft,
                "the title's blur is not the light one")
        #expect(gallery.contentScrollView(for: .top) === gallery.grid)
        #expect(gallery.toolbarItems?.count == controller.toolbarItems?.count, "the pushed screen lost the toolbar")

        let galleryBookmark = try #require(gallery.toolbarItems?.first { $0.accessibilityLabel == "Save sound" })
        controller.debugToggleSaved()
        #expect(galleryBookmark.accessibilityLabel == "Sound saved")
        #expect(controller.bookmarkItem?.accessibilityLabel == "Sound saved")
    }

    /// The Recent grid shows everything it holds: no chevron, and nothing to
    /// push even once the sheet is whole.
    @Test func theRecentGridDoesNotPush() throws {
        let controller = sheet(tiles: 23)
        let navigation = try laidOut(controller)
        controller.reveal.set(1)
        let recent = try #require(controller.sections.first { $0.kind == .recent })
        #expect(!recent.hasMore)
        controller.showSection(.recent)
        #expect(navigation.topViewController === controller, "the Recent grid pushed")
    }
}
