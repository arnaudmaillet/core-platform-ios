import CoreModels
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// **A PAGE THAT ADOPTS A LANDING'S LIVE SURFACE OWNS WHAT IT DRAWS.**
///
/// The map's cluster feed lands with the present card's live view handed to
/// the page (`SnapFeedCell.adoptLiveRenderView`). That view was only JOINED to
/// the page's player, and the loan stayed filed under the surface the landing
/// threw away — so the pool's next dead-surface sweep retired the player under
/// the page. In the app it was the early-grab stall: the vertical grab's card
/// went dark one tick after its donation, the page behind it was black after
/// the cancel, and the second grab's donation came back REFUSED.
///
/// ⚠️ WHAT THIS CANNOT SEE. No decoder runs here, so "the picture keeps
/// moving" is asserted as the pool's bookkeeping — who owns the playback, and
/// whether a grab can still join it. The frames are the simulator's, against
/// `-zoom-live-log`'s `producer` lines.
@MainActor
struct LiveSurfaceAdoptionTests {
    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }

    private static let clip = URL(string: "mock://video/lyon")!

    private static func model() -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID("post-lyon"),
            authorID: ProfileID("profile-1"),
            authorName: "Ava",
            metaText: "@ava · 3m",
            avatarURL: nil,
            caption: "Lyon",
            mediaURL: clip,
            mediaKind: .video,
            thumbnailURL: nil,
            audioText: nil,
            likeCount: 0,
            timestampText: "now"
        )
    }

    /// A page playing its own clip, as a present with no flying player leaves
    /// it, and the present card mirroring it — the surface the landing adopts.
    private static func pageWithMirroredCard()
        async -> (cell: SnapFeedCell, pool: VideoPlaybackController, card: VideoRenderView) {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 4, capacity: 4)
        let cell = SnapFeedCell(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        cell.configure(
            with: model(),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: pool
        )
        cell.layoutIfNeeded()
        await pool.play(clip, in: cell.debugRenderSurface, scope: "post-lyon")
        let card = VideoRenderView()
        #expect(pool.mirror(from: cell.debugRenderSurface, to: card))
        return (cell, pool, card)
    }

    @Test func theAdoptedSurfaceTakesThePagesLoan() async {
        guard VideoRenderFlags.usesSampleBufferLayer else { return }
        let (cell, pool, card) = await Self.pageWithMirroredCard()
        let replaced = cell.debugRenderSurface
        #expect(pool.hasPlayer(in: replaced), "the premise: the page owns its playback")

        cell.adoptLiveRenderView(card)

        #expect(cell.debugRenderSurface === card)
        #expect(pool.hasPlayer(in: card))
        #expect(!pool.hasPlayer(in: replaced),
                "a loan left on the discarded view is retired by the next sweep")
        #expect(pool.playerCountByURL[Self.clip] == 1)
        #expect(pool.itemCreations == 1)
    }

    /// The second grab of the reported run: the page must still have a live
    /// surface to hand the flight.
    @Test func aGrabAfterTheLandingStillGetsALiveSurface() async {
        guard VideoRenderFlags.usesSampleBufferLayer else { return }
        let (cell, pool, card) = await Self.pageWithMirroredCard()
        cell.adoptLiveRenderView(card)

        let donated = cell.donateLiveRenderView()

        #expect(donated != nil)
        if let donated {
            #expect(pool.isAdvancing(in: donated))
            cell.reclaimDonatedPlayback(donated)
        }
        // A cancelled grab gives nothing back because nothing was taken.
        #expect(pool.hasPlayer(in: card))
        #expect(pool.isAdvancing(in: card))
    }
}
