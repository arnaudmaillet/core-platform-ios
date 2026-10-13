import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import PostGrid

/// The media surface (#1088): a cover on the loading ladder, and the live
/// surface's plumbing every grid host copied.
@MainActor
struct MediaSurfaceTests {
    private func makePipeline() -> ImagePipeline { ImagePipeline(fetcher: PlaceholderImageFetcher()) }

    private func solid(_ color: UIColor = .systemTeal) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func makeRig() -> (MediaSurface, UIImageView, UIView) {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 160))
        let cover = UIImageView()
        cover.frame = host.bounds
        host.addSubview(cover)
        return (MediaSurface(cover: cover, in: host, coverSize: .full), cover, host)
    }

    /// A cover the pipeline holds is drawn in the configure pass, unanimated,
    /// and nothing is announced as "loaded".
    @Test func aWarmCoverDrawsAtOnce() throws {
        let pipeline = makePipeline()
        let url = try #require(URL(string: "mock://cover/warm"))
        pipeline.store(solid(), for: url, size: .full)
        let (media, cover, _) = makeRig()
        var loaded = 0
        media.onCoverLoaded = { loaded += 1 }
        media.loadCover(url, pipeline: pipeline, item: "p1")
        #expect(cover.image != nil)
        #expect(media.ladder.transitions.last?.1 == LoadingLadder.Transition.none)
        #expect(loaded == 0)
    }

    /// A late cover dissolves in, becomes the live surface's poster, and is
    /// announced — the autoplay waits on it.
    @Test func aLateCoverLandsAndIsAnnounced() async throws {
        let (media, cover, _) = makeRig()
        var loaded = 0
        media.onCoverLoaded = { loaded += 1 }
        media.loadCover(try #require(URL(string: "mock://cover/late")), pipeline: makePipeline(), item: "p1")
        #expect(cover.image == nil)
        for _ in 0..<200 where loaded == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(cover.image != nil)
        #expect(loaded == 1)
        #expect(media.ladder.transitions.last?.1 == .pictureArrives)
    }

    /// ⚠️ THE PARKED FRAME WINS (hook 7): a closing hero lands the tile on its
    /// frame, and the pipeline's thumbnail landing afterwards does not replace
    /// it.
    @Test func aParkedFrameOutranksALateThumbnail() async throws {
        let (media, cover, _) = makeRig()
        media.loadCover(try #require(URL(string: "mock://cover/parked")), pipeline: makePipeline(), item: "p1")
        let parked = solid(.systemRed)
        media.showReturnStill(parked)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(cover.image === parked)
        #expect(media.ladder.previewSource == .parked)
    }

    /// A recycled host never shows the previous post's cover.
    @Test func aResetDropsTheLateCover() async throws {
        let (media, cover, _) = makeRig()
        media.loadCover(try #require(URL(string: "mock://cover/old")), pipeline: makePipeline(), item: "p1")
        media.reset()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(cover.image == nil)
    }

    /// The same post again is a reconfigure: nothing restarts.
    @Test func theSamePostAgainIsAReconfigure() throws {
        let pipeline = makePipeline()
        let url = try #require(URL(string: "mock://cover/same"))
        pipeline.store(solid(), for: url, size: .full)
        let (media, _, _) = makeRig()
        media.loadCover(url, pipeline: pipeline, item: "p1")
        let generation = media.ladder.generation
        media.loadCover(url, pipeline: pipeline, item: "p1")
        #expect(media.ladder.generation == generation)
    }

    /// The surface: built hidden just above the cover, its poster the cover;
    /// one lent in replaces it, shown; donated, the host keeps its cover.
    @Test func theSurfaceIsBuiltAboveTheCoverAndLentAround() {
        let (media, cover, host) = makeRig()
        cover.image = solid()
        let built = media.makeVideoRenderViewIfNeeded()
        #expect(built.isHidden)
        #expect(host.subviews.firstIndex(of: built) == host.subviews.firstIndex(of: cover).map { $0 + 1 })
        #expect(media.makeVideoRenderViewIfNeeded() === built)

        let lent = VideoRenderView()
        lent.isHidden = true
        media.adopt(lent)
        #expect(media.video === lent)
        #expect(!lent.isHidden)
        #expect(built.superview == nil, "the replaced surface stayed in the host")

        #expect(media.donate() === lent)
        #expect(lent.superview == nil)
        #expect(media.video == nil)
        #expect(cover.superview === host)
    }
}
