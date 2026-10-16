import CoreModels
import CoreNavigation
import FeedInterface
import Foundation
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// A close that pages on and comes home to the tile that opened the feed
/// (#923): which picture the tile ends up showing, and how the tile's own
/// picture arrives over the page's.
///
/// The rule (#888/#908): the close lands on the tile that opened the feed, and
/// that tile keeps ITS OWN post. Filmed broken on a Following card: open a
/// video, swipe to another video, close — the card flew the page's clip home
/// and the landing handed it to the tile, which then played the other post.
@MainActor
struct ReturnToOriginTileTests {
    private static func post(_ id: String, kind: GalleryPost.Kind = .video) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: URL(string: "https://example.test/\(id).jpg"),
            videoURL: kind == .video ? URL(string: "mock://video/\(id)") : nil,
            aspectRatio: 1, caption: "caption \(id)", publishedAtMS: 0
        )
    }

    private static func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    // MARK: - Landing content choice (an origin outside the grid: the rows)

    /// The pieces of one close, as the flight drives them.
    @MainActor
    private final class Close {
        var adopted: [UIView] = []
        var pauses = 0
        let returnSurface = VideoRenderView()
        let departureSurface = VideoRenderView()
        var parked = true
    }

    private func externalSource(
        _ close: Close, settledOn settled: PostID
    ) -> (ExternalHeroZoomSource, GalleryPost) {
        let tapped = Self.post("tapped")
        let origin = SnapFeedHeroOrigin(
            post: tapped, cover: Self.picture(), style: .listMedia,
            frame: { _ in .zero }, isOnScreen: { true }, setConcealed: { _ in },
            adoptLandingLiveMedia: { close.adopted.append($0) },
            returnLiveMedia: { close.parked ? close.returnSurface : nil },
            pauseReturnLiveMedia: { close.pauses += 1 }
        )
        return (ExternalHeroZoomSource(origin: origin, settle: { (id: settled, cover: nil) }), tapped)
    }

    /// ⚠️ THE FILMED DEFECT. Closing from another post, the landing hands the
    /// tile its OWN clip (the return surface the card faded in), never the
    /// departure surface, which is the page's post.
    @Test func aCloseFromAnotherPostLandsTheTilesOwnClip() throws {
        let close = Close()
        let (source, _) = externalSource(close, settledOn: PostID("other"))
        source.zoomSourceWillStageDismissal()
        let card = try #require(source.makeZoomFlightCard() as? PostGridFlightCard)
        card.adoptZoomLiveMediaView(close.departureSurface)

        source.zoomAdoptLiveMediaView(close.departureSurface)
        source.setZoomSourceHidden(false)

        #expect(close.adopted.count == 1, "the landing ran twice, or never")
        #expect(close.adopted.first === close.returnSurface)
        #expect(!close.adopted.contains { $0 === close.departureSurface },
                "the tile was handed the post the viewer closed")
    }

    /// Same post: unchanged — the tile takes the very surface the card flew.
    @Test func aCloseFromTheSamePostStillLandsTheFlownSurface() throws {
        let close = Close()
        let (source, tapped) = externalSource(close, settledOn: PostID("tapped"))
        source.zoomSourceWillStageDismissal()
        _ = try #require(source.makeZoomFlightCard() as? PostGridFlightCard)

        source.zoomAdoptLiveMediaView(close.departureSurface)
        source.setZoomSourceHidden(false)

        #expect(tapped.id == PostID("tapped"))
        #expect(close.adopted.count == 1)
        #expect(close.adopted.first === close.departureSurface)
    }

    /// A card that flew no departure surface (a photo page) never reaches
    /// `zoomAdoptLiveMediaView`; the reveal still hands the tile its clip.
    @Test func aCloseWithNoDepartureSurfaceStillLandsTheTilesClip() throws {
        let close = Close()
        let (source, _) = externalSource(close, settledOn: PostID("other"))
        source.zoomSourceWillStageDismissal()
        _ = try #require(source.makeZoomFlightCard() as? PostGridFlightCard)

        source.setZoomSourceHidden(false)
        #expect(close.adopted.count == 1)
        #expect(close.adopted.first === close.returnSurface)
    }

    /// The return player was evicted (a deep stack of pushes): nothing is
    /// handed over and the tile lands on its still — never on the page's clip.
    @Test func anEvictedReturnPlayerLandsOnTheStill() throws {
        let close = Close()
        close.parked = false
        let (source, _) = externalSource(close, settledOn: PostID("other"))
        source.zoomSourceWillStageDismissal()
        let card = try #require(source.makeZoomFlightCard() as? PostGridFlightCard)
        card.adoptZoomLiveMediaView(close.departureSurface)

        source.zoomAdoptLiveMediaView(close.departureSurface)
        source.setZoomSourceHidden(false)
        #expect(close.adopted.isEmpty)
        // The still rises over the page's clip: the card is not left flying
        // the other post into the tile.
        card.setZoomContentBlend(1)
        let pane = card.subviews[card.subviews.count - 1]
        #expect(!pane.isHidden)
        #expect(abs(pane.alpha - 1) < 0.0001)
    }

    /// An abandoned close pauses the tile's clip for the next one, and the next
    /// close decides afresh.
    @Test func anAbandonedClosePausesTheTilesClip() throws {
        let close = Close()
        let (source, _) = externalSource(close, settledOn: PostID("other"))
        source.zoomSourceWillStageDismissal()
        _ = try #require(source.makeZoomFlightCard() as? PostGridFlightCard)
        source.zoomSourceDidAbandonDismissal()
        #expect(close.pauses == 1)
        source.zoomAdoptLiveMediaView(close.departureSurface)
        #expect(close.adopted.first === close.departureSurface,
                "an abandoned close kept deciding the next landing")
    }

    // MARK: - Landing content choice (the For You list)

    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private struct FixedVideoSource: VideoSource {
        let url: URL
        func playableURL(for url: URL) async throws -> URL { self.url }
    }

    private func listPage(pool: VideoPlaybackController) -> ForYouGridPage {
        let page = ForYouGridPage(
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: .list, videoPlayback: pool
        )
        page.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        page.render(.content((0..<6).map { Self.post("row\($0)") }))
        page.layoutIfNeeded()
        return page
    }

    private func makePool() -> VideoPlaybackController {
        VideoPlaybackController(source: FixedVideoSource(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("return-landing.mp4")
        ))
    }

    /// The page's surface, owning the clip the viewer is closing.
    private func pagePlaying(_ pool: VideoPlaybackController) async -> VideoRenderView {
        let surface = VideoRenderView()
        await pool.play(URL(string: "mock://video/page")!, in: surface, scope: "page")
        return surface
    }

    private func tileSurface(of id: PostID, in page: ForYouGridPage) -> VideoRenderView? {
        (page.debugCell(for: id) as? any GridPlaybackCell)?.loadedVideoRenderView
    }

    /// ⚠️ THE LIST KEEPS ITS ORDER, so paging on and closing comes home to the
    /// row that was tapped — and that row must not take the page's player.
    @Test func aListRowClosedFromAnotherPostKeepsItsOwnPost() async throws {
        let pool = makePool()
        let page = listPage(pool: pool)
        let tapped = page.posts[0].id
        let landed = page.posts[1].id
        let departure = await pagePlaying(pool)
        #expect(pool.hasPlayer(in: departure))

        let source = ForYouGridZoomSource(
            page: page, tappedID: tapped, activePostID: { landed }, depthView: nil
        )
        source.zoomSourceWillStageDismissal()
        _ = source.makeZoomFlightCard()
        source.zoomAdoptLiveMediaView(departure)
        source.setZoomSourceHidden(false)

        // The landing moves a loan by identity: had the row taken the page's
        // player, the page's surface would have lost it.
        #expect(pool.hasPlayer(in: departure),
                "the tapped row took the player of the post the viewer closed")
    }

    /// Same post: the row takes the playback the card flew, as before.
    @Test func aListRowClosedFromItsOwnPostTakesTheFlownPlayback() async throws {
        let pool = makePool()
        let page = listPage(pool: pool)
        let tapped = page.posts[0].id
        let departure = await pagePlaying(pool)

        let source = ForYouGridZoomSource(
            page: page, tappedID: tapped, activePostID: { tapped }, depthView: nil
        )
        source.zoomSourceWillStageDismissal()
        _ = source.makeZoomFlightCard()
        source.zoomAdoptLiveMediaView(departure)

        let tile = try #require(tileSurface(of: tapped, in: page))
        #expect(pool.hasPlayer(in: tile), "the row did not take the flown playback")
        #expect(!pool.hasPlayer(in: departure))
    }

    // MARK: - The arrival's curve

    /// Whole by the time the flight is halfway home, and nothing moves after.
    @Test func theArrivalIsWholeByHalfway() {
        #expect(PostGridFlightCard.arrivalAlpha(at: 0) == 0)
        #expect(abs(PostGridFlightCard.arrivalAlpha(at: 0.5) - 1) < 0.0001)
        for t in stride(from: CGFloat(0.5), through: 1, by: 0.05) {
            #expect(abs(PostGridFlightCard.arrivalAlpha(at: t) - 1) < 0.0001)
        }
        #expect(PostGridFlightCard.arrivalAlpha(at: -1) == 0)
        #expect(PostGridFlightCard.arrivalAlpha(at: 2) == 1)
    }

    /// ⚠️ EASE-OUT: fast at first, slow at the end. Rises monotonically, more
    /// than half-way by a quarter of its span, and each equal step of the
    /// flight adds less than the one before.
    @Test func theArrivalIsAnEaseOut() {
        let steps = (0...10).map { PostGridFlightCard.arrivalAlpha(at: CGFloat($0) * 0.05) }
        let gains = zip(steps.dropFirst(), steps).map { $0 - $1 }
        #expect(gains.allSatisfy { $0 > 0 }, "not monotonic over the span")
        #expect(zip(gains.dropFirst(), gains).allSatisfy { $0 < $1 }, "not decelerating")
        #expect(PostGridFlightCard.arrivalAlpha(at: 0.125) > 0.5)
        #expect(PostGridFlightCard.arrivalAlpha(at: 0.25) > 0.85)
    }

    private func blendingCard() -> PostGridFlightCard {
        let card = PostGridFlightCard(post: Self.post("c"), cover: Self.picture(), style: .listMedia)
        card.frame = CGRect(x: 0, y: 0, width: 130, height: 130)
        card.setDepartureShowsAnotherPost(true)
        card.adoptZoomLiveMediaView(VideoRenderView())
        card.setZoomContentBlend(0)
        return card
    }

    private func pane(of card: PostGridFlightCard) -> UIView { card.subviews[card.subviews.count - 1] }

    /// Posed directly — an interactive pose — the curve follows the progress.
    @Test func aPosedFlightTracksTheCurve() {
        let card = blendingCard()
        let flying: any ZoomFlightCard = card
        flying.setZoomContentBlend(0.25)
        #expect(abs(pane(of: card).alpha - PostGridFlightCard.arrivalAlpha(at: 0.25)) < 0.0001)
        flying.setZoomContentBlend(0.5)
        #expect(abs(pane(of: card).alpha - 1) < 0.0001)
    }

    /// ⚠️ INSIDE THE FLIGHT'S ANIMATOR the rise is keyframed over the first
    /// half of it — not left on the flight's own curve for the whole flight.
    /// Asserted on the animation the property animator actually installed.
    @Test func anAnimatedFlightRisesInTheFirstHalf() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let card = blendingCard()
        window.addSubview(card)
        window.isHidden = false
        defer { window.isHidden = true }

        let animator = UIViewPropertyAnimator(duration: 0.42, dampingRatio: 1)
        let flying: any ZoomFlightCard = card
        animator.addAnimations { flying.setZoomContentBlend(1) }
        animator.startAnimation()
        defer { animator.stopAnimation(true) }

        let layer = pane(of: card).layer
        let keyframes = try #require(
            layer.animationKeys()?.compactMap { layer.animation(forKey: $0) as? CAKeyframeAnimation }
                .first { $0.keyPath == "opacity" },
            "the rise was not keyframed"
        )
        let times = try #require(keyframes.keyTimes?.map(\.doubleValue))
        let values = try #require(keyframes.values?.compactMap { ($0 as? NSNumber)?.doubleValue })
        // Whole at or before half of the animation.
        let wholeAt = try #require(zip(times, values).first { $0.1 > 0.999 }?.0)
        #expect(wholeAt <= 0.5 + 0.0001, "whole only at \(wholeAt) of the flight")
        // Fast first: the first keyframe of eight already gains the most.
        #expect(values.count >= 3)
        #expect(values[1] - values[0] > values[values.count - 1] - values[values.count - 2])
        // The model is the landed value.
        #expect(abs(pane(of: card).alpha - 1) < 0.0001)
    }
}
