import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A card's carousel is a STRIP (2026-10-02): two whole 3:4 items and a third
/// cropped by the box's edge, resting on an item's edge picked by the
/// gesture's direction, one item per gesture — and the card it sits in about
/// half as tall as when a page nearly filled the box with a pill-shaped
/// sliver of the next beside it.
@MainActor
struct CardCarouselStripTests {
    /// The box of a 402pt phone's card: 402 less the list's margins (16 × 2)
    /// less the card's media inset (12 × 2).
    private let box: CGFloat = 346

    private func carousel(pages count: Int) -> MediaCarouselView {
        let height = MediaCarouselView.cardHeight(forBoxWidth: box, pageCount: count)
        let view = MediaCarouselView(
            style: .card, frame: CGRect(x: 0, y: 0, width: box, height: height)
        )
        view.configure(
            with: (0..<count).map {
                GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://t/\($0)"))
            },
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        view.layoutIfNeeded()
        return view
    }

    /// The item's rect in the box's space at the strip's current offset.
    private func rectInBox(_ view: MediaCarouselView, page: Int) -> CGRect {
        view.pageViews[page].convert(view.pageViews[page].bounds, to: view)
    }

    private func isWhole(_ rect: CGRect, in view: MediaCarouselView) -> Bool {
        rect.minX >= -0.5 && rect.maxX <= view.bounds.width + 0.5
    }

    // MARK: - Size

    /// 2.3 items per box, gaps counted: `2w + 2 × gap + 0.3w = box`, whole
    /// points.
    @Test func anItemIsSizedForTwoWholeAndAThirdCropped() {
        let width = MediaCarouselView.cardPageWidth(forBoxWidth: box, pageCount: 5)
        let expected = ((box - 2 * MediaCarouselView.gap) / 2.3).rounded(.down)

        #expect(width == expected)
        #expect(MediaCarouselView.cardPagesVisible(pageCount: 3) == 2.3)
        #expect(MediaCarouselView.cardPagesVisible(pageCount: 12) == 2.3)
    }

    /// ⚠️ TWO PAGES SHARE THE BOX, half and half — at 2.3 a third of the box
    /// would sit empty after the second item, a strip with nowhere to go.
    @Test func twoPagesFillTheBoxBetweenThem() {
        let view = carousel(pages: 2)

        #expect(MediaCarouselView.cardPagesVisible(pageCount: 2) == 2)
        #expect(abs(view.pageViews[0].frame.minX) < 0.5)
        #expect(abs(view.pageViews[1].frame.maxX - box) <= 1)
        #expect(view.hasTravel(towardsPageDelta: 1) == false)
    }

    /// Every item is 3:4 portrait and the box is exactly one item tall.
    @Test func theBoxIsOneItemTall() {
        let view = carousel(pages: 4)
        for page in view.pageViews {
            #expect(abs(page.frame.height / page.frame.width - 4.0 / 3.0) < 0.01)
            #expect(page.frame.height == view.bounds.height)
        }
    }

    /// ⚠️ THE POINT: a collection's card is clearly SHORTER than it was — the
    /// old box was the post's own shape across the whole width (a square was
    /// as tall as the box is wide, 4:5 taller still).
    @Test func aCollectionsPreviewIsAboutHalfWhatItWas() {
        let cardWidth = box + PostGridListRowCell.contentInset * 2
        let now = PostGridListRowCell.collectionMediaHeight(forCardWidth: cardWidth, pageCount: 4)
        let squareBefore = PostGridListRowCell.mediaHeight(forCardWidth: cardWidth, aspectRatio: 1)
        let portraitBefore = PostGridListRowCell.mediaHeight(forCardWidth: cardWidth, aspectRatio: 4.0 / 5.0)

        #expect(now < squareBefore * 0.6)
        #expect(now < portraitBefore / 2)
    }

    /// And the row itself, measured the way a list measures it: a collection
    /// row is shorter than the same post with one picture.
    @Test func aCollectionRowIsShorterThanASinglePictureRow() throws {
        func row(pages: Int) -> PostGridListRowCell {
            let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 370, height: 500))
            cell.configure(
                with: GalleryPost(
                    id: PostID("p"), kind: .photo, isRepost: false,
                    pages: (0..<pages).map {
                        GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://t/\($0)"), aspectRatio: 1)
                    },
                    caption: "Short.", publishedAtMS: 0
                ),
                imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
            )
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
            attributes.frame = cell.frame
            cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
            cell.layoutIfNeeded()
            return cell
        }
        let single = row(pages: 1)
        let collection = row(pages: 4)
        let preview = try #require(collection.mediaHeroRect)

