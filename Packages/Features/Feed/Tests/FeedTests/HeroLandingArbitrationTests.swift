import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// Who takes a close after the viewer has paged DEEP into the feed.
///
/// ## The defect
///
/// For You → Discover → tap a tile → swipe through ~25 posts → dismiss: the
/// hero never flew. The feed slid off to the right instead, grab and chevron
/// alike.
///
/// Two drivers share that screen — the flight and the card-shaped slide — and
/// each must refuse exactly the drags the other takes. The slide's refusal was
/// a RESTATEMENT of the hero's gate that asked `heroAppearance` for the post
/// the viewer ended on: a realized-cell question. A mosaic's hero accepts any
/// landing (it adopts the settled post into the departure slot), but a tile
/// that far past the tapped one has no cell, so the restatement answered "the
/// hero cannot land" and the slide claimed the close.
///
/// These assert on the closure the slide is actually handed
/// (`ForYouViewController.heroLandingArbiter`), not on the hero's gate through
/// it, and each case fixes its precondition — the landing's tile really is
/// unrealized — so a pass cannot come from a grid that happened to be short.
///
/// ⚠️ EVERY CASE HOLDS ITS SOURCE ALIVE. The arbiter captures the source
/// WEAKLY (in the app the flight's controller owns it), and a released source
/// answers "no opinion" — true. Handed an inline temporary, the two `true`
/// cases passed for that reason alone and the `false` one failed: measured on
/// the first run of this suite.
@MainActor
struct HeroLandingArbitrationTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// Kinds cycle photo → video → text, so an index names its kind.
    private func corpus(_ count: Int) -> [GalleryPost] {
        (0..<count).map { index in
            let kind: GalleryPost.Kind = switch index % 3 {
            case 0: .photo
            case 1: .video
            default: .text
            }
            return GalleryPost(
                id: PostID("p\(index)"),
                kind: kind,
                isRepost: false,
                thumbnailURL: kind == .text ? nil : URL(string: "https://example.test/\(index).jpg"),
                aspectRatio: 1,
                caption: "caption \(index)",
                publishedAtMS: 0
            )
        }
    }

    private func page(style: ForYouGridPage.Style, count: Int = 60) -> ForYouGridPage {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: style
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.render(.content(corpus(count)))
        page.layoutIfNeeded()
        return page
    }

    private func source(
        on page: ForYouGridPage, tapped: PostID, landed: PostID
    ) -> ForYouGridZoomSource {
        ForYouGridZoomSource(
            page: page, tappedID: tapped, activePostID: { landed },
            landedModel: { id in page.post(for: id) }, depthView: nil
        )
    }

    // MARK: - The mosaic: the hero takes every media close, however deep

    /// The reported route: a photograph far past the realized window. The
    /// slide must stand aside, or it claims the grab and the chevron's pop is
    /// never forwarded to the flight.
    @Test func aMosaicLeavesADeepMediaCloseToTheHero() {
        let page = page(style: .grid)
        let tapped = page.posts[0].id
        let landed = page.posts[57].id
        #expect(page.post(for: landed)?.kind == .photo, "precondition: a photograph")
        #expect(page.heroAppearance(for: landed) == nil,
                "precondition: the landing's tile is NOT realized — the deep case")

        let source = source(on: page, tapped: tapped, landed: landed)
        let heroTakesIt = ForYouViewController.heroLandingArbiter(asking: source)

        withExtendedLifetime(source) {
            #expect(heroTakesIt(), "the slide claimed a deep close the hero accepts")
        }
    }

    /// The shallow case, which always worked, must keep working — a realized
    /// neighbour of the tapped tile.
    @Test func aMosaicLeavesAShallowMediaCloseToTheHero() {
        let page = page(style: .grid)
        let tapped = page.posts[0].id
        let landed = page.posts[3].id
        #expect(page.heroAppearance(for: landed) != nil, "precondition: realized")

        let source = source(on: page, tapped: tapped, landed: landed)
        let heroTakesIt = ForYouViewController.heroLandingArbiter(asking: source)

        withExtendedLifetime(source) { #expect(heroTakesIt()) }
    }

    // MARK: - The list: the landing is the departure row, whatever was paged to

    /// A list keeps its order, so the close lands on the row the viewer left
    /// from. A MEDIA departure receives the hero even when the settled post's
    /// own row is long gone — depth must not change the answer here either.
    @Test func aListWithAMediaDepartureLeavesADeepCloseToTheHero() {
        let page = page(style: .list)
        let tapped = page.posts[0].id
        let landed = page.posts[57].id
        #expect(page.heroAppearance(for: landed) == nil,
                "precondition: the settled post's row is NOT realized")

        let source = source(on: page, tapped: tapped, landed: landed)
        let heroTakesIt = ForYouViewController.heroLandingArbiter(asking: source)

        withExtendedLifetime(source) { #expect(heroTakesIt()) }
    }

    /// The half that must keep REFUSING: a list opened on a TEXT row lands on
    /// words, and a hero carrying a photograph onto them is a card dissolving
    /// over an empty rectangle. The slide takes it.
    @Test func aListWithATextDepartureLeavesTheCloseToTheSlide() {
        let page = page(style: .list)
        let tapped = page.posts[2].id
        let landed = page.posts[3].id
        #expect(page.post(for: tapped)?.kind == .text, "precondition: a text row")

        let source = source(on: page, tapped: tapped, landed: landed)
        let heroTakesIt = ForYouViewController.heroLandingArbiter(asking: source)

        withExtendedLifetime(source) {
            #expect(!heroTakesIt(), "the slide deferred to a hero that cannot land")
        }
    }

    /// No flight, no opinion — the slide's gate reads what it read before the
    /// channel existed.
    @Test func noSourceIsNoOpinion() {
        #expect(ForYouViewController.heroLandingArbiter(asking: nil)())
    }
}
