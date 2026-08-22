import CoreModels
import MediaCore
import UIKit
import Testing
@testable import PostGrid

// `post.v1.PostView.attachments` has always been a repeated field and
// `PostKind` has always had a `carousel` case beside `main_video`. The client
// collapsed both with `.first`, in four projections. These pin the shape of the
// model that stopped doing that, and the two properties of the card's carousel
// that a screenshot cannot show.

private func page(_ id: String, aspect: Double = 1) -> GalleryPost.MediaPage {
    GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://\(id)"), aspectRatio: aspect)
}

struct GalleryPostCollectionTests {
    /// The single-media initializer still exists and still means one page —
    /// most builders genuinely have one piece.
    @Test func oneAttachmentIsOnePage() {
        let post = GalleryPost(
            id: PostID("p"), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "mock://a"), aspectRatio: 0.8,
            caption: "", publishedAtMS: 0
        )

        #expect(post.pages.count == 1)
        #expect(post.isCollection == false)
        #expect(post.aspectRatio == 0.8)
    }

    /// ⚠️ A text post has NO page, rather than one page of nothing.
    ///
    /// The single-media accessors read `pages.first`, so a synthetic page here
    /// would hand a text post a thumbnail of nil dressed as media it does not
    /// have — and `mediaHeroRect`, autoplay and the carousel all branch on
    /// whether media exists.
    @Test func aTextPostHasNoPages() {
        let post = GalleryPost(
            id: PostID("p"), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: "words", publishedAtMS: 0
        )

        #expect(post.pages.isEmpty)
        #expect(post.isCollection == false)
        #expect(post.thumbnailURL == nil)
    }

    /// The collection keeps the author's order, and the single-media accessors
    /// answer for its HEAD — a mosaic brick, a map pin and a flight's cover all
    /// show one piece of a post, and it is the first.
    @Test func aCollectionKeepsItsOrderAndAnswersForItsHead() {
        let post = GalleryPost(
            id: PostID("p"), kind: .photo, isRepost: false,
            pages: [page("a", aspect: 0.8), page("b", aspect: 1.78), page("c")],
            caption: "", publishedAtMS: 0
        )

        #expect(post.isCollection)
        #expect(post.pages.count == 3)
        #expect(post.aspectRatio == 0.8)
        #expect(post.thumbnailURL == URL(string: "mock://a"))
    }

    /// Two pages is a collection; one is not. The card hangs an indicator, a
    /// scroll view and a peek off this answer.
    @Test func twoPagesIsTheThreshold() {
        func post(_ count: Int) -> GalleryPost {
            GalleryPost(
                id: PostID("p"), kind: .photo, isRepost: false,
                pages: (0..<count).map { page("\($0)") },
                caption: "", publishedAtMS: 0
            )
        }

        #expect(post(1).isCollection == false)
        #expect(post(2).isCollection)
    }
}

@MainActor
struct MediaCarouselGeometryTests {
    private func carousel(pages: Int, width: CGFloat = 348, height: CGFloat = 435)
        -> MediaCarouselView {
        let view = MediaCarouselView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.configure(
            with: (0..<pages).map { page("\($0)") },
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        view.layoutIfNeeded()
        return view
    }

    /// The peek IS the affordance: a page is narrower than the box, so the next
    /// one is always partly on screen. Without it nothing on the card says there
    /// is more than one photograph.
    @Test func aPageIsNarrowerThanTheBoxByThePeek() throws {
        let view = carousel(pages: 3)
        let first = try #require(view.currentPageRect(in: view))

        #expect(abs(first.width - (view.bounds.width - MediaCarouselView.peek)) < 0.5)
        #expect(abs(first.minX) < 0.5)
    }

    /// ⚠️ The LAST page lands flush against the trailing edge, which is why the
    /// content is not `pages × stride`.
    ///
    /// Sized the naive way, the scroll ends with a strip of empty box after the
    /// final photograph — a peek of nothing, which reads as a broken layout
    /// rather than as an end. At the last page it is the PREVIOUS one that
    /// peeks, on the left.
    @Test func theLastPageLandsFlush() throws {
        let view = carousel(pages: 4)
        view.debugScroll(toPage: 3, animated: false)
        view.layoutIfNeeded()
        let last = try #require(view.currentPageRect(in: view))

        #expect(abs(last.maxX - view.bounds.width) < 0.5)
        #expect(view.currentPage == 3)
    }

    /// ⚠️ The sliver is a VERTICAL CAPSULE, and the arithmetic that makes it one
    /// is the reason `neighbourWidth` is derived rather than picked.
    ///
    /// Its left corners come from the page (radius `mediaCornerRadius`); its
    /// right corners come from the BOX clipping it, at the same radius. A strip
    /// of exactly `2 × radius` therefore has no straight edge anywhere — four
    /// quarter-circles meeting — which is a capsule. One point off in either
    /// direction and it is a slab with soft corners.
    @Test func theNeighbourShowsAsAVerticalCapsule() throws {
        let view = carousel(pages: 3)
        let first = try #require(view.currentPageRect(in: view))
        let neighbourLeadingEdge = first.maxX + MediaCarouselView.gap
        let visible = view.bounds.width - neighbourLeadingEdge

        #expect(abs(visible - MediaCarouselView.neighbourWidth) < 0.5)
        #expect(abs(visible - PostGridListRowCell.mediaCornerRadius * 2) < 0.5)
    }

    /// ⚠️ The gutter falls INSIDE the peek, and getting that backwards is what
    /// the first version did: with `peek` measured to the page's own edge, the
    /// gap ate into the sliver and what showed was `peek - gap`.
    @Test func thePeekCarriesTheGutterAsWellAsTheSliver() {
        #expect(MediaCarouselView.peek
            == MediaCarouselView.neighbourWidth + MediaCarouselView.gap)
    }

