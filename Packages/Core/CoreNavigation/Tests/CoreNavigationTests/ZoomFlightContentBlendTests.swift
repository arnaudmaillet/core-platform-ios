import Testing
import UIKit
@testable import CoreNavigation

/// The flight's PICTURE channel: the card blends between its own resting
/// content and the picture of the page at the other end.
///
/// Why it exists at all: the two ends of a flight are not always the same
/// picture. A post dismissed onto the marker it came from is one picture at
/// both ends and must not blend; a post dismissed onto a DIFFERENT marker is
/// two, and swapping them in a single frame at the landing is a pop. What is
/// pinned here is the endpoint arithmetic and — just as load-bearing — that the
/// blend and the two chrome alphas remain separate channels.
@MainActor
struct ZoomFlightContentBlendTests {
    private let sourceFrame = CGRect(x: 40, y: 200, width: 56, height: 56)
    private let pageFrame = CGRect(x: 0, y: 0, width: 402, height: 874)

    private func flight(card: BlendCard = BlendCard()) -> (ZoomFlight, BlendCard) {
        let built = ZoomFlight.build(
            source: BlendSource(card: card), destination: BlendDestination(),
            sourceFrame: sourceFrame, pageFrame: pageFrame
        )
        return (built, card)
    }

    // MARK: - Endpoints

    /// The thumbnail end is the source's own picture, whole — the half of the
    /// handshake that has to be pixel-identical to the marker underneath it.
    @Test func theSourcePoseBlendsFullyToTheCardsOwnContent() {
        let (built, card) = flight()
        built.poseAtSource()
        #expect(card.blends.last == 1)

        // And from a landing recomputed at release time, which is the path the
        // interactive driver actually takes.
        built.poseAtSource(at: CGRect(x: 10, y: 20, width: 44, height: 44))
        #expect(card.blends.last == 1)
    }

    /// The full-screen end is the page's picture.
    @Test func thePagePoseBlendsFullyToThePagesPicture() {
        let (built, card) = flight()
        built.poseAsPage(cornerRadius: 55)
        #expect(card.blends.last == 0)
    }

    /// A held card is still the page, so it still wears the page's picture —
    /// the blend belongs to the release, which is when the outcome is known.
    /// Asserted after a source pose so it is the pose SETTING the channel that
    /// is under test, not the value it happened to start at: this one is
    /// re-applied on every pan event, and a channel it does not name is a
    /// channel that can carry a stale value into a whole grab.
    @Test func theHeldCardIsStillThePagesPicture() {
        let (built, card) = flight()
        built.poseAtSource()
        built.poseFloating(scale: 0.8, cornerRadius: 30)
        #expect(card.blends.last == 0)
    }

    // MARK: - The grab's channel

    /// The blend rides the drag rather than waiting for the release spring —
    /// unlike the chrome alphas, and for the reason recorded on
    /// `poseInterpolated`: two opaque pictures with one of them opaque behind
    /// the other produce a whole photograph at every instant, so the "two
    /// half-drawn overlays" objection does not reach them.
    @Test func theBlendTracksTheDragAndLandsExactlyOnBothEnds() {
        let (built, card) = flight()
        let start = CGSize(width: 380, height: 830)
        for step in 0...4 {
            let t = CGFloat(step) / 4
            built.poseInterpolated(t, from: start, to: sourceFrame, startCornerRadius: 55)
            #expect(card.blends.last == t)
        }
    }

    /// Clamped on the same interval as everything else the pose interpolates —
    /// a rubber-banded finger must not drive the blend past either picture.
    @Test func theInterpolatedBlendIsClampedToTheUnitInterval() {
        let (built, card) = flight()
        let start = CGSize(width: 380, height: 830)
        built.poseInterpolated(-0.5, from: start, to: sourceFrame, startCornerRadius: 55)
        #expect(card.blends.last == 0)
        built.poseInterpolated(1.7, from: start, to: sourceFrame, startCornerRadius: 55)
        #expect(card.blends.last == 1)
    }

    /// ⚠️ The live-surface block in `poseInterpolated` returns EARLY for a card
    /// that sizes its own surface. The blend is set ahead of it, because it
    /// belongs to every card and not only to the ones that fall through.
    @Test func aCardSizingItsOwnSurfaceStillGetsTheBlend() {
        let card = BlendCard()
        card.tracksBounds = true
        card.ownSurface = UIView()
        let (built, _) = flight(card: card)
        built.poseInterpolated(0.5, from: pageFrame.size, to: sourceFrame, startCornerRadius: 55)
        #expect(card.blends.last == 0.5)
    }

