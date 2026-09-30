import CoreModels
import CoreNavigation
import CoreStorage
import FeedInterface
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The sound sheet's rules: how it opens (the close item in its bar, the
/// content behind the bar, one gutter under its top edge), that no detent —
/// large included — pauses the clip behind, the two sections (the Popular
/// row with "Original" first, the Recent grid of EVERY post, newest first —
/// a popular post in both), the toolbar ([Use this sound —][🔖][↑]), the one
/// gutter and no gap between sections, that the collapsed detent ends a
/// little into the Recent grid's first row, over the toolbar — at the SAME
/// height at every visit and for any number of posts, with no layout pass
/// ever re-asking the detents — that the expanded detent fits a short
/// content, the reveal of the Recent title and grid as one (faint at
/// collapsed), and Popular's title + chevron.
@MainActor
struct SoundSheetTests {
    private typealias Sheet = SoundSheetViewController

    private func sheet(
        tiles count: Int = 1, original: Int? = nil, saved: SavedSoundStore? = nil
    ) -> SoundSheetViewController {
        let content = Self.content(count, original: original)
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
    /// the reverse.
    private static func rankings(_ count: Int) -> PostSoundRankings {
        let ids = ids(count)
        return PostSoundRankings(popular: ids, recent: ids.reversed())
    }

    /// The sections over `count` posts, p0 the post watched, and a tile for
    /// each post.
    private static func content(
        _ count: Int, original: Int? = nil, loaded: (Int) -> Bool = { _ in true }
    ) -> (sections: [SoundSheetSection], tiles: [SoundSheetViewController.Tile]) {
        let dealt = SoundSheetSections.make(
            rankings: rankings(count), current: PostID("p0"),
            original: original.map { PostID("p\($0)") }, isMedia: { _ in true }
        )
        let tiles = (0..<count).map { (index: Int) in
            SoundSheetViewController.Tile(
                postID: PostID("p\(index)"), thumbnailURL: nil, caption: nil,
                isCurrent: index == 0, isOriginal: dealt.original == PostID("p\(index)"),
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

    /// The bar's one item is the close button, at its trailing end; the
    /// content starts BEHIND the bar — no inset from it, the sound
    /// `topInset` under the grabber — with no blur over it.
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
        #expect(Sheet.topInset == Sheet.gutter, "the header's top margin is not its side margin")
        #expect(collection.topEdgeEffect.isHidden, "a blur over the sound at rest")
        #expect(controller.contentScrollView(for: .top) === collection)
    }

    /// The header's lines stop short of the close button and hold ONE line
    /// each, truncated: a long name neither runs under the ✕ nor makes the
    /// header — and so the collapsed detent — taller.
    @Test func theHeaderClearsTheCloseButtonAndTruncates() throws {
        let width: CGFloat = 402 - 2 * Sheet.gutter
        func height(_ title: String) -> CGFloat {
            SoundSheetHeaderView.fittingHeight(
                width: width, title: title, subtitle: "Daft Punk", meta: "0:30 · 23 posts", canPreview: true
            )
        }
        let long = String(repeating: "Veridis Quo ", count: 12)
        #expect(height(long) == height("Veridis Quo"), "a long name made the header taller")

        let header = SoundSheetHeaderView(frame: CGRect(x: 0, y: 0, width: width, height: height(long)))
        header.configure(title: long, subtitle: long, meta: "0:30 · 23 posts", canPreview: true)
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
            postID: post.id, thumbnailURL: post.thumbnailURL, caption: post.caption,
            isCurrent: false, isOriginal: true
        )
    }

    /// ⚠️ The regression: the flight card rounded as a For You brick (16pt)
    /// and landed on a 12pt tile, so the corners jumped in the frame the card
    /// was taken away — the flash at the end of every close. The card lands
    /// on the tile's own corner AND curve.
    @Test func aTilesFlightLandsOnTheTilesOwnCorner() throws {
        let controller = sheet(tiles: 3)
        try laidOut(controller)
        let post = Self.galleryPost("p1", kind: .photo)
        let origin = controller.heroOrigin(for: Self.tile(for: post), post: post, stream: [post], source: .sheet(.popular))
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
        let words = controller.heroOrigin(for: Self.tile(for: text), post: text, stream: [text], source: .sheet(.popular))
        #expect(words.hasHero == false, "a text tile has no picture to fly")
        let window = try #require(words.textReveal, "a text tile opened with the plain push")
        #expect(window.cornerRadius == SoundSheetTileCell.cornerRadius)
        #expect(window.alignsPageToSource == false)
        #expect(window.pageFit == .covering)
        #expect(window.fill.map { Self.alpha(of: $0) } == 1, "the window's ground is see-through")

        let photo = Self.galleryPost("p2", kind: .photo)
        let media = controller.heroOrigin(for: Self.tile(for: photo), post: photo, stream: [photo], source: .sheet(.popular))
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

    // MARK: - Sections

    /// 23 posts, a row of 8: Popular is the original, the post watched, then
    /// the most engaged; Recent is EVERY post, newest first — the ones in the
    /// row included. Popular's chevron is its whole ranking; Recent — which
    /// shows everything it holds — has none.
    @Test func recentHoldsEveryPostNewestFirst() throws {
        let rankings = Self.rankings(23)
        let dealt = SoundSheetSections.make(
            rankings: rankings, current: PostID("p5"), original: PostID("p9"), isMedia: { _ in true }, rowLimit: 8
        )
        #expect(dealt.sections.map(\.kind) == [.popular, .recent])
        #expect(dealt.original == PostID("p9"))
        let popular = dealt.sections[0], recent = dealt.sections[1]
        #expect(popular.ids.map(\.rawValue) == ["p9", "p5", "p0", "p1", "p2", "p3", "p4", "p6"])
        #expect(popular.all.count == 23 && popular.all.prefix(8) == popular.ids.prefix(8))
        #expect(recent.ids == rankings.recent, "Recent is not every post in date order")
        #expect(recent.ids.first == PostID("p22"))
        #expect(recent.all == recent.ids)
        #expect(Set(popular.ids).isSubset(of: Set(recent.ids)), "a popular post is missing from Recent")
        #expect(popular.hasMore)
        #expect(!recent.hasMore, "the grid offers a chevron")
        #expect(SoundSheetSection.Kind.allCases == [.popular, .recent])
        #expect(SoundSheetSection.Kind.recent.title == "Recent")
        #expect(SoundSheetSection.Kind.popular.isRow && !SoundSheetSection.Kind.recent.isRow)
    }

    /// A post the date order leaves out (a ranking that lags) is still
    /// recent: at the grid's end.
    @Test func aPostTheDateOrderMissesJoinsTheGridsEnd() {
        let popular = Self.ids(12)
        let dealt = SoundSheetSections.make(
            rankings: PostSoundRankings(popular: popular, recent: Array(popular.dropLast().reversed())),
            current: PostID("p0"), original: nil, isMedia: { _ in true }, rowLimit: 8
        )
        #expect(dealt.sections.last?.kind == .recent)
        #expect(dealt.sections.last?.ids.last == PostID("p11"))
        #expect(dealt.sections.last?.ids.count == 12)
    }

    /// Recent is never empty: a few posts are in the row AND the grid, and
    /// with no provider at all the post watched is both.
    @Test func recentIsNeverEmpty() {
        let dealt = SoundSheetSections.make(
            rankings: Self.rankings(5), current: PostID("p0"), original: nil, isMedia: { _ in true }, rowLimit: 8
        )
        #expect(dealt.sections.map(\.kind) == [.popular, .recent])
        #expect(dealt.sections.first?.hasMore == false, "a row that shows everything offers a chevron")
        #expect(dealt.sections.last?.ids.count == 5)

        let alone = SoundSheetSections.make(
            rankings: .empty, current: PostID("cur"), original: nil, isMedia: { _ in true }
        )
        #expect(alone.sections.map(\.kind) == [.popular, .recent])
        #expect(alone.sections.allSatisfy { $0.ids == [PostID("cur")] })
    }

    /// A post that could not be loaded leaves every section, and the row
    /// fills up again behind it.
    @Test func anExcludedPostLeavesAndTheRowRefills() throws {
        let dealt = SoundSheetSections.make(
            rankings: Self.rankings(23), current: PostID("p0"), original: nil, isMedia: { _ in true },
            excluding: [PostID("p2"), PostID("p22")], rowLimit: 8
        )
        #expect(!dealt.sections.contains { $0.all.contains(PostID("p2")) || $0.all.contains(PostID("p22")) })
        #expect(dealt.sections[0].ids.count == 8 && dealt.sections[1].ids.count == 21)
        #expect(dealt.sections[1].ids.first == PostID("p21"))
    }

    /// The sheet lays the sections out in order, under the sound: the row,
    /// then the grid — a post in both is two items, one per section.
    @Test func theSheetShowsTheSectionsInOrder() throws {
        let controller = sheet(tiles: 23, original: 0)
        try laidOut(controller)
        let snapshot = try dataSource(of: controller).snapshot()
        #expect(snapshot.sectionIdentifiers == [.sound, .posts(.popular), .posts(.recent)])
        #expect(try tileIDs(in: .popular, of: controller).first == "p0")
        #expect(try tileIDs(in: .recent, of: controller).count == 23)
        #expect(snapshot.indexOfItem(.tile(PostID("p0"), .popular)) != nil)
        #expect(snapshot.indexOfItem(.tile(PostID("p0"), .recent)) != nil)
        #expect(controller.tiles.first { $0.postID == PostID("p0") }?.isOriginal == true)
        let items = snapshot.itemIdentifiers
        #expect(Set(items).count == items.count)
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
            rankings: Self.rankings(12), current: PostID("p0"), original: nil, isMedia: { _ in true },
            excluding: [PostID("p11")]
        )
        controller.update(sections: dealt.sections, tiles: (0..<11).map { (index: Int) in
            SoundSheetViewController.Tile(
                postID: PostID("p\(index)"), thumbnailURL: nil, caption: "post \(index)", isCurrent: index == 0
            )
        })
        #expect(controller.tiles.count == 11)
        #expect(controller.tiles.allSatisfy { $0.isLoaded })
        #expect(try !tileIDs(in: .recent, of: controller).contains("p11"))
        #expect(try tileIDs(in: .recent, of: controller).first == "p10")
        #expect(try tileIDs(in: .recent, of: controller).count == 11)
    }

    // MARK: - Collapsed detent

    /// The arithmetic: the fold is the inset under the grabber, the header,
    /// the Popular title, its row, then — no gap — the Recent title and the
    /// top of its first row; the toolbar's band is the bottom safe area ABOVE
    /// the window's, which the sheet adds by itself. The reveal's line is the
    /// Recent title's top. The fitted height is the whole content.
    @Test func theDetentsAreComputed() {
        #expect(Sheet.toolbarBand(bottomSafeArea: 34 + 52, windowBottomSafeArea: 34) == 52)
        #expect(Sheet.toolbarBand(bottomSafeArea: 20, windowBottomSafeArea: 34) == 0)
        // 402 wide: (402 - 4 × 8) / 3 = 123.33 → 3:4 → 164.4 → 164.
        #expect(Sheet.tileHeight(width: 402) == 164)
        // A row: (402 - 4 × 8) / 3.4 = 108.8 → 108 → 3:4 → 144.
        #expect(Sheet.rowTileWidth(width: 402) == 108)
        #expect(Sheet.rowTileHeight(width: 402) == 144)
        #expect(Sheet.recentPeekHeight(width: 402) == 41)
        let metrics = Sheet.DetentMetrics(width: 402, headerHeight: 96, sectionHeaderHeight: 44, toolbarBand: 52.2)
        #expect(Sheet.recentTitleTop(metrics) == CGFloat(96 + 44 + 144), "a gap between the row and the Recent title")
        #expect(Sheet.foldBottom(metrics) == Sheet.topInset + 96 + 44 + 144 + 44 + 41)
        #expect(Sheet.collapsedDetentHeight(metrics) == (Sheet.foldBottom(metrics) + 52.2).rounded(.up))
        #expect(Sheet.revealLine(metrics) == Sheet.recentTitleTop(metrics), "the Recent title does not fade")

        // The grid: rows of 164, a gutter between.
        #expect(Sheet.gridHeight(width: 402, count: 1) == 164)
        #expect(Sheet.gridHeight(width: 402, count: 3) == 164)
        #expect(Sheet.gridHeight(width: 402, count: 4) == 2 * 164 + Sheet.gutter)
        #expect(Sheet.contentHeight(metrics, recentCount: 5)
                == 96 + 44 + 144 + 44 + 2 * 164 + Sheet.gutter + Sheet.contentBottom)
        #expect(Sheet.fittedDetentHeight(metrics, recentCount: 5)
                == (Sheet.topInset + Sheet.contentHeight(metrics, recentCount: 5) + 52.2).rounded(.up))
        // One post: still taller than collapsed — the sheet always grows.
        #expect(Sheet.fittedDetentHeight(metrics, recentCount: 1) > Sheet.collapsedDetentHeight(metrics))
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
    /// was computed with: the Popular row whole above it, the Recent title
    /// right on the row's foot and whole above it too, the top of the grid's
    /// first row, and the reveal's line on that title's TOP — the title fades
    /// with its grid.
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
        let collapsed = try #require(controller.collapsedHeight)
        #expect(collapsed == Sheet.collapsedDetentHeight(metrics))

        let sound = try frame(of: .sound, in: controller)
        #expect(sound.minY == 0 && sound.height == metrics.headerHeight)
        let title = try headerFrame(of: .popular, in: controller)
        #expect(abs(title.minY - sound.maxY) < 0.5, "the Popular title is off the sound's foot")
        #expect(title.height == metrics.sectionHeaderHeight)
        let popular = try tileIDs(in: .popular, of: controller)
        let row = try popular.prefix(4).map { try frame(of: .tile(PostID($0), .popular), in: controller) }
        #expect(row.allSatisfy { abs($0.minY - title.maxY) < 0.5 }, "the row is not one line under its title")
        let recent = try headerFrame(of: .recent, in: controller)
        #expect(abs(recent.minY - row[0].maxY) < 0.5, "a gap between the row and the Recent title")
        #expect(abs(recent.minY - Sheet.recentTitleTop(metrics)) < 0.5)
        #expect(abs(Sheet.revealLine(metrics) - recent.minY) < 0.5, "the reveal's line is off the Recent title's top")

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

    /// The fitted height is the content the LAYOUT lays out — its whole
    /// height, the grid's rows counted from its posts — plus the inset under
    /// the grabber and the toolbar's band; and it follows the post count.
    @Test func theFittedHeightIsTheLaidOutContent() throws {
        for count in [1, 5, 23] {
            let controller = sheet(tiles: count)
            try laidOut(controller)
            let metrics = try #require(controller.detentMetrics)
            let content = try grid(of: controller).collectionViewLayout.collectionViewContentSize.height
            #expect(abs(content - Sheet.contentHeight(metrics, recentCount: count)) < 0.5,
                    "\(count) posts: laid out \(content), computed \(Sheet.contentHeight(metrics, recentCount: count))")
            #expect(controller.fittedHeight == Sheet.fittedDetentHeight(metrics, recentCount: count))
        }
    }

