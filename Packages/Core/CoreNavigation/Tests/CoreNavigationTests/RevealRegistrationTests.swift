import Testing
import UIKit
@testable import CoreNavigation

/// The reveal's window can be GRABBED, which means its position stops being a
/// function of progress and becomes a function of the hand. These pin the law
/// that keeps the page's caption inside it anyway — see
/// `RevealStage.pageTranslation`.
///
/// Pure geometry, tested without a view hierarchy, for the reason
/// `ZoomTransitionGeometryTests` is: the failure it guards against is silent.
/// A window whose content has drifted still animates, still lands, still
/// completes — it just shows the wrong words on the way, and the only signal is
/// a frame capture somebody has to think to take.
@MainActor
struct RevealRegistrationTests {
    /// An iPhone SE: the page fills the screen, its caption row starts 110pt
    /// down and 16pt in, and the row it came from is 145pt tall at y 427.
    private static let screen = CGRect(x: 0, y: 0, width: 375, height: 667)
    private static let anchor = CGRect(x: 16, y: 110, width: 343, height: 299)
    private static let landing = CGRect(x: 16, y: 427, width: 343, height: 145)

    /// At rest the page has not moved, whatever else is true.
    @Test func theRestingPoseDoesNotMoveThePage() {
        let translation = RevealStage.pageTranslation(
            carrying: Self.screen, anchor: Self.anchor, progress: 0
        )
        #expect(translation == .zero)
    }

    /// And home, the law must agree with the closed pose the animated legs fly
    /// to — otherwise a released grab would land somewhere a chevron does not.
    @Test func theHomePoseAgreesWithTheClosedPose() {
        let closed = RevealStage.closed(
            sourceRect: Self.landing, radius: 18, anchor: Self.anchor, matchesAnchor: true
        )
        let translation = RevealStage.pageTranslation(
            carrying: Self.landing, anchor: Self.anchor, progress: 1
        )
        #expect(translation == closed.pageTranslation)
    }