    // MARK: - Channel separation

    /// The blend is its own channel. The two chrome alphas still swap only
    /// inside the release spring, where one of them is always the answer —
    /// interpolating them mid-drag draws the page's caption over the tile's
    /// counters, which is the defect that rule exists for.
    @Test func theBlendMovesWhileTheChromeAlphasStayPut() {
        let (built, card) = flight()
        built.poseAsPage(cornerRadius: 55)
        #expect(built.chrome?.alpha == 1)
        #expect(card.restingChromeView.alpha == 0)

        for step in 1...4 {
            built.poseInterpolated(
                CGFloat(step) / 4, from: pageFrame.size, to: sourceFrame, startCornerRadius: 55
            )
            #expect(built.chrome?.alpha == 1, "page chrome cross-faded mid-drag")
            #expect(card.restingChromeView.alpha == 0, "resting chrome cross-faded mid-drag")
        }
        #expect(card.blends.last == 1)
    }

    /// The card's resting chrome is posed by the flight, never by the blend —
    /// the two are set from the same poses but are separate properties, so a
    /// card is free to own them independently.
    @Test func theSourcePoseSetsBothChannelsToTheirLandingValues() {
        let (built, card) = flight()
        built.poseAsPage(cornerRadius: 55)
        built.poseAtSource()
        #expect(card.blends.last == 1)
        #expect(card.restingChromeView.alpha == 1)
        #expect(built.chrome?.alpha == 0)
    }

    // MARK: - Dispatch

    /// ⚠️ A REQUIREMENT, not an extension-only member. A protocol-extension
    /// member with no requirement behind it dispatches STATICALLY through an
    /// existential, and every conformer here is held as `any ZoomFlightCard` —
    /// the override would be invisible and the no-op default the only answer
    /// anyone ever got. The card would fly the wrong picture home with every
    /// log reading healthy, which is exactly how
    /// `zoomLiveMediaSurfaceIfReady` cost this codebase an investigation.
    @Test func theBlendIsSeenThroughTheExistentialTheFlightHoldsCardsAs() {
        let spy = BlendCard()
        let existential: any ZoomFlightCard = spy
        existential.setZoomContentBlend(0.25)
        #expect(spy.blends == [0.25])
    }

    /// And a card with one picture inherits a no-op, so nothing that does not
    /// need a blend has to say so.
    @Test func aCardWithNothingToBlendInheritsANoOp() {
        let plain: any ZoomFlightCard = PlainCard()
        plain.setZoomContentBlend(0.5)
        // Reaching here at all is the assertion: the default must exist and
        // must not require the conformer to implement anything.
        #expect(plain.zoomRestingCornerRadius == 10)
    }
}

// MARK: - Stage doubles

private final class BlendSource: NSObject, ZoomTransitionSource {
    private let card: BlendCard
    init(card: BlendCard) { self.card = card }
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { card }
    func setZoomSourceHidden(_ hidden: Bool) {}
}

private final class BlendDestination: NSObject, ZoomTransitionDestination {
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { UIView() }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}
}

/// Records the blend channel in the order the poses drive it.
private final class BlendCard: UIView, ZoomFlightCard {
    let restingChromeView = UIView()
    var ownSurface: UIView?
    var tracksBounds = false
    private(set) var blends: [CGFloat] = []

    var zoomRestingCornerRadius: CGFloat { 12 }
    var zoomRestingChrome: UIView? { restingChromeView }
    func setZoomCornerRadius(_ radius: CGFloat) {}

    var zoomLiveMediaSurface: UIView? { ownSurface }
    var zoomLiveMediaTracksCardBounds: Bool { tracksBounds }
    func setZoomContentBlend(_ t: CGFloat) { blends.append(t) }
}

/// Implements only the requirements — everything else comes from the defaults.
private final class PlainCard: UIView, ZoomFlightCard {
    var zoomRestingCornerRadius: CGFloat { 10 }
    var zoomRestingChrome: UIView? { nil }
    func setZoomCornerRadius(_ radius: CGFloat) {}
}