    /// ONE gutter: the sheet's side margin is the gap between tiles and
    /// between rows, and the sound and the titles start on the tiles' left
    /// edge. A row shows three tiles and the fourth peeking.
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
        #expect(abs(sound.minX - gutter) < 0.5, "the sound is off the tiles' edge")
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

    /// The fold counts no posts: two posts or twenty-three, the collapsed
    /// detent is the same, and the posts arriving never re-ask it. The
    /// fitted height follows them.
    @Test func thePostCountNeverMovesTheCollapsedDetent() throws {
        let many = sheet(tiles: 23)
        _ = many.wrappedInSheet()
        many.loadViewIfNeeded()
        let few = sheet(tiles: 2)
        _ = few.wrappedInSheet()
        few.loadViewIfNeeded()
        #expect(many.collapsedHeight == few.collapsedHeight)

        let invalidations = many.detentInvalidations
        let content = Self.content(3)
        many.update(sections: content.sections, tiles: content.tiles)
        #expect(many.collapsedHeight == few.collapsedHeight)
        #expect(many.detentInvalidations == invalidations, "a change of posts re-asked the detents")
        let metrics = try #require(many.detentMetrics)
        #expect(many.fittedHeight == Sheet.fittedDetentHeight(metrics, recentCount: 3))
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

    // MARK: - Chevron

    /// The chevron stands RIGHT AFTER the title, not at the header's far end,
    /// and the title and chevron are one control that pushes; a section that
    /// shows everything is a plain title.
    @Test func theChevronFollowsTheTitle() throws {
        let width: CGFloat = 386
        let header = SoundSheetSectionHeaderView(frame: CGRect(x: 0, y: 0, width: width, height: 44))
        var pushed = 0
        header.onViewAll = { pushed += 1 }
        header.configure(title: "Popular", hasMore: true)
        header.layoutIfNeeded()
        header.control.layoutIfNeeded()
        #expect(header.title == "Popular")
        #expect(header.offersViewAll)
        let title = try #require(header.control.titleLabel)
        let chevron = try #require(header.control.imageView)
        let titleFrame = title.convert(title.bounds, to: header)
        let chevronFrame = chevron.convert(chevron.bounds, to: header)
        #expect(abs(titleFrame.minX) < 0.5, "the title is off the tiles' edge")
        #expect(chevronFrame.minX >= titleFrame.maxX - 0.5, "the chevron is not after the title")
        #expect(chevronFrame.minX - titleFrame.maxX < 12, "the chevron stands off the title")
        #expect(chevronFrame.maxX < width / 2, "the chevron sits at the header's far end")
        #expect(!allSubviews(of: header).compactMap { $0 as? UILabel }.contains { $0.text == "View all" })
        header.sendViewAll()
        #expect(pushed == 1)

        header.configure(title: "Recent", hasMore: false)
        #expect(!header.offersViewAll, "a section that shows everything offers a chevron")
        #expect(header.title == "Recent")
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
