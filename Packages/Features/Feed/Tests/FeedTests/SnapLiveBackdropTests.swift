import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// Which pages let their blurred band play (`LiveMediaBackdrop`): a single
/// clip framed `.fitBlurred`, on the page the cell says is being watched —
/// and nothing else.
@MainActor
struct SnapLiveBackdropTests {
    @Test func aWatchedFittedClipPlaysItsBand() {
        let card = Self.fittedClip()
        card.setLiveBackdropActive(true)
        #expect(card.debugLiveBackdrop.isRunning)
        card.setLiveBackdropActive(false)
        #expect(!card.debugLiveBackdrop.isRunning)
    }

    /// A neighbour — any page the cell has not activated — stays on the still.
    @Test func aClipThatIsNotWatchedKeepsTheStill() {
        let card = Self.fittedClip()
        #expect(!card.debugLiveBackdrop.isRunning)
        #expect(card.backdropImage != nil)
    }

    /// A photo's band is its photo, blurred, and there is nothing to play.
    @Test func aFittedPhotoNeverPlaysItsBand() {
        let card = SnapMediaCardView()
        card.debugLiveBackdrop.isSuppressedBySystem = { false }
        card.configure(kind: .image)
        card.setImage(Self.image(CGSize(width: 80, height: 100)))
        #expect(card.framing == .fitBlurred)
        card.setLiveBackdropActive(true)
        #expect(!card.debugLiveBackdrop.isRunning)
    }

    /// A tall clip fills: there is no band to play.
    @Test func aFillingClipHasNoBandToPlay() {
        let card = SnapMediaCardView()
        card.debugLiveBackdrop.isSuppressedBySystem = { false }
        card.configure(kind: .video)
        card.setDeclaredAspect(CGSize(width: 9, height: 16))
        card.setPoster(Self.image(CGSize(width: 90, height: 160)))
        #expect(card.framing == .fill)
        card.setLiveBackdropActive(true)
        #expect(!card.debugLiveBackdrop.isRunning)
    }

    /// Reduce Motion or Low Power: the still, whatever the cell says.
    @Test func reducedMotionKeepsTheStill() {
        let card = Self.fittedClip(suppressed: true)
        card.setLiveBackdropActive(true)
        #expect(!card.debugLiveBackdrop.isRunning)
    }

    /// Recycled for a new post, a card's band is that post's still again, and
    /// stops following the old clip until its page is watched.
    @Test func aRecycledCardStopsAndGoesBackToTheStill() {
        let card = Self.fittedClip()
        card.setLiveBackdropActive(true)
        card.configure(kind: .image)
        #expect(!card.debugLiveBackdrop.isRunning)
        #expect(!card.debugLiveBackdrop.isShowingLive)
        card.setLiveBackdropActive(false)
    }

    /// ⚠️ THE CARD IS THE SOURCE, NOT THE SURFACE. A surface that has left the
    /// card — donated to a hero flight — is not this page's to sample, even
    /// though it is in a window and drawing.
    @Test func aSurfaceThatLeftTheCardIsNotSampled() {
        let card = Self.fittedClip()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        window.addSubview(card)
        let surface = card.renderView
        surface.removeFromSuperview()
        window.addSubview(surface)
        #expect(!card.isShowingLiveFrames)
    }

    /// ⚠️ THE BAND FOLLOWS THE CARD'S SURFACE, WHICHEVER IT IS. It is that
    /// surface's frame companion — the renderer hands it each frame ahead and
    /// tells it when the frame goes on screen — and a landing re-points the
    /// card at the flight's surface: the band must move with it, and leave the
    /// surface it replaced.
    @Test func theBandIsTheCompanionOfWhicheverSurfaceTheCardDrawsWith() {
        let card = Self.fittedClip()
        let first = card.renderView
        #expect(first.frameCompanion === card.debugLiveBackdrop)
        let landed = VideoRenderView()
        card.restoreRenderView(landed)
        #expect(card.renderView === landed)
        #expect(landed.frameCompanion === card.debugLiveBackdrop)
        #expect(first.frameCompanion == nil)
    }

    /// A band that is running asks for frames ahead only while its card's
    /// surface is drawing in a window — never for a card nobody can see.
    @Test func aBandAsksForFramesOnlyWhileItsCardIsOnScreen() {
        let card = Self.fittedClip()
        card.setLiveBackdropActive(true)
        #expect(card.debugLiveBackdrop.isRunning)
        #expect(!card.debugLiveBackdrop.wantsFramesAhead, "a card outside a window asked for frames")
        card.setLiveBackdropActive(false)
    }

    private static func fittedClip(suppressed: Bool = false) -> SnapMediaCardView {
        let card = SnapMediaCardView()
        card.debugLiveBackdrop.isSuppressedBySystem = { suppressed }
        card.configure(kind: .video)
        card.setDeclaredAspect(CGSize(width: 4, height: 5))
        card.setPoster(Self.image(CGSize(width: 80, height: 100)))
        #expect(card.framing == .fitBlurred)
        return card
    }

    private static func image(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
