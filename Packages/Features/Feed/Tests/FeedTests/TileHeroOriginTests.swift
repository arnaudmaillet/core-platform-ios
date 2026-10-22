import CoreModels
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// ⚠️ ONE CONTRACT FOR EVERY MEDIA TILE (#1270, epic #1269): every host of a
/// `ForYouGridPage` other than For You describes a tile's opening through
/// `ForYouGridPage.heroOrigin`, and the origin carries every hook For You's own
/// tiles fly with — the landing's playhead above all, whose absence restarted
/// a tile's clip after a close onto the same post.
@MainActor
struct TileHeroOriginTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func corpus(_ count: Int) -> [GalleryPost] {
        (0..<count).map { index in
            GalleryPost(
                id: PostID("p\(index)"), kind: .video, isRepost: false,
                thumbnailURL: URL(string: "https://example.com/\(index).jpg"),
                aspectRatio: 1, caption: "post \(index)", publishedAtMS: Int64(10_000 - index),
                authorID: ProfileID("a\(index)"), authorName: "Author \(index)", authorHandle: "author\(index)",
                reactionCount: 100
            )
        }
    }

    private func page(style: ForYouGridPage.Style) -> ForYouGridPage {
        let page = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: style)
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 3000)
        page.setCorpusComplete(true)
        page.render(.content(corpus(12)))
        page.layoutIfNeeded()
        return page
    }

    @Test(arguments: [ForYouGridPage.Style.grid, .list])
    func theOriginCarriesEveryTileHook(style: ForYouGridPage.Style) throws {
        let page = page(style: style)
        let tapped = try #require(page.posts.first)
        let origin = page.heroOrigin(
            opening: tapped, stream: Array(page.posts.prefix(4)), in: page,
            textReveal: nil, continuation: nil
        )
        #expect(origin.post.id == tapped.id)
        #expect(origin.stream.map(\.id) == page.posts.prefix(4).map(\.id))
        #expect(origin.donateLiveMedia != nil, "the card takes off as a still")
        #expect(origin.adoptLandingLiveMedia != nil, "a same-post close restarts the tile's clip")
        #expect(origin.landingMediaIsReady != nil, "the card leaves before the tile draws")
        #expect(origin.returnLiveMedia != nil && origin.pauseReturnLiveMedia != nil)
        #expect(origin.adoptReturnLiveMedia != nil && origin.returnLandingIsReady != nil)
        #expect(origin.restingOverlay != nil, "a close lands bare")
        #expect(origin.followMediaPage != nil)
    }

    /// The host's own staging runs after the page has pinned itself.
    @Test func theHostsStagingRunsAfterThePin() throws {
        let page = page(style: .grid)
        let tapped = try #require(page.posts.first)
        var staged = 0
        let origin = page.heroOrigin(
            opening: tapped, stream: [tapped], in: page,
            textReveal: nil, willStageDismissal: { staged += 1 }, continuation: nil
        )
        origin.willStageDismissal()
        #expect(staged == 1)
    }

    /// ⚠️ FROM THE LIFT (#1543): a committed long press's flight takes off
    /// from where the viewer SEES the preview — UIKit's drawing of it, never
    /// the preview's own view, which sits at alpha 0 off screen — captured at
    /// the commit, and never back through the tile; concealing the tile takes
    /// the drawing with it; once the capture has expired, the tile is the hero
    /// again.
    @Test func aCommittedPreviewIsTheHerosOrigin() throws {
        let grid = page(style: .list)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 3000))
        window.isHidden = true
        window.addSubview(grid)
        let tapped = try #require(grid.posts.first)
        let tile = try #require(grid.hero(for: tapped.id, in: window)).frame

        let preview = ForYouPostPreviewViewController(
            post: tapped, imagePipeline: ImagePipeline(fetcher: SilentFetcher()), width: 361
        )
        let (held, drawn) = Self.mountLift(preview, drawnAt: CGRect(x: 24, y: 180, width: 345, height: 460), in: window)
        grid.previewLaunch = try #require(PreviewLaunch(preview), "UIKit's drawing of the lift was not found")
        // UIKit takes the lift down before the post opens: the capture holds.
        held.removeFromSuperview()
        #expect(grid.hero(for: tapped.id, in: window)?.frame == drawn.frame, "the flight did not leave from the lift")

        grid.setHeroHidden(true, for: tapped.id)
        #expect(drawn.alpha == 0, "the lift draws over the card")
        #expect(grid.previewLaunch?.debugIsHolding == false, "the lift's still stays over the flight")
        grid.setHeroHidden(false, for: tapped.id)

        let earlier = CACurrentMediaTime() - PreviewLaunch.lifetime - 0.1
        drawn.alpha = 1
        window.insertSubview(held, belowSubview: try #require(drawn.superview))
        grid.previewLaunch = try #require(PreviewLaunch(preview, now: earlier))
        #expect(grid.hero(for: tapped.id, in: window)?.frame == tile, "a later close lands on the lift's ghost")
    }

    /// A lift whose drawing cannot be found answers nothing — the tile stays
    /// the origin rather than the preview's own off-screen view.
    @Test func aLiftWithNoDrawingIsNoOrigin() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 874))
        window.isHidden = true
        let preview = ForYouPostPreviewViewController(
            post: corpus(1)[0], imagePipeline: ImagePipeline(fetcher: SilentFetcher()), width: 361
        )
        let held = UIView(frame: window.bounds)
        held.alpha = 0
        preview.view.frame = CGRect(x: -393, y: 0, width: 345, height: 460)
        held.addSubview(preview.view)
        window.addSubview(held)
        #expect(PreviewLaunch(preview) == nil)
    }

    /// A lift as UIKit mounts it (measured on iOS 27): the controller's view
    /// at alpha 0 off screen, and its drawing — the context menu's platter —
    /// in a container added after, where the viewer sees it.
    static func mountLift(
        _ preview: UIViewController, drawnAt frame: CGRect, in window: UIWindow
    ) -> (held: UIView, drawn: UIView) {
        let held = UIView(frame: window.bounds)
        held.alpha = 0
        preview.view.frame = CGRect(origin: CGPoint(x: -window.bounds.width, y: 0), size: frame.size)
        held.addSubview(preview.view)
        window.addSubview(held)
        let menu = UIView(frame: window.bounds)
        let drawn = UIView(frame: frame)
        menu.addSubview(drawn)
        window.addSubview(menu)
        return (held, drawn)
    }
}
