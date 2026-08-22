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

    /// ⚠️ The PAGES' alphas, which is not the same as every image view's.
    ///
    /// This collected `UIImageView`s and was right while a page WAS one. A page
    /// is now a container — a cover, and a play badge for a page that carries a
    /// clip — so the walk returned two views per page, and concealment does not
    /// touch either of them: it dims the page, and the layers inside inherit it.
    ///
    /// Read off the carousel's own page list. The scroll view's subviews are
    /// NOT it — UIKit keeps its two scroll indicators there, permanently at
    /// alpha 0, which read as two extra concealed pages.
    private func pageAlphas(_ view: MediaCarouselView) -> [CGFloat] {
        view.pageViews.map(\.alpha)
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

/// A collection's pages need not agree about their type: `post.v1` gives every
/// attachment its own MIME, and the client hydrates `MediaPage.videoURL` one
/// page at a time. These pin the consequences — the parts that answer for the
/// PAGE where something used to answer for the post.
@MainActor
struct MixedCarouselTests {
    private func mixed() -> MediaCarouselView {
        let view = MediaCarouselView(style: .card)
        view.frame = CGRect(x: 0, y: 0, width: 340, height: 200)
        view.configure(
            with: [
                GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://a"), aspectRatio: 1.78),
                GalleryPost.MediaPage(
                    thumbnailURL: URL(string: "mock://b"),
                    videoURL: URL(string: "mock://video/b"), aspectRatio: 1.78
                ),
                GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://c"), aspectRatio: 1.78)
            ],
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        view.layoutIfNeeded()
        return view
    }

    /// ⚠️ THE REQUIREMENT: the stream follows the page.
    ///
    /// `GalleryPost.videoURL` answers for page one for ever, so a caller that
    /// used it on a mixed collection would play page one's clip — or nothing at
    /// all, which is what happened: a post whose first page is a photograph is a
    /// `.photo` post, and the autoplay gate refused it outright.
    @Test func theStreamIsTheCurrentPagesAndNotThePosts() {
        let view = mixed()
        #expect(view.currentPageVideoURL == nil)

        view.setPage(1, animated: false)
        #expect(view.currentPageVideoURL == URL(string: "mock://video/b"))

        view.setPage(2, animated: false)
        #expect(view.currentPageVideoURL == nil)
    }

    /// The badge is per page too, and it is the only thing that says a page in
    /// the middle of a run of photographs is a clip — the row's own badge sits
    /// over the whole preview and has no single answer to give.
    @Test func onlyAPlayablePageWearsABadge() {
        let view = mixed()

        #expect(view.pageViews.map(\.isPlayable) == [false, true, false])
        // And the badge really follows that flag rather than merely agreeing
        // with it today: a still page draws its cover and nothing else, a
        // playable one draws the mark as well.
        let drawn = view.pageViews.map { page in
            page.subviews.filter { !$0.isHidden }.count
        }
        #expect(drawn == [1, 2, 1])
    }

    /// ⚠️ The badge's fate under playback is decided by the SURFACE, not by the
    /// page — and the two surfaces disagree on purpose.
    ///
    /// On a card the badge is what tells a clip apart from the photographs
    /// either side of it while the viewer scrolls past. Full-bleed there is
    /// nothing to tell it apart from, and a single-video post shows no badge on
    /// that screen at all — keeping one would make two posts of the same kind
    /// disagree on the same page.
    @Test func aPlayingPageKeepsItsBadgeOnACardAndLosesItOnAPage() {
        for style in [MediaCarouselView.Style.card, .page] {
            let view = MediaCarouselView(style: style)
            view.frame = CGRect(x: 0, y: 0, width: 340, height: 200)
            view.configure(
                with: [GalleryPost.MediaPage(
                    thumbnailURL: URL(string: "mock://a"),
                    videoURL: URL(string: "mock://video/a")
                )],
                imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
            )
            view.layoutIfNeeded()
            let page = view.pageViews[0]
            let restingBadges = page.subviews.filter { !$0.isHidden }.count

            view.host(UIView())
            let playingBadges = page.subviews.filter { !$0.isHidden }.count

            #expect(restingBadges == 2)
            // Card: cover, surface, badge. Page: cover and surface only.
            #expect(playingBadges == (style == .card ? 3 : 2))
        }
    }

    /// ⚠️ A SURFACE TAKEN AWAY BEHIND THE CAROUSEL'S BACK CAN COME HOME.
    ///
    /// A hero flight takes the render view by `removeFromSuperview` — it never
    /// asks the carousel, and it cannot: the flight is driven from the surface's
    /// own side. The page's reference is weak and the flight card retains the
    /// view, so the page went on believing it held one, and re-hosting the same
    /// object at the landing was skipped as redundant. The surface came back to
    /// nowhere, the page showed its cover, and the NEXT flight flew a thumbnail.
    ///
    /// Reproduced here the way it happens: no eviction, just a removal.
    @Test func aSurfaceTakenByAFlightIsRehostedOnItsReturn() {
        let view = mixed()
        view.setPage(1, animated: false)
        let surface = UIView()
        view.host(surface)
        let hostedFirst = surface.superview === view.pageViews[1]
        #expect(hostedFirst)

        // What a flight does, and all it does.
        surface.removeFromSuperview()

        view.host(surface)
        let hostedAgain = surface.superview === view.pageViews[1]
        #expect(hostedAgain)
    }

    /// A surface handed to the carousel lands on the page being looked at, and
    /// paging away takes it off again.
    ///
    /// ⚠️ The eviction searches every page rather than trusting `currentPage`:
    /// the page changes BEFORE the host is told, so by the time anyone reacts
    /// the surface is sitting on the page the viewer just left — still on
    /// screen, peeking, playing a video beside the still they moved to.
    @Test func theHostedSurfaceMovesWithTheViewer() {
        let view = mixed()
        let surface = UIView()
        view.setPage(1, animated: false)
        view.host(surface)

        let host = surface.superview
        #expect(host === view.pageViews[1])

        view.setPage(2, animated: false)
        let evicted = view.evictHostedSurface()
        #expect(evicted === surface)
        let orphaned = surface.superview == nil
        #expect(orphaned)
    }
}

/// The row's playback surface, across page changes.
@MainActor
struct RowSurfaceReinstallTests {
    private func row() -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        cell.configure(
            with: GalleryPost(
                id: PostID("p"), kind: .photo, isRepost: false,
                pages: [
                    GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://a"), aspectRatio: 1.5),
                    GalleryPost.MediaPage(
                        thumbnailURL: URL(string: "mock://b"),
                        videoURL: URL(string: "mock://video/b"), aspectRatio: 1.5
                    )
                ],
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

    /// ⚠️ PAGING AWAY DOES NOT PUT THE THUMBNAIL BACK.
    ///
    /// The surface used to be evicted on every page change, which released the
    /// page's cover to show through — so a clip appeared to be REPLACED by a
    /// photograph the moment the viewer moved to the next page, while it was
    /// merely no longer the one being watched. In a carousel that page is still
    /// on screen, peeking. It keeps its last frame instead, paused in place.
    ///
    /// The row also keeps ANSWERING for that clip (`retainedVideoURL`): a row
    /// that answered only for its current page would drop out of the pool's
    /// ranking, and the player would go with the slot.
    @Test func pagingAwayLeavesTheClipsFrameOnItsPage() {
        let cell = row()
        cell.debugScrollCarousel(toPage: 1, animated: false)
        let surface = cell.makeVideoRenderViewIfNeeded()
        let host = surface.superview
        let installed = host != nil
        #expect(installed)

        cell.debugScrollCarousel(toPage: 0, animated: false)

        let stillHosted = surface.superview === host
        #expect(stillHosted)
        // Not advancing — the viewer is on a still…
        #expect(cell.currentPageVideoURL == nil)
        // …and still held, which is what keeps the player.
        #expect(cell.retainedVideoURL == URL(string: "mock://video/b"))
    }

    /// And it MOVES when the viewer reaches a different clip: the page it came
    /// from must not be left believing it still holds a surface, which is enough
    /// to keep that page's badge hidden for good.
    @Test func arrivingAtAnotherClipMovesTheSurface() {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        cell.configure(
            with: GalleryPost(
                id: PostID("p"), kind: .photo, isRepost: false,
                pages: [
                    GalleryPost.MediaPage(
                        thumbnailURL: URL(string: "mock://a"),
                        videoURL: URL(string: "mock://video/a"), aspectRatio: 1.5
                    ),
                    GalleryPost.MediaPage(
                        thumbnailURL: URL(string: "mock://b"),
                        videoURL: URL(string: "mock://video/b"), aspectRatio: 1.5
                    )
                ],
                caption: "Short.", publishedAtMS: 0
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()

        let surface = cell.makeVideoRenderViewIfNeeded()
        let firstHost = surface.superview

        cell.debugScrollCarousel(toPage: 1, animated: false)
        _ = cell.makeVideoRenderViewIfNeeded()

        let moved = surface.superview !== firstHost
        let hosted = surface.superview != nil
        #expect(moved)
        #expect(hosted)
        #expect(cell.retainedVideoURL == URL(string: "mock://video/b"))
    }

    /// ⚠️ THE ROUND TRIP: hosted, donated to a flight, adopted back.
    ///
    /// This is the sequence the viewer reported — "after several hero
    /// animations the player disappears and I get the thumbnail, and the next
    /// flight uses the thumbnail as its window; doing it again works". Each
    /// step alone was correct; the pair left a page believing it still held a
    /// surface that had been carried off, and a page that believes that refuses
    /// to take it back.
    ///
    /// The second attempt worked because the following page change evicted the
    /// stale reference — which is exactly why this has to be tested as a
    /// SEQUENCE rather than as three calls.
    @Test func aDonatedSurfaceIsHostedAgainWhenTheFlightLands() {
        let cell = row()
        cell.debugScrollCarousel(toPage: 1, animated: false)
        let surface = cell.makeVideoRenderViewIfNeeded()
        let page = surface.superview
        let hosted = page != nil
        #expect(hosted)

        let donated = cell.donateVideoRenderView()
        let gone = donated === surface && surface.superview == nil
        #expect(gone)

        cell.adoptVideoRenderView(surface)

        let home = surface.superview === page
        #expect(home)
        // And the row is holding it again, so the pool keeps its slot.
        #expect(cell.retainedVideoURL == URL(string: "mock://video/b"))
    }

    /// ⚠️ THE FLIGHT MUST NOT CARRY A CLIP THE VIEWER HAS PAGED PAST.
    ///
    /// This is the defect the recording showed: the card was on a photograph,
    /// the hero animation opened on the VIDEO, and the post arrived on the
    /// photograph — a window showing something that was nowhere on screen.
    ///
    /// It followed directly from keeping the player alive across a page change.
    /// "This row is playing" stopped meaning "this row's picture is moving", and
    /// the flight asked the first question while needing the second. So the cell
    /// answers the second one now, and the coordinator asks it before donating.
    ///
    /// Both directions are asserted. A guard that answered "no" always would
    /// pass a one-sided version of this test and quietly kill live flights.
    @Test func aPausedClipOnAnotherPageIsNotTheCurrentMedia() {
        let cell = row()
        cell.debugScrollCarousel(toPage: 1, animated: false)
        _ = cell.makeVideoRenderViewIfNeeded()
        #expect(cell.isRenderingCurrentMedia)

        cell.debugScrollCarousel(toPage: 0, animated: false)

        // Still holding the player — the frame stays on its page…
        #expect(cell.retainedVideoURL == URL(string: "mock://video/b"))
        // …and still NOT what the viewer is looking at.
        #expect(cell.isRenderingCurrentMedia == false)

        cell.debugScrollCarousel(toPage: 1, animated: false)
        _ = cell.makeVideoRenderViewIfNeeded()
        #expect(cell.isRenderingCurrentMedia)
    }

    /// A row with no surface at all is not rendering anything, whatever its
    /// pages say — the case a flight from a still row hits on every tap.
    @Test func aRowWithNoSurfaceIsNotRenderingCurrentMedia() {
        let cell = row()
        cell.debugScrollCarousel(toPage: 1, animated: false)

        #expect(cell.isRenderingCurrentMedia == false)
    }

    /// And a row with a single attachment is NOT re-parented on every ask:
    /// `pin(to:)` discards the concrete frame until the next layout pass, which
    /// resets `AVPlayerLayer.isReadyForDisplay` for ~170ms — measured, and the
    /// reason the landing path installs by frame.
    @Test func aSingleAttachmentSurfaceIsInstalledOnce() {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        cell.configure(
            with: GalleryPost(
                id: PostID("q"), kind: .video, isRepost: false,
                thumbnailURL: URL(string: "mock://solo"), aspectRatio: 1.5,
                caption: "Short.", publishedAtMS: 0
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        cell.layoutIfNeeded()

        let first = cell.makeVideoRenderViewIfNeeded()
        let host = first.superview
        let constraints = host?.constraints.count ?? 0
        _ = cell.makeVideoRenderViewIfNeeded()

        let stillThere = first.superview === host
        #expect(stillThere)
        #expect((host?.constraints.count ?? 0) == constraints)
    }
}

@MainActor
struct CarouselChipsAreFixedTests {
    private func row(
        pages: Int, width: CGFloat = 390,
        reactions: Int64 = 160, comments: Int64 = 12, publishedAtMS: Int64 = 0
    ) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 500))
        cell.configure(
            with: GalleryPost(
                id: PostID("p"), kind: .photo, isRepost: false,
                pages: (0..<pages).map { page("\($0)", aspect: 0.8) },
                // LIKES and COMMENTS: one chip each on the preview, and a
                // number the post does not have draws no chip at all.
                caption: "Short.", publishedAtMS: publishedAtMS,
                reactionCount: reactions, commentCount: comments
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
        func pills(_ view: UIView) -> [UIView] {
            if isChip(view) { return [view] }
            return view.subviews.flatMap(pills)
        }
        // ⚠️ ON SCREEN, which is a question about a chip's ANCESTORS and not
        // about the chip.
        //
        // This filtered on the pill's own `isHidden` and was right for exactly
        // as long as a media row was the only row with pills in it. A card now
        // builds BOTH shapes and hides one — the closing line by hiding its
        // stack, the preview's chips by hiding the preview — so a chip of the
        // shape that is not being drawn still answers `isHidden == false`, and
        // every count here silently gained two.
        func isOnScreen(_ view: UIView) -> Bool {
            sequence(first: view, next: \.superview)
                .prefix { $0 !== cell.contentView.superview }
                .allSatisfy { !$0.isHidden && $0.alpha > 0 }
        }
        return pills(cell.contentView)
            .filter(isOnScreen)
            .map { $0.convert($0.bounds, to: cell.contentView) }
            .sorted { $0.minX < $1.minX }
    }

    /// ⚠️ A CHIP IS A BOX ON THE ROW, not a capsule.
    ///
    /// Three of the four wear one; the date lost its capsule and kept the box,
    /// so a check for `PostMetaPillView` alone silently stopped counting it —
    /// and the tests that read `frames[3]` crashed rather than failed, which is
    /// the loudest possible version of a good outcome.
    private func isChip(_ view: UIView) -> Bool {
        view is PostMetaPillView || view is PostChipSlotView
    }

    /// The chips actually being drawn, in reading order — same rule as
    /// `chipFrames`, for the tests that need the views and not their frames.
    private func onScreenPills(in cell: PostGridListRowCell) -> [UIView] {
        func pills(_ view: UIView) -> [UIView] {
            if isChip(view) { return [view] }
            return view.subviews.flatMap(pills)
        }
        func isOnScreen(_ view: UIView) -> Bool {
            sequence(first: view, next: \.superview)
                .prefix { $0 !== cell.contentView.superview }
                .allSatisfy { !$0.isHidden && $0.alpha > 0 }
        }
        return pills(cell.contentView).filter(isOnScreen).sorted {
            $0.convert($0.bounds, to: cell).minX < $1.convert($1.bounds, to: cell).minX
        }
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
        // likes, comments, indicator, age.
        #expect(before.count == 4)

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
        // Likes, comments, age — and a fourth only when there are pages to
        // indicate.
        #expect(chipFrames(in: row(pages: 1)).count == 3)
        #expect(chipFrames(in: row(pages: 4)).count == 4)
    }

    /// It sits BETWEEN the other two, which is the placement asked for and the
    /// one a centred-on-the-leftover-space version would break the moment a
    /// counter gained a digit.
    ///
    /// ⚠️ On one line of CENTRES, not one bottom edge. The three chips are
    /// different heights — a row of 6pt dots against a line of caption2 — so a
    /// shared bottom puts the short one's mass below the others, and the row
    /// stops reading as a row.
    @Test func theIndicatorSitsBetweenTheCountersAndTheDate() throws {
        let cell = row(pages: 4)
        let frames = chipFrames(in: cell)
        // likes, comments, indicator, age.
        #expect(frames.count == 4)

        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(left.maxX <= right.minX)
            #expect(abs(left.midY - right.midY) < 0.5)
        }
        // ⚠️ And every chip is the SAME HEIGHT. A row of 6pt dots is shorter
        // than a line of caption2, so an indicator sized by its contents came
        // out visibly smaller than the three beside it — which is what stopped
        // the four reading as one row.
        for frame in frames {
            #expect(abs(frame.height - frames[0].height) < 0.5)
        }
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
        #expect(chipFrames(in: cell).count == 4)

        cell.prepareForReuse()
        cell.configure(
            with: GalleryPost(
                id: PostID("q"), kind: .photo, isRepost: false,
                thumbnailURL: URL(string: "mock://solo"), aspectRatio: 0.8,
                caption: "Short.", publishedAtMS: 0, reactionCount: 12, commentCount: 3
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        cell.layoutIfNeeded()

        #expect(chipFrames(in: cell).count == 3)
        #expect(cell.debugScrollCarousel(toPage: 1, animated: false) == false)
    }

    /// A row whose chips have room to move, so a layout that mispositions them
    /// shows up as a measurement rather than as a coincidence.
    ///
    /// ⚠️ Three fixture choices, each load-bearing:
    ///
    /// - **Six-figure counts.** Whether the counters get squeezed depends on how
    ///   wide they are; "160" and "12" fit inside almost anything.
    /// - **A RECENT date**, so the age chip is "1h" rather than "Jan 1 1970" —
    ///   a 123pt date chip filled the row on its own and clamped every gap to
    ///   the minimum, which made the two spaces trivially equal and the whole
    ///   assertion vacuous. It passed under the broken layout.
    /// - **Ninety minutes**, not sixty: an hour on the nose sits on the boundary
    ///   the formatter rounds at.
    private func spaciousRow() -> PostGridListRowCell {
        let ninetyMinutesAgo = Int64(Date().timeIntervalSince1970 * 1000) - 90 * 60 * 1000
        return row(
            pages: 6, reactions: 1_600_000, comments: 128_000,
            publishedAtMS: ninetyMinutesAgo
        )
    }

    /// ⚠️ A COUNT IS NEVER CLIPPED TO MAKE ROOM FOR THE INDICATOR.
    ///
    /// The regression this pins: the indicator was centred on the PREVIEW, which
    /// fixes its leading edge at half the width and caps what is left for the
    /// counters — so the comments chip rendered "💬 …" while empty preview sat
    /// on the other side of the dots. Clipped, it reads as a number the post
    /// has, and it is not one.
    ///
    /// Measuring each chip against what it asks for UNCONSTRAINED is the part
    /// that matters: a frame-order or gap assertion passes just as happily on a
    /// row of ellipses.
    @Test func theCountersAreNeverSqueezedByTheIndicator() {
        let cell = spaciousRow()
        let ordered = onScreenPills(in: cell)
        #expect(ordered.count == 4)

        // Likes, comments and the date at their unconstrained width. The
        // indicator is excluded on purpose — yielding is its job.
        for chip in [ordered[0], ordered[1], ordered[3]] {
            let wanted = chip.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
            #expect(chip.bounds.width >= wanted - 0.5)
        }
    }

    /// And the indicator sits centred BETWEEN the two groups rather than on the
    /// preview: the two dynamic spaces are equal, whatever the counters took.
    @Test func theIndicatorFloatsBetweenTheGroups() {
        let chips = chipFrames(in: spaciousRow())
        #expect(chips.count == 4)

        let leading = chips[2].minX - chips[1].maxX
        let trailing = chips[3].minX - chips[2].maxX
        #expect(abs(leading - trailing) < 0.5)
        // And there is genuine slack here, so the equality above is a measured
        // result and not two gaps clamped at the same minimum.
        #expect(leading > PostGridListRowCell.chipGap + 1)
        #expect(leading >= PostGridListRowCell.chipGap - 0.5)
    }
}
