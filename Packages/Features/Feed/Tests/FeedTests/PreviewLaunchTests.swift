import CoreModels
import CoreNavigation
import Foundation
import MediaCore
import PostGrid
import QuartzCore
import Testing
import UIKit
@testable import Feed

/// ⚠️ A WINDOW OPENS OUT OF THE LIFT TOO (#1543): words and friends' faces
/// open through a window, and every surface's window is built in one place
/// (`TextRevealInstaller`), which looks the lift up rather than being handed
/// it. The lift answers for its own post only, while its capture lasts, and
/// hands its still to the window — kept where the lift was, never stretched.
@MainActor
struct PreviewLaunchTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private static let drawnAt = CGRect(x: 24, y: 180, width: 345, height: 460)

    private func post(_ id: String, kind: GalleryPost.Kind) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(id).jpg"),
            aspectRatio: 1, caption: "post \(id)", publishedAtMS: 10_000,
            authorID: ProfileID("a"), authorName: "Author", authorHandle: "author",
            reactionCount: 3
        )
    }

    /// A lift mounted as UIKit mounts it, and its launch.
    private func launch(
        _ post: GalleryPost, now: CFTimeInterval = CACurrentMediaTime()
    ) throws -> (PreviewLaunch, window: UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 874))
        window.isHidden = true
        let preview = ForYouPostPreviewViewController(
            post: post, imagePipeline: ImagePipeline(fetcher: SilentFetcher()), width: 361
        )
        _ = TileHeroOriginTests.mountLift(preview, drawnAt: Self.drawnAt, in: window)
        return (try #require(PreviewLaunch(preview, now: now)), window)
    }

    @Test func aLiftAnswersForItsOwnPostWhileItsCaptureLasts() throws {
        let (launch, _) = try launch(post("words", kind: .text))
        #expect(PreviewLaunch.pending(for: PostID("words")) === launch)
        #expect(PreviewLaunch.pending(for: PostID("other")) == nil, "another post opened out of the lift")
        let later = CACurrentMediaTime() + PreviewLaunch.lifetime + 0.1
        #expect(PreviewLaunch.pending(for: PostID("words"), now: later) == nil, "a later open left from the lift")
        #expect(launch.revealLaunch(now: later) == nil)
    }

    @Test(arguments: [GalleryPost.Kind.text, .photo])
    func aWindowOpensOutOfTheLift(kind: GalleryPost.Kind) throws {
        let (launch, window) = try launch(post("p", kind: kind))
        let reveal = try #require(launch.revealLaunch())
        #expect(reveal.frame(window) == Self.drawnAt)
        #expect(reveal.cornerRadius == PreviewLaunch.cornerRadius)
        #expect(reveal.cornerCurve == .continuous)
        // Words are seen in place; a picture fills the window.
        #expect(reveal.pageFit == (kind == .text ? .clipped : .covering))

        // The still the lift's place was held with is the window's now —
        // on the page's ground, kept at the lift's size and place.
        #expect(launch.debugIsHolding, "no still held the lift's place")
        let standIn = try #require(reveal.makeStandIn() as? LiftStandInView)
        #expect(launch.debugIsHolding == false, "the still stayed in the window over the opening")
        #expect(standIn.backgroundColor == (kind == .text ? .systemBackground : .black))
        window.addSubview(standIn)
        standIn.frame = window.bounds
        standIn.layoutIfNeeded()
        let still = try #require(standIn.subviews.first)
        #expect(still.convert(still.bounds, to: window) == Self.drawnAt, "the lift's words grew with the window")
        #expect(reveal.makeStandIn() == nil, "one still, two stand-ins")
        // Concealing for a flight leaves a still the window took alone.
        launch.conceal()
        #expect(still.superview === standIn)
    }
}
