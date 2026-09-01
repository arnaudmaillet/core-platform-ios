import CoreModels
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// A carousel keeps only the drags it can spend.
///
/// The reported defect: on the first page of a collection, a rightward drag did
/// NOTHING — the carousel held the gesture, rubber-banded, and the screen's
/// dismissal never heard about it. The rule that fixes it is the one
/// `ProfileDismissalPolicy` already states for tabs, one level in: with nothing
/// to the left the movement is free, so it passes through.
@MainActor
struct CarouselTravelTests {
    private func carousel(pages count: Int) -> MediaCarouselView {
        let view = MediaCarouselView(
            style: .card, frame: CGRect(x: 0, y: 0, width: 358, height: 240)
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

    /// ⚠️ The delta is in PAGES, which run the opposite way to the finger: the
    /// rightward drag that uncovers the previous photograph asks for `-1`.
    @Test func theFirstPageHasNothingBehindItAndEverythingAhead() {
        let view = carousel(pages: 4)

        #expect(view.hasTravel(towardsPageDelta: -1) == false)
        #expect(view.hasTravel(towardsPageDelta: 1))
    }

    @Test func theLastPageHasNothingAheadOfItAndEverythingBehind() {
        let view = carousel(pages: 4)
        view.setPage(3, animated: false)

        #expect(view.currentPage == 3)
        #expect(view.hasTravel(towardsPageDelta: 1) == false)
        #expect(view.hasTravel(towardsPageDelta: -1))
    }

    @Test func aMiddlePageCanTravelBothWays() {
        let view = carousel(pages: 4)
        view.setPage(2, animated: false)

        #expect(view.hasTravel(towardsPageDelta: -1))
        #expect(view.hasTravel(towardsPageDelta: 1))
    }

    /// One page is both ends at once, and a rule that only knew about the first
    /// would hand it the leftward drag it cannot use either.
    @Test func aSinglePageHasNoTravelInEitherDirection() {
        let view = carousel(pages: 1)

        #expect(view.hasTravel(towardsPageDelta: -1) == false)
        #expect(view.hasTravel(towardsPageDelta: 1) == false)
        #expect(view.hasTravel(towardsPageDelta: 0) == false)
    }

    /// Zero is "direction unknown", and answers the older, weaker question.
    @Test func aDirectionlessQuestionAsksWhetherThereIsMoreThanOnePage() {
        #expect(carousel(pages: 4).hasTravel(towardsPageDelta: 0))
    }

    /// ⚠️ ANSWERED THROUGH A RUBBER-BAND, which is why it is resolved from
    /// `currentPage` and not from the raw offset. An overscroll past the start
    /// is a NEGATIVE offset: read literally it is "before page zero", which
    /// reports travel that does not exist on exactly the drag this rule exists
    /// to route.
    @Test func anOverscrollPastTheStartIsStillTheFirstPage() {
        let view = carousel(pages: 4)
        view.debugScroll(toOffsetX: -60)

        #expect(view.currentPage == 0)
        #expect(view.hasTravel(towardsPageDelta: -1) == false)
    }

    /// The gesture rule itself: rightward, predominantly horizontal, nothing to
    /// the left.
    @Test func aRightwardDragOnTheFirstPageIsDeclined() {
        let view = carousel(pages: 4)

        #expect(view.yieldsRightwardDrag(velocity: CGPoint(x: 820, y: 0)))
    }

    @Test func theSameDragIsKeptOnceThereIsAPhotographToGoBackTo() {
        let view = carousel(pages: 4)
        view.setPage(1, animated: false)

        #expect(view.yieldsRightwardDrag(velocity: CGPoint(x: 820, y: 0)) == false)
    }

    /// ⚠️ THE MIRROR IS DELIBERATELY NOT WRITTEN HERE, and this pins the
    /// decision rather than the omission.
    ///
    /// Leftward on the last page can only rubber-band too — but on the surfaces
    /// a carousel lives on there is nobody waiting for it: the dismissal is
    /// armed rightward only (`ZoomDismissAxis.match` requires `velocity.x > 0`)
    /// and the feed is forward-only. A drag given up to nobody is worse than one
    /// that ends against a stop, because the stop is at least an answer. Where
    /// something IS waiting — the tab pager, which has a next tab — that surface
    /// makes the mirror decision itself, in `HorizontalPagerScrollView`.
    @Test func aLeftwardDragOnTheLastPageIsNeverDeclined() {
        let view = carousel(pages: 4)
        view.setPage(3, animated: false)

        #expect(view.hasTravel(towardsPageDelta: 1) == false)
        #expect(view.yieldsRightwardDrag(velocity: CGPoint(x: -820, y: 0)) == false)
    }

    /// ⚠️ PREDOMINANTLY HORIZONTAL, which is the mirror of the dismissal's own
    /// begin gate — so exactly one of the two claims any given drag. Without it
    /// a downward drag with any rightward drift would be refused here as well,
    /// and a diagonal would fall between the two.
    @Test func aPredominantlyVerticalDragIsNotThisRulesToRefuse() {
        let view = carousel(pages: 4)

        #expect(view.yieldsRightwardDrag(velocity: CGPoint(x: 120, y: 900)) == false)
    }
}

/// The walk from a touch down to the carousel under it, shared so a second
/// screen's dismissal gate does not copy the first one's.
@MainActor
struct MediaCarouselTouchRoutingTests {
    /// A host the size of a screen with one carousel laid into it, which is the
    /// shape of every caller: a point in the host's own space, hit-tested down.
    private func screen(pages count: Int) -> (UIView, MediaCarouselView) {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let carousel = MediaCarouselView(
            style: .page, frame: CGRect(x: 0, y: 120, width: 390, height: 390)
        )
        carousel.configure(
            with: (0..<count).map {
                GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://t/\($0)"))
            },
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        host.addSubview(carousel)
        carousel.layoutIfNeeded()
        return (host, carousel)
    }

    private let onTheCarousel = CGPoint(x: 195, y: 300)
    private let belowIt = CGPoint(x: 195, y: 700)

    @Test func theWalkFindsTheCarouselUnderTheTouch() {
        let (host, carousel) = screen(pages: 3)

        #expect(MediaCarouselTouchRouting.carousel(at: onTheCarousel, in: host) === carousel)
    }

    /// A touch that lands on no carousel passes through — the answer for the
    /// whole of a text post, and for the chrome around a gallery.
    @Test func aTouchOnNoCarouselPassesThrough() {
        let (host, _) = screen(pages: 3)

        #expect(MediaCarouselTouchRouting.carousel(at: belowIt, in: host) == nil)
        #expect(MediaCarouselTouchRouting.dragPassesThroughCarousel(
            at: belowIt, in: host, towardsPageDelta: -1
        ))
    }

    @Test func aRightwardDragOnAFirstPageCarouselPassesThrough() {
        let (host, _) = screen(pages: 3)

        #expect(MediaCarouselTouchRouting.dragPassesThroughCarousel(
            at: onTheCarousel, in: host, towardsPageDelta: -1
        ))
    }

    /// Both directions of the answer, or a gate that always permitted would pass
    /// the test above and hand every "previous photo" swipe to the dismissal.
    @Test func aRightwardDragOnACarouselWithAPreviousPageDoesNot() {
        let (host, carousel) = screen(pages: 3)
        carousel.setPage(1, animated: false)

        #expect(MediaCarouselTouchRouting.dragPassesThroughCarousel(
            at: onTheCarousel, in: host, towardsPageDelta: -1
        ) == false)
    }

    /// The delta is honoured rather than assumed: the same touch, on the same
    /// page, answers the other way when the drag is going the other way.
    @Test func theDeltaIsTheCallersToChoose() {
        let (host, carousel) = screen(pages: 3)
        carousel.setPage(2, animated: false)

        #expect(MediaCarouselTouchRouting.dragPassesThroughCarousel(
            at: onTheCarousel, in: host, towardsPageDelta: 1
        ))
        #expect(MediaCarouselTouchRouting.dragPassesThroughCarousel(
            at: onTheCarousel, in: host, towardsPageDelta: -1
        ) == false)
    }
}