    /// The horizontal component is zero at BOTH ends — the row and the page
    /// carry their captions at the same inset — which is why the animated legs
    /// never needed one and why its absence went unnoticed until a window could
    /// be held off-axis.
    @Test func theHorizontalComponentVanishesAtBothEnds() {
        #expect(RevealStage.pageTranslation(
            carrying: Self.screen, anchor: Self.anchor, progress: 0
        ).x == 0)
        #expect(RevealStage.pageTranslation(
            carrying: Self.landing, anchor: Self.anchor, progress: 1
        ).x == 0)
    }

    /// Mid-grab it is emphatically NOT zero: a window dragged sideways carries
    /// the page with it, one point for one point. This is the regression — the
    /// window used to slide across the text instead.
    @Test func aSidewaysDragCarriesThePageWithTheWindow() {
        let held = Self.screen.offsetBy(dx: 134, dy: 0)
        let still = RevealStage.pageTranslation(
            carrying: Self.screen, anchor: Self.anchor, progress: 0.55
        )
        let dragged = RevealStage.pageTranslation(
            carrying: held, anchor: Self.anchor, progress: 0.55
        )
        #expect(dragged.x - still.x == 134)
        #expect(dragged.y == still.y)
    }

    /// The gap between the window's top edge and the caption's closes smoothly
    /// — it is the resting gap scaled by how far from home the grab is, which
    /// is the whole content of the law.
    @Test func theGapClosesInProportionToProgress() {
        for progress in stride(from: CGFloat(0), through: 1, by: 0.25) {
            let window = Self.screen.offsetBy(dx: 40, dy: 90)
            let translation = RevealStage.pageTranslation(
                carrying: window, anchor: Self.anchor, progress: progress
            )
            let captionTop = Self.anchor.minY + translation.y
            #expect(abs((captionTop - window.minY) - (1 - progress) * Self.anchor.minY) < 0.001)
        }
    }

    /// A source card can put its caption BELOW its own top edge — an author
    /// band above it — and the window is the whole card either way. These pin
    /// the term that carries the difference.
    ///
    /// The band's height, plus the gap under it, as `PostGridListRowCell`
    /// measures it on an iPhone SE.
    private static let bandOffset: CGFloat = 52

    /// At rest the band is irrelevant: the page's caption is where the page put
    /// it, and nothing has moved.
    @Test func theBandDoesNotMoveTheRestingPose() {
        #expect(RevealStage.pageTranslation(
            carrying: Self.screen, anchor: Self.anchor, progress: 0,
            captionTop: Self.bandOffset
        ) == .zero)
    }

    /// And home, the caption lands on the CARD's caption rather than on the
    /// window's top edge — which is the whole reason the term exists.
    @Test func theBandOffsetsTheHomePoseByExactlyItself() {
        let plain = RevealStage.pageTranslation(
            carrying: Self.landing, anchor: Self.anchor, progress: 1
        )
        let banded = RevealStage.pageTranslation(
            carrying: Self.landing, anchor: Self.anchor, progress: 1,
            captionTop: Self.bandOffset
        )
        #expect(banded.y - plain.y == Self.bandOffset)
        #expect(banded.x == plain.x)
    }

    /// And the closed pose agrees with the law, band or no band — otherwise a
    /// released grab would land somewhere a chevron does not.
    @Test func theClosedPoseCarriesTheBandToo() {
        let closed = RevealStage.closed(
            sourceRect: Self.landing, radius: 18, anchor: Self.anchor,
            matchesAnchor: true, captionTop: Self.bandOffset
        )
        let law = RevealStage.pageTranslation(
            carrying: Self.landing, anchor: Self.anchor, progress: 1,
            captionTop: Self.bandOffset
        )
        #expect(closed.pageTranslation == law)
    }

    /// The window stops being the page and becomes the card WITHOUT ever being
    /// both — see `RevealStage.swapFractions`. These pin what reading the
    /// numbers will not tell you.
    ///
    /// The design exists because blending two runs of text draws both of them,
    /// which this transition established four times over.
    @Test func theWindowIsNeverEmptyForAnyMeasurableTime() {
        // The card starts exactly where the fill lands, so the empty region has
        // no width. It used to be a tenth of the gesture wide, which read as a
        // hole rather than as a hand-off.
        #expect(RevealStage.cardFadeStart == RevealStage.pageFadeEnd)
        // A hair past the hand-off, the card is already there — and visibly so,
        // because it leaves zero fast. Linear, it would still be at 3%.
        #expect(RevealStage.swapFractions(at: RevealStage.pageFadeEnd + 0.01).content > 0.05)
    }

    /// The two fades never overlap — the card cannot begin before the page has
    /// finished, at any progress at all.
    @Test func theTwoFadesNeverOverlap() {
        // The card may not begin before the page is COVERED — which is what
        // the fill reaching 1 means, the fill being opaque. Equal is enough;
        // it never needed a gap.
        #expect(RevealStage.cardFadeStart >= RevealStage.pageFadeEnd)
        for step in 0...100 {
            let swap = RevealStage.swapFractions(at: CGFloat(step) / 100)
            // Partway through one means the other is finished or not started.
            if swap.fill > 0, swap.fill < 1 { #expect(swap.content == 0) }
            if swap.content > 0 { #expect(swap.fill == 1) }
        }
    }

    // MARK: - What a held grab may do

    /// ⚠️ A HELD WINDOW IS STILL THE PAGE. It may not shrink toward its
    /// landing under the hand.
    ///
    /// Morphing all the way to the landing by progress is right against a
    /// CARD, which is large enough to leave something recognisable in the hand
    /// at full drag. Against a 44pt marker it took the post most of the way to
    /// a disc for a modest pull — reported as the grab being far too sensitive.
    /// The remaining distance belongs to the release spring, which is when the
    /// outcome is actually known.
    @Test func aHeldWindowMayNotShrinkPastTheFlightsFloor() {
        #expect(RevealStage.grabMorph(at: 0) == 1, "the window shrank before the finger moved")
        #expect(RevealStage.grabMorph(at: 1) == ZoomFlight.minimumGrabScale,
                "a held window went past the floor a held card stops at")
        // Shared with the hero rather than restated: the two are one dismissal
        // wearing two animations, and a hand that learnt one should find the
        // other familiar.
        #expect(RevealStage.grabMorph(at: 1) > 0.5, "a held post is not a thumbnail")

        var previous = CGFloat(2)
        for step in 0...100 {
            let value = RevealStage.grabMorph(at: CGFloat(step) / 100)
            #expect(value <= previous, "the morph is not monotonic")
            previous = value
        }
        // Beyond the end of the drag it holds rather than continuing.
        #expect(RevealStage.grabMorph(at: 4) == ZoomFlight.minimumGrabScale)
        #expect(RevealStage.grabMorph(at: -1) == 1)
    }

    /// ⚠️ AND THE FORWARD LIMIT IS AN AXIS'S OWN, not one number for both.
    ///
    /// 320pt was measured on the vertical axis, where a screen is ~874pt and a
    /// full throw still leaves most of the thing on screen. Applied unchanged
    /// to a 402pt-wide screen it put the whole window past the right edge with
    /// the finger still down — the exact motion the constant exists to
    /// prevent, on the axis nobody measured.
    @Test func theForwardLimitFirmsUpOnAShortAxis() {
        let tall = ZoomTransitionGeometry.forwardDragLimit(forSpan: 874)
        let wide = ZoomTransitionGeometry.forwardDragLimit(forSpan: 402)

        #expect(tall == ZoomTransitionGeometry.forwardDragLimit,
                "the vertical axis was retuned; it was already right")
        #expect(wide < tall, "a short axis got a tall axis's throw")
        // The window keeps more than half of itself on screen at full throw:
        // at the grab floor it is 0.6 of the screen wide, and it may not
        // travel further than its own half-width past the centre.
        let windowHalfWidth = 402 * ZoomFlight.minimumGrabScale / 2
        #expect(wide < 402 / 2 + windowHalfWidth,
                "the window can still leave the screen entirely")
        #expect(ZoomTransitionGeometry.forwardDragLimit(forSpan: 0)
            == ZoomTransitionGeometry.forwardDragLimit, "a zero span must not zero the limit")
    }

    /// And it is over before the drag is: a swap still running at the release
    /// would land a half-drawn card on the row.
    @Test func theSwapFinishesBeforeTheDragCan() {
        let done = RevealStage.swapFractions(at: 1)
        #expect(done.fill == 1)
        #expect(done.content == 1)
        #expect(RevealStage.cardFadeEnd < 1)
    }

    /// A page under a flight moves one of three ways    /// A page under a flight moves one of three ways, and the three are not
    /// interchangeable. These pin the one a stand-in selects.
    ///
    /// * REGISTERED — the page slides so its caption lands on the card's.
    /// * STILL — the page does not move; the window opens over it.
    /// * RIDING — the page moves with the window, rigidly.
    ///
    /// The middle one is the trap. It looks like the safe answer once a
    /// stand-in is showing the card (nothing behind it matters, so why move
    /// it?) and it is wrong for a GRAB: the window travels under the finger
    /// while its contents stay nailed to the screen, which is dragging a hole
    /// rather than holding a card.
    @Test func aRidingPageMovesExactlyWithItsWindow() {
        let held = Self.screen.offsetBy(dx: 120, dy: 60)
        let translation = RevealStage.pageRiding(held, from: Self.screen)
        #expect(translation == CGPoint(x: 120, y: 60))
    }

    /// A window back at rest has ridden nowhere — which is why an abandoned
    /// grab needs no special case.
    @Test func aWindowAtRestHasRiddenNowhere() {
        #expect(RevealStage.pageRiding(Self.screen, from: Self.screen) == .zero)
    }

    /// And a closed pose that rides carries the page by the LANDING's
    /// displacement, ignoring the anchor entirely — the alignment is what a
    /// stand-in makes meaningless.
    @Test func aRidingClosedPoseIgnoresTheAnchor() {
        let riding = RevealStage.closed(
            sourceRect: Self.landing, radius: 18, anchor: Self.anchor,
            matchesAnchor: true, captionTop: 52, ridingFrom: Self.screen
        )
        #expect(riding.pageTranslation
            == RevealStage.pageRiding(Self.landing, from: Self.screen))
        // Emphatically NOT the registered answer, which is the whole point.
        let registered = RevealStage.closed(
            sourceRect: Self.landing, radius: 18, anchor: Self.anchor,
            matchesAnchor: true, captionTop: 52
        )
        #expect(riding.pageTranslation != registered.pageTranslation)
    }

    /// Plain mode has no anchor to register against, and the page simply sits
    /// still while the window moves over it — the `-text-reveal-plain`
    /// behaviour, unchanged by any of this.
    @Test func plainModeLeavesThePageAlone() {
        #expect(RevealStage.pageTranslation(
            carrying: Self.landing, anchor: nil, progress: 1
        ) == .zero)
    }
}


/// The ordinary case: a card the page has no copy of, which needs all three
/// acts.
@MainActor
private final class OrdinaryStandIn: UIView, RevealStandInShaping {
    func setCornerRadius(_ radius: CGFloat) {}
    func setContentOpacity(_ alpha: CGFloat) {}
}
