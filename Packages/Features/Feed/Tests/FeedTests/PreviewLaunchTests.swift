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

    // ⚠️ EVERY READ AT A STATED TIME, never the clock's (#1888): a starved
    // runner can stall the main thread past the capture's one-second
    // lifetime between the capture and the read (CI run 40860820962).

    @Test func aLiftAnswersForItsOwnPostWhileItsCaptureLasts() throws {
        let now = CACurrentMediaTime()
        let (launch, _) = try launch(post("words", kind: .text), now: now)
        #expect(PreviewLaunch.pending(for: PostID("words"), now: now) === launch)
        #expect(PreviewLaunch.pending(for: PostID("other"), now: now) == nil, "another post opened out of the lift")
        let later = now + PreviewLaunch.lifetime + 0.1
        #expect(PreviewLaunch.pending(for: PostID("words"), now: later) == nil, "a later open left from the lift")
        #expect(launch.revealLaunch(now: later) == nil)
    }

    @Test(arguments: [GalleryPost.Kind.text, .photo])
    func aWindowOpensOutOfTheLift(kind: GalleryPost.Kind) throws {
        // Captured a minute ahead: the window's frame reads the clock.
        // One reading of the clock for both (#1962): a stall longer than the
        // capture's lifetime between two readings expired it on a starved
        // runner.
        let now = CACurrentMediaTime() + 60
        let (launch, window) = try launch(post("p", kind: kind), now: now)
        let reveal = try #require(launch.revealLaunch(now: now))
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

    // MARK: - Finding UIKit's drawing (#1888)

    private func makePreview(_ id: String = "p", kind: GalleryPost.Kind = .photo) -> ForYouPostPreviewViewController {
        ForYouPostPreviewViewController(
            post: post(id, kind: kind), imagePipeline: ImagePipeline(fetcher: SilentFetcher()), width: 361
        )
    }

    /// The lift's controller held off screen at alpha 0, as UIKit holds it.
    private func holdLift(_ preview: UIViewController, size: CGSize, in window: UIWindow) {
        let held = UIView(frame: window.bounds)
        held.alpha = 0
        preview.view.frame = CGRect(origin: CGPoint(x: -window.bounds.width, y: 0), size: size)
        held.addSubview(preview.view)
        window.addSubview(held)
    }

    /// ⚠️ A PLATTER UIKIT SHRANK (#1888): a preview taller than the room the
    /// menu leaves is drawn smaller than the lift. It is found by its shape,
    /// and the flight leaves from where it is drawn.
    @Test func aPlatterUIKitShrankIsFoundByItsShape() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 874))
        window.isHidden = true
        let preview = makePreview()
        holdLift(preview, size: Self.drawnAt.size, in: window)
        let menu = UIView(frame: window.bounds)
        let shrunk = CGRect(x: 40, y: 120, width: Self.drawnAt.width * 0.8, height: Self.drawnAt.height * 0.8)
        let drawn = UIView(frame: shrunk)
        menu.addSubview(drawn)
        window.addSubview(menu)

        let found = try #require(PreviewLaunch.drawing(of: preview.view, in: window))
        #expect(found.view === drawn)
        #expect(found.match == .scaled)
        let now = CACurrentMediaTime()
        let launch = try #require(PreviewLaunch(preview, now: now))
        #expect(launch.frame(in: window, now: now) == shrunk)
    }

    /// The exact size first; a container wider than the lift, or a small
    /// piece of its shape, is never taken for it.
    @Test func onlyTheLiftsSizeOrAShrunkCopyOfItsShapeIsTaken() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 874))
        window.isHidden = true
        let preview = makePreview()
        holdLift(preview, size: Self.drawnAt.size, in: window)
        let menu = UIView(frame: window.bounds)
        window.addSubview(menu)
        let size = Self.drawnAt.size
        // Wider, at the lift's shape; tiny, at the lift's shape; and hidden.
        menu.addSubview(UIView(frame: CGRect(x: 0, y: 0, width: size.width * 1.1, height: size.height * 1.1)))
        menu.addSubview(UIView(frame: CGRect(x: 0, y: 0, width: size.width * 0.2, height: size.height * 0.2)))
        let hidden = UIView(frame: Self.drawnAt)
        hidden.isHidden = true
        menu.addSubview(hidden)
        #expect(PreviewLaunch.drawing(of: preview.view, in: window) == nil)

        // A shrunk copy first in the tree, the exact one deeper: exact wins.
        let shrunk = UIView(frame: CGRect(x: 0, y: 0, width: size.width * 0.9, height: size.height * 0.9))
        menu.addSubview(shrunk)
        let wrapper = UIView(frame: window.bounds)
        let exact = UIView(frame: Self.drawnAt)
        wrapper.addSubview(exact)
        menu.addSubview(wrapper)
        let found = try #require(PreviewLaunch.drawing(of: preview.view, in: window))
        #expect(found.view === exact)
        #expect(found.match == .exact)
    }

    // MARK: - The commit (#1888)

    @MainActor
    private final class CommitAnimator: NSObject, UIContextMenuInteractionCommitAnimating {
        var preferredCommitStyle: UIContextMenuInteractionCommitStyle = .pop
        let previewViewController: UIViewController?
        init(_ preview: UIViewController?) { previewViewController = preview }
        func addAnimations(_ animations: @escaping () -> Void) {}
        func addCompletion(_ completion: @escaping () -> Void) {}
    }

    /// The run loop's next turn.
    private func nextTurn() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    /// ⚠️ THE OPEN NEVER WAITS ON UIKIT (#1888): with the drawing found or
    /// not, the post opens on the next turn — never on the animator's
    /// completion, which this animator never runs — and the lift is
    /// dismissed rather than popped.
    @Test(arguments: [true, false])
    func aCommitOpensOnTheNextTurn(drawn: Bool) async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 874))
        window.isHidden = true
        let preview = makePreview()
        if drawn {
            _ = TileHeroOriginTests.mountLift(preview, drawnAt: Self.drawnAt, in: window)
        } else {
            holdLift(preview, size: Self.drawnAt.size, in: window)
        }
        let animator = CommitAnimator(preview)
        var opened = 0
        let launch = PreviewLaunch.commit(animator, opening: PostID("p")) { opened += 1 }

        #expect((launch != nil) == drawn)
        #expect(animator.preferredCommitStyle == .dismiss)
        #expect(opened == 0, "the post opened inside UIKit's commit")
        await nextTurn()
        #expect(opened == 1, "the post waited on UIKit's completion")
    }

    /// Another post's lift is no origin: the card is.
    @Test func anotherPostsLiftIsNoOrigin() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 874))
        window.isHidden = true
        let preview = makePreview("other")
        _ = TileHeroOriginTests.mountLift(preview, drawnAt: Self.drawnAt, in: window)
        #expect(PreviewLaunch.commit(CommitAnimator(preview), opening: PostID("p")) {} == nil)
        #expect(PreviewLaunch.commit(CommitAnimator(preview), opening: nil) {} != nil, "a face's lift, whatever its post")
        await nextTurn()
    }

    /// In the shelf: the capture when there is one — the menu's dismissal
    /// leaves the lift in place — and the card only without one.
    @Test(arguments: [true, false])
    func theShelfsCommitUsesTheCaptureWhenThereIsOne(drawn: Bool) async throws {
        let shelf = PostShelfSection(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), videoPlayback: nil)
        shelf.frame = CGRect(x: 0, y: 0, width: 393, height: 800)
        _ = shelf.render([post("p", kind: .photo)])
        var tapped: [Int] = []
        shelf.onCardTapped = { tapped.append($0) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 874))
        window.isHidden = true
        let preview = makePreview()
        if drawn {
            _ = TileHeroOriginTests.mountLift(preview, drawnAt: Self.drawnAt, in: window)
        } else {
            holdLift(preview, size: Self.drawnAt.size, in: window)
        }
        let configuration = UIContextMenuConfiguration(identifier: RowMenuTarget.card(PostID("p")).identifier, previewProvider: nil)
        // The capture answers from at least here, for a second.
        let committed = CACurrentMediaTime()
        shelf.collectionView(shelf.mediaView, willPerformPreviewActionForMenuWith: configuration, animator: CommitAnimator(preview))

        #expect((shelf.previewLaunch != nil) == drawn)
        if drawn {
            let target = try #require(shelf.previewLaunch?.dismissalTarget(now: committed))
            #expect(target.target.center == CGPoint(x: Self.drawnAt.midX, y: Self.drawnAt.midY))
        }
        await nextTurn()
        #expect(tapped == [0], "the card did not open")
    }
}