        #expect(collection.bounds.height < single.bounds.height - 100)
        #expect(abs(preview.height
            - PostGridListRowCell.collectionMediaHeight(forCardWidth: 370, pageCount: 4)) < 0.5)
    }

    // MARK: - Rests

    /// The start is the first item flush with the box's left edge; the end is
    /// the last one flush with its right edge.
    @Test func theRunStartsFlushLeftAndEndsFlushRight() {
        let view = carousel(pages: 5)
        let anchors = view.debugAnchors()

        #expect(anchors.leading.contains(0))
        #expect(abs(rectInBox(view, page: 0).minX) < 0.5)

        view.setPage(4, animated: false)
        #expect(abs(rectInBox(view, page: 4).maxX - box) < 0.5)
        #expect(view.currentPage == 4)
        #expect(abs(view.debugContentOffsetX - (anchors.trailing.max() ?? -1)) < 0.5)
    }

    /// Releases the strip the way UIKit does, from `start` to `live` with
    /// `velocity`, and returns where it was told to rest.
    private func release(
        _ view: MediaCarouselView, from start: CGFloat, at live: CGFloat,
        velocity: CGFloat, projected: CGFloat
    ) -> CGFloat {
        let scrollView = UIScrollView()
        scrollView.contentOffset = CGPoint(x: start, y: 0)
        view.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: live, y: 0)
        var target = CGPoint(x: projected, y: 0)
        withUnsafeMutablePointer(to: &target) {
            view.scrollViewWillEndDragging(
                scrollView, withVelocity: CGPoint(x: velocity, y: 0), targetContentOffset: $0
            )
        }
        return target.x
    }

    /// Forward lands the item that was cropped on the right flush with the
    /// right edge — the next item, whole, and nothing cut on the right.
    @Test func aForwardSwipeBringsTheCroppedItemWholeToTheRightEdge() {
        let view = carousel(pages: 5)
        let target = release(view, from: 0, at: 20, velocity: 1.5, projected: 120)
        let item = view.pageViews[2].frame

        #expect(abs(target - (item.maxX - box)) < 0.5)
    }

    /// ⚠️ ONE ITEM PER GESTURE, however hard the flick: momentum decides how
    /// fast, never how far ("if I slide hard I scroll several photos at once"
    /// was a defect report). The projection says the end of the run; the rest
    /// is the item the finger left cropped.
    @Test func aViolentFlickStillMovesOneItem() {
        let view = carousel(pages: 8)
        let farEnd = view.debugAnchors().trailing.max() ?? 0
        let target = release(view, from: 0, at: 20, velocity: 9, projected: farEnd)

        #expect(abs(target - (view.pageViews[2].frame.maxX - box)) < 0.5)
    }

    /// A long slow drag is the finger's own doing: the item it left cropped
    /// comes in, wherever that is.
    @Test func aLongDragIsHonoured() {
        let view = carousel(pages: 8)
        let stride = view.pageViews[1].frame.minX
        let live = stride * 2.5
        let target = release(view, from: 0, at: live, velocity: 0.5, projected: live + 40)
        let cropped = view.pageViews.firstIndex { $0.frame.maxX > live + box } ?? -1

        #expect(abs(target - (view.pageViews[cropped].frame.maxX - box)) < 0.5)
    }

    /// Back is the mirror: the item cropped on the left comes whole to the
    /// left edge.
    @Test func aBackwardSwipeBringsTheCroppedItemWholeToTheLeftEdge() {
        let view = carousel(pages: 5)
        view.setPage(3, animated: false)
        let rest = view.debugContentOffsetX
        let cropped = view.pageViews.lastIndex { $0.frame.minX < rest } ?? -1
        let target = release(view, from: rest, at: rest - 15, velocity: -1.5, projected: 0)

        #expect(cropped == 1)
        #expect(abs(target - view.pageViews[cropped].frame.minX) < 0.5)
    }

    /// A drag let go where it began, with no speed, stays.
    @Test func aDragThatGoesNowhereStaysPut() {
        let view = carousel(pages: 5)
        let target = release(view, from: 0, at: 0, velocity: 0, projected: 0)

        #expect(target == 0)
    }

    // MARK: - The current page

    /// The current page is the first one at the start and the LAST one at the
    /// end — at the end two items are whole, and the run's end must still be
    /// reachable by the dots and by playback.
    @Test func theRunsEndsAreItsFirstAndLastPages() {
        let view = carousel(pages: 6)
        #expect(view.currentPage == 0)

        view.debugScroll(toOffsetX: view.debugAnchors().trailing.max() ?? 0)

        #expect(view.currentPage == 5)
    }

    /// ⚠️ AT EVERY REST THE CURRENT PAGE IS WHOLE — it is the one that plays
    /// and the one a hero flies, and a cropped one would fly half a picture.
    @Test func atEveryRestTheCurrentPageIsWhole() {
        let view = carousel(pages: 6)
        let anchors = view.debugAnchors()
        for offset in anchors.leading + anchors.trailing {
            view.debugScroll(toOffsetX: offset)
            #expect(isWhole(rectInBox(view, page: view.currentPage), in: view),
                    "page \(view.currentPage) cropped at offset \(offset)")
        }
    }

    /// Naming a page already whole moves nothing — a post opened from the
    /// second whole item and closed on it comes home to the strip as it was.
    @Test func namingAWholePageMovesNothing() {
        let view = carousel(pages: 5)
        view.setPage(1, animated: false)

        #expect(view.currentPage == 1)
        #expect(view.debugContentOffsetX == 0)
    }

    /// Naming a cropped one brings it whole in from its side, and no further.
    @Test func namingACroppedPageBringsItWholeToItsEdge() {
        let view = carousel(pages: 5)
        view.setPage(2, animated: false)

        #expect(view.currentPage == 2)
        #expect(abs(rectInBox(view, page: 2).maxX - box) < 0.5)
    }

    // MARK: - Tap and hero

    /// A tap names the item under it: the post opens on THAT one.
    @Test func aTapMakesTheTappedItemCurrent() {
        let view = carousel(pages: 5)
        var openedOn: Int?
        view.onTapped = { [weak view] in openedOn = view?.currentPage }

        view.debugTap(onPage: 1)

        #expect(openedOn == 1)
        #expect(view.debugContentOffsetX == 0)
    }

    /// ⚠️ A cropped item tapped is brought whole BEFORE anyone is told, so the
    /// flight departs from a whole picture inside the box.
    @Test func aTappedCroppedItemIsWholeBeforeThePostOpens() throws {
        let view = carousel(pages: 5)
        var rectAtOpen: CGRect?
        view.onTapped = { [weak view] in
            rectAtOpen = view.flatMap { $0.currentPageRect(in: $0) }
        }

        view.debugTap(onPage: 2)

        let rect = try #require(rectAtOpen)
        #expect(isWhole(rect, in: view))
        #expect(view.currentPage == 2)
    }

    /// The tap's location resolves to the item under it, the gutter counting
    /// for the nearer one.
    @Test func aPointResolvesToTheItemUnderIt() {
        let view = carousel(pages: 5)
        let second = view.pageViews[1].frame

        #expect(view.page(at: CGPoint(x: second.midX, y: 10)) == 1)
        #expect(view.page(at: CGPoint(x: second.minX - 1, y: 10)) == 1)
        #expect(view.page(at: CGPoint(x: 5, y: 10)) == 0)
    }

    /// The row's side of the hero: what opens the post reads the tapped item
    /// as the current page, and the flight's rect is that item's — on the way
    /// out and, after the destination names it again, on the way home.
    @Test func theHeroSourceIsTheTappedItem() throws {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 370, height: 500))
        cell.configure(
            with: GalleryPost(
                id: PostID("p"), kind: .photo, isRepost: false,
                pages: (0..<4).map {
                    GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://t/\($0)"), aspectRatio: 1)
                },
                caption: "Short.", publishedAtMS: 0
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()
        let carousel = try #require(cell.debugCarousel)
        var opened: (page: Int?, rect: CGRect?)?
        cell.onMediaTapped = { [weak cell] in
            opened = (cell?.currentMediaPage, cell?.mediaHeroRect)
        }

        carousel.debugTap(onPage: 1)

        let item = carousel.pageViews[1].convert(carousel.pageViews[1].bounds, to: cell)
        #expect(opened?.page == 1)
        #expect(opened?.rect == item)

        // The destination hands the page back at the close.
        cell.setMediaPage(1, animated: false)
        #expect(cell.mediaHeroRect == item)
    }
}

