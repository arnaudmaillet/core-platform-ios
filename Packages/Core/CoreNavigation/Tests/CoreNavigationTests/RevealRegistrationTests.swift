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

    /// A page under a flight moves one of three ways, and the three are not
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