    /// Asking for a page that is not there is false, not a silent no-op — the
    /// answer a harness must not mistake for success.
    @Test func thereIsNoPageBeyondTheLast() {
        let view = carousel(pages: 2)

        #expect(view.debugScroll(toPage: 1, animated: false))
        #expect(view.debugScroll(toPage: 2, animated: false) == false)
    }

    /// A hero flight departs with the page the viewer is LOOKING at, not the
    /// post's first attachment.
    @Test func theCoverFollowsTheCurrentPage() {
        let view = carousel(pages: 3)
        #expect(view.currentPage == 0)

        view.debugScroll(toPage: 2, animated: false)

        #expect(view.currentPage == 2)
    }
}

/// CONCEAL EXACTLY WHAT THE FLIGHT REPRODUCES, read one level in.
///
/// A flight from a collection carries the current PAGE — its rect and its image
/// — so the page is what disappears while the flight is out. Concealing the
/// preview instead took the neighbour's peek and the chips with it, and the
/// whole strip returned in one frame at the landing: the pop the rule exists to
/// prevent, rebuilt inside the preview the rule was written for.
@MainActor
struct CarouselConcealmentTests {
    private func carousel(pages: Int) -> MediaCarouselView {
        let view = MediaCarouselView(frame: CGRect(x: 0, y: 0, width: 348, height: 435))
        view.configure(
            with: (0..<pages).map { page("\($0)") },
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        view.layoutIfNeeded()
        return view
    }

    private func pageAlphas(_ view: MediaCarouselView) -> [CGFloat] {
        func images(_ node: UIView) -> [UIImageView] {
            if let image = node as? UIImageView { return [image] }
            return node.subviews.flatMap(images)
        }
        return images(view).map(\.alpha)
    }

    @Test func onlyTheFlownPageIsConcealed() {
        let view = carousel(pages: 4)
        view.setPage(1, animated: false)

        view.setCurrentPageConcealed(true)

        #expect(pageAlphas(view) == [1, 0, 1, 1])
    }

    /// The carousel itself stays visible, which is what keeps the peek and the
    /// chips on screen for the length of the flight.
    @Test func theCarouselItselfStaysVisible() {
        let view = carousel(pages: 3)
        view.setCurrentPageConcealed(true)

        #expect(view.alpha == 1)
        #expect(view.isHidden == false)
    }

    /// ⚠️ The concealed page is identified by INDEX, so a page change while a
    /// flight is out has to move the hole with it — otherwise the wrong page
    /// stays invisible and the right one is on screen twice.
    @Test func theHoleFollowsThePage() {
        let view = carousel(pages: 4)
        view.setCurrentPageConcealed(true)
        #expect(pageAlphas(view) == [0, 1, 1, 1])

        view.setPage(2, animated: false)

        #expect(pageAlphas(view) == [1, 1, 0, 1])
    }

    /// And the rect is still answerable while concealed — it is what the
    /// dismissal flies home to, which is why this is alpha and not `isHidden`.
    @Test func aConcealedPageStillReportsItsRect() throws {
        let view = carousel(pages: 3)
        let resting = try #require(view.currentPageRect(in: view))

        view.setCurrentPageConcealed(true)

        #expect(view.currentPageRect(in: view) == resting)
    }

    @Test func unconcealingRestoresEveryPage() {
        let view = carousel(pages: 3)
        view.setCurrentPageConcealed(true)
        view.setCurrentPageConcealed(false)

        #expect(pageAlphas(view) == [1, 1, 1])
    }
}

@MainActor
struct CarouselChipsAreFixedTests {
    private func row(pages: Int, width: CGFloat = 390) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 500))
        cell.configure(
            with: GalleryPost(
                id: PostID("p"), kind: .photo, isRepost: false,
                pages: (0..<pages).map { page("\($0)", aspect: 0.8) },
                caption: "Short.", publishedAtMS: 0, reactionCount: 160
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()
        return cell
    }

    private func chipFrames(in cell: PostGridListRowCell) -> [CGRect] {
        func pills(_ view: UIView) -> [PostMetaPillView] {
            if let pill = view as? PostMetaPillView { return [pill] }
            return view.subviews.flatMap(pills)
        }
        return pills(cell.contentView)
            .filter { !$0.isHidden }
            .map { $0.convert($0.bounds, to: cell.contentView) }
            .sorted { $0.minX < $1.minX }
    }

    /// ⚠️ THE REQUIREMENT: the chips and the indicator belong to the PREVIEW,
    /// not to what is inside it, so scrolling the pages must not move them.
    ///
    /// The natural way to write a carousel is to put its furniture in the scroll
    /// view — everything is then one subtree and nothing needs pinning — and it
    /// carries the counters off the screen with page two. Here the scroll view
    /// is a sibling BELOW them inside the box, and this measures the difference.
    @Test func theChipsDoNotTravelWithThePages() {
        let cell = row(pages: 4)
        let before = chipFrames(in: cell)
        #expect(before.count == 3)

        #expect(cell.debugScrollCarousel(toPage: 3, animated: false))
        cell.layoutIfNeeded()

        let after = chipFrames(in: cell)
        #expect(after.count == before.count)
        for (old, new) in zip(before, after) {
            #expect(abs(old.minX - new.minX) < 0.5)
            #expect(abs(old.minY - new.minY) < 0.5)
        }
    }

    /// Three chips for a collection — counters, indicator, age — and two for a
    /// single-media post. An indicator for one page is furniture answering a
    /// question nobody asked.
    @Test func onlyACollectionWearsAnIndicator() {
        #expect(chipFrames(in: row(pages: 1)).count == 2)
        #expect(chipFrames(in: row(pages: 4)).count == 3)
    }

    /// It sits BETWEEN the other two, which is the placement asked for and the
    /// one a centred-on-the-leftover-space version would break the moment a
    /// counter gained a digit.
    ///
    /// ⚠️ On one line of CENTRES, not one bottom edge. The three chips are
    /// different heights — a row of 6pt dots against a line of caption2 — so a
    /// shared bottom puts the short one's mass below the others, and the row
    /// stops reading as a row.
    @Test func theIndicatorSitsBetweenTheCounterAndTheDate() throws {
        let cell = row(pages: 4)
        let frames = chipFrames(in: cell)
        #expect(frames.count == 3)

        #expect(frames[0].maxX <= frames[1].minX)
        #expect(frames[1].maxX <= frames[2].minX)
        for frame in frames {
            #expect(abs(frame.midY - frames[0].midY) < 0.5)
        }
        // And it really is shorter, so the assertion above is not the same as a
        // bottom-edge one by accident.
        #expect(frames[1].height < frames[2].height)
    }

    /// The indicator is a CONTROL: a tap or a drag across it asks for a page.
    ///
    /// Truncation into equal bands, not rounding. Rounding makes the first and
    /// last bands half-width, so the two pages people reach for most — the ends
    /// — become the hardest to hit.
    @Test func theIndicatorTurnsATouchIntoAPage() {
        let width: CGFloat = 100
        func page(_ x: CGFloat) -> Int {
            MediaPageIndicatorView.page(at: x, width: width, count: 4)
        }

        #expect(page(0) == 0)
        #expect(page(width) == 3)
        // Four equal bands across the padded strip: the ends are as wide as the
        // middles.
        #expect(page(width * 0.2) == 0)
        #expect(page(width * 0.45) == 1)
        #expect(page(width * 0.95) == 3)
        // Outside the chip is clamped, never a crash and never a wrap.
        #expect(page(-40) == 0)
        #expect(page(width + 40) == 3)
    }

    /// A single-page post has no page to ask for.
    @Test func theIndicatorAsksForNothingWhenThereIsOnePage() {
        #expect(MediaPageIndicatorView.page(at: 80, width: 100, count: 1) == 0)
    }

    /// A row recycled from a collection to a single-media post must not keep the
    /// previous post's pages or its indicator — the carousel is built once and
    /// then reused, so nothing on the configure path for a one-piece post would
    /// have cleared it.
    @Test func aRecycledRowDropsThePreviousCollection() {
        let cell = row(pages: 4)
        #expect(chipFrames(in: cell).count == 3)

        cell.prepareForReuse()
        cell.configure(
            with: GalleryPost(
                id: PostID("q"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "mock://solo"), aspectRatio: 0.8,
                caption: "Short.", publishedAtMS: 0, reactionCount: 12
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        cell.layoutIfNeeded()

        #expect(chipFrames(in: cell).count == 2)
        #expect(cell.debugScrollCarousel(toPage: 1, animated: false) == false)
    }
}