/// The one-step variant of the rows' rule, without a scroll view.
struct RowEdgeSteppedSnapTests {
    /// Items 100 wide, 10 apart, in a 250 viewport, margin 0.
    private let items: [ClosedRange<CGFloat>] = (0..<6).map {
        CGFloat($0) * 110...(CGFloat($0) * 110 + 100)
    }
    private var offsets: ClosedRange<CGFloat> { 0...(650 - 250) }

    private func snap(live: CGFloat, start: CGFloat, _ direction: RowEdgeSnap.Direction?) -> CGFloat {
        RowEdgeSnap.steppedTarget(
            live: live, start: start, direction: direction,
            items: items, viewport: 250, margin: 0, offsets: offsets
        )
    }

    /// From a rest, a forward flick that barely moved still advances.
    @Test func aShortForwardFlickAdvancesOneItem() {
        // Item 2 (220…320) cropped at the right: its trailing anchor is 70.
        #expect(snap(live: 1, start: 0, .forward) == 70)
    }

    /// Already resting on the anchor it would pick, it moves to the NEXT.
    @Test func fromAnAnchorItMovesToTheNext() {
        #expect(snap(live: 70.2, start: 70, .forward) == 180)
        #expect(snap(live: 179.8, start: 180, .backward) == 110)
    }

    /// The far ends clamp: nothing past the last rest, nothing before the first.
    @Test func theEndsClamp() {
        #expect(snap(live: 399, start: 395, .forward) == 400)
        #expect(snap(live: 2, start: 5, .backward) == 0)
    }

    /// No direction: the nearest rest to where the finger let go.
    @Test func noDirectionTakesTheNearestRest() {
        #expect(snap(live: 100, start: 0, nil) == 110)
    }
}