/// The row cell's twin of the question, for a host that holds cells rather than
/// carousels.
@MainActor
struct RowMediaTravelTests {
    private func row(pages: [GalleryPost.MediaPage]) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        cell.configure(
            with: GalleryPost(
                id: PostID("p"), kind: .photo, isRepost: false,
                pages: pages, caption: "Short.", publishedAtMS: 0
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()
        return cell
    }

    private func mediaPages(_ count: Int) -> [GalleryPost.MediaPage] {
        (0..<count).map {
            GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://t/\($0)"), aspectRatio: 1.5)
        }
    }

    @Test func theRowAnswersForItsOwnCarousel() {
        let cell = row(pages: mediaPages(3))

        #expect(cell.currentMediaPage == 0)
        #expect(cell.mediaHasTravel(towardsPageDelta: -1) == false)
        #expect(cell.mediaHasTravel(towardsPageDelta: 1))

        cell.debugScrollCarousel(toPage: 1, animated: false)

        #expect(cell.mediaHasTravel(towardsPageDelta: -1))
    }

    /// ⚠️ `false`, not an optional the caller has to invent an answer for. A row
    /// with one photograph has no carousel and no page to reach — and the first
    /// caller to guess `true` here would hand a drag to something that is not
    /// there.
    @Test func aRowWithNoCollectionHasNowhereToTravel() {
        let cell = row(pages: mediaPages(1))

        #expect(cell.currentMediaPage == nil)
        #expect(cell.mediaHasTravel(towardsPageDelta: -1) == false)
        #expect(cell.mediaHasTravel(towardsPageDelta: 1) == false)
    }
}
