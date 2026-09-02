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

    // MARK: - How the page meets its window

    /// ⚠️ A CARRIED PAGE FILLS ITS WINDOW, always — never fitted inside it.
    ///
    /// Both were shipped in turn and both were filmed. Held still, the page
    /// stayed at full size while the window shrank around it: a keyhole
    /// panning over a photograph. Fitted inside, the media sat letterboxed
    /// with the card's ground above and below it on the release spring, where
    /// the window's aspect leaves the page's. Filling is the invariant every
    /// report agreed on.
    @Test func aCarriedPageFillsItsWindow() {
        let screen = CGRect(x: 0, y: 0, width: 402, height: 874)

        for window in [
            CGRect(x: 16, y: 300, width: 343, height: 145),   // a list row
            CGRect(x: 300, y: 500, width: 44, height: 44),    // a marker
            CGRect(x: 40, y: 120, width: 128, height: 170),   // a grid tile
        ] {
            let fit = RevealStage.pageFitting(window, from: screen, fit: .covering)
            let drawn = CGRect(
                x: window.midX - screen.width * fit.scale / 2,
                y: window.midY - screen.height * fit.scale / 2,
                width: screen.width * fit.scale,
                height: screen.height * fit.scale
            )
            #expect(drawn.insetBy(dx: -0.01, dy: -0.01).contains(window),
                    "the window showed ground: \\(drawn) does not fill \\(window)")
        }
    }

    /// A carried page is the identity at rest, so an abandoned grab needs no
    /// special case.
    @Test func everyFitIsTheIdentityAtRest() {
        let screen = CGRect(x: 0, y: 0, width: 402, height: 874)
        for fit in [RevealPageFit.covering] {
            let pose = RevealStage.pageFitting(screen, from: screen, fit: fit)
            #expect(abs(pose.scale - 1) < 0.0001, "\(fit) moved a page that had not left")
            #expect(abs(pose.translation.x) < 0.0001)
            #expect(abs(pose.translation.y) < 0.0001)
        }
    }

    /// ⚠️ A COMMITTED RELEASE NEVER RUNS ITS TWO CHANNELS AT ONCE.
    ///
    /// A card landing hands over during the drag, with an empty beat between
    /// the page and the card so neither fade has text on both sides. A commit
    /// BELOW that beat skips it — and the release used to set the fill and the
    /// content together, raising the arrival's caption over a page still drawn
    /// at full alpha. A short flick is enough, and a short flick is the
    /// commonest way to leave.
    @Test func aCommittedReleaseFinishesOneChannelBeforeStartingTheOther() {
        for carriesPage in [true, false] {
            let s = RevealStage.releaseHandover(carriesPage: carriesPage)
            #expect(s.fill.delay + s.fill.duration <= s.content.delay + 0.0001,
                    "the arrival started before the fill was done (carries=\(carriesPage))")
            #expect(s.fill.delay >= 0)
            #expect(s.content.delay + s.content.duration <= 1.0001,
                    "the hand-over outlives the spring it rides")
        }
    }

    /// ⚠️ AND A CARRYING RELEASE NEVER LEAVES THE WINDOW EMPTY.
    ///
    /// Two fades that are careful not to overlap cross at NOTHING: the page
    /// went out, the arrival came in after it, and in between the window was a
    /// hole. Filmed on a place page's Activity close.
    ///
    /// The page does not fade at all now, so there is nothing to sequence
    /// against — the arrival covers it in one ramp over the whole release, and
    /// every intermediate frame is an opaque sum of two finished drawings.
    @Test func aCarryingReleaseNeverPassesThroughAHole() {
        let s = RevealStage.releaseHandover(carriesPage: true)
        #expect(s.fill.delay == 0, "the arrival waited, and the window was empty while it did")
        #expect(s.fill.duration == 1, "the arrival did not cover the whole release")

        // The page it covers is whole at both ends, so there is nothing behind
        // the ramp that could thin out under it.
        let landing = RevealStage.closed(
            sourceRect: CGRect(x: 300, y: 500, width: 44, height: 44),
            radius: 22, anchor: nil, matchesAnchor: false,
            ridingFrom: CGRect(x: 0, y: 0, width: 402, height: 874),
            fit: .covering
        )
        #expect(landing.pageOpacity == 1, "the source faded, so the two cross at nothing")
    }

    /// A carrying fit has nothing in the second slot: its content is pinned at
    /// 1 and only the view's alpha moves — one ramp, one direction, over an
    /// opaque page.
    @Test func aCarryingReleaseSchedulesOnlyItsView() {
        let s = RevealStage.releaseHandover(carriesPage: true)
        #expect(s.content.duration == 0, "a carrying fit ramped its content")
        // A card landing still keeps its three acts, and its arrival still
        // waits for the fill — the two fits differ here and are meant to.
        #expect(RevealStage.releaseHandover(carriesPage: false).content.delay
            == RevealStage.cardFadeStart)
    }

    // MARK: - What a held grab may do

    /// ⚠️ A HELD WINDOW IS THE SCREEN — smaller and moved, and nothing else.
    ///
    /// Its aspect is the screen's and its corner is the screen's proportion, so
    /// the SHAPE never changes while the viewer is still deciding. Everything
    /// that did change under the hand was filmed and reported: a window morphing
    /// toward its landing cut the media away or opened ground around it, a
    /// corner swept toward the landing's made a capsule halfway through, and a
    /// page faded out began the hand-over before there was anything to hand
    /// over.
    @Test func aHeldWindowKeepsTheScreensShape() {
        let screen = CGRect(x: 0, y: 0, width: 402, height: 874)
        let screenRadius: CGFloat = 55
        let aspect = screen.width / screen.height
        let roundness = screenRadius / screen.width

        for step in 0...100 {
            let progress = CGFloat(step) / 100
            let held = RevealStage.heldWindow(
                screen, displacedBy: CGPoint(x: progress * 120, y: 0), at: progress
            )
            #expect(abs(held.width / held.height - aspect) < 0.0001,
                    "the window changed aspect under the finger at \(progress)")
            #expect(abs(RevealStage.heldRadius(screenRadius, at: progress) / held.width
                - roundness) < 0.0001,
                    "the window changed roundness under the finger at \(progress)")
        }
    }

    /// And it may not shrink past the floor a held hero card stops at: a page
    /// that reaches thumbnail size in the hand reads as already gone, and the
    /// distance left belongs to the release spring.
    @Test func aHeldWindowStopsAtTheFlightsFloor() {
        let screen = CGRect(x: 0, y: 0, width: 402, height: 874)

        #expect(RevealStage.heldWindow(screen, displacedBy: .zero, at: 0) == screen,
                "the window shrank before the finger moved")
        let full = RevealStage.heldWindow(screen, displacedBy: .zero, at: 1)
        #expect(abs(full.width - screen.width * ZoomFlight.minimumGrabScale) < 0.01,
                "a held window went past the floor a held card stops at")

        var previous = CGFloat.greatestFiniteMagnitude
        for step in 0...100 {
            let width = RevealStage
                .heldWindow(screen, displacedBy: .zero, at: CGFloat(step) / 100).width
            #expect(width <= previous + 0.0001, "the morph is not monotonic")
            previous = width
        }
        // Past the end of the drag it holds rather than continuing.
        #expect(RevealStage.heldWindow(screen, displacedBy: .zero, at: 4).width == full.width)
    }

    /// The displacement is the finger's, and it is the ONLY thing the position
    /// answers to: a window at rest is the screen exactly, so an abandoned grab
    /// has nothing to undo.
    @Test func aHeldWindowFollowsTheFingerFromTheScreensOwnCentre() {
        let screen = CGRect(x: 0, y: 0, width: 402, height: 874)
        let moved = RevealStage.heldWindow(
            screen, displacedBy: CGPoint(x: 90, y: -20), at: 0
        )
        #expect(abs(moved.midX - (screen.midX + 90)) < 0.0001)
        #expect(abs(moved.midY - (screen.midY - 20)) < 0.0001)
        #expect(moved.size == screen.size)
    }

    /// ⚠️ AND NEITHER PROP IS EVEN INSTALLED on a fit that carries the page.
    ///
    /// The veil (the landing card's fill, below its caption) and the borrowed
    /// author band are both DESTINATION scenery, and both are added as
    /// subviews of the departing page — so they scale with it and are drawn
    /// inside the window the finger is holding. Gating the stand-in was not
    /// enough: these two ramped on `pose.progress` with no fit branch at all,
    /// and a card-coloured hole opened down the miniature post with a second
    /// author header above it while the viewer was still deciding.
    ///
    /// Exactly one origin ever armed them on a carrying fit — the place page's
    /// Activity close — and every other carrying source avoided it by passing
    /// `captionEnd: nil`. A convention four sources happened to keep is not a
    /// rule.
    @Test func aCarryingFitInstallsNoDestinationScenery() {
        for fit in [RevealPageFit.covering] {
            let box = SceneryBox()
            installVeil(geometry: box.geometry(fit: fit), anchor: box.anchor)
            installAuthorBand(geometry: box.geometry(fit: fit), anchor: box.anchor)

            #expect(box.veilCut == nil, "\(fit) painted the landing card's fill")
            #expect(box.bandAnchor == nil, "\(fit) borrowed the landing row's author band")
        }
        // The legacy landing keeps both: there the window IS a card-shaped
        // slice of the page, and the props are the transition.
        let legacy = SceneryBox()
        installVeil(geometry: legacy.geometry(fit: .clipped), anchor: legacy.anchor)
        installAuthorBand(geometry: legacy.geometry(fit: .clipped), anchor: legacy.anchor)
        #expect(legacy.veilCut != nil, "the legacy close lost its veil")
        #expect(legacy.bandAnchor != nil, "the legacy close lost its borrowed band")
    }

    // MARK: - The pivot is the release

    /// ⚠️ EVERY FIT THAT CARRIES THE PAGE OBEYS THE SAME DRAG LAW — asking
    /// `== .covering` is a bug that compiles, and it shipped.
    ///
    /// The schedule that keeps the destination off screen during a drag was
    /// gated on `.covering` alone, so a `.contained` landing fell through to
    /// the legacy three acts and its card appeared under the finger. Filmed on
    /// a place page's Activity close, and reported as the same defect twice
    /// because it WAS the same defect, reached by a fit the gate did not name.
    @Test func everyFitThatCarriesThePageAnswersTheSameQuestion() {
        #expect(RevealPageFit.covering.carriesPage)
        #expect(!RevealPageFit.clipped.carriesPage, "the legacy landing must stay legacy")

        // And the drag law follows from that one answer, not from the fit.
        for fit in [RevealPageFit.covering] {
            for step in 0...20 {
                let progress = CGFloat(step) / 20
                #expect(RevealStage.fill(at: progress, carriesPage: fit.carriesPage) == 0,
                        "\(fit) showed its destination at \(progress)")
            }
        }
    }



    /// ⚠️ NOTHING OF THE DESTINATION IS SEEN WHILE THE FINGER IS DOWN.
    ///
    /// The arrival used to come up over the page during the drag, which put a
    /// card's text on screen laid out for a width the window had not reached —
    /// clipped at the window's edge, and filmed that way. The drag's whole job
    /// is the page leaving; the arrival is what the release buys.
    @Test func nothingArrivesWhileTheFingerIsDown() {
        for step in 0...100 {
            let progress = CGFloat(step) / 100
            #expect(RevealStage.fill(at: progress, carriesPage: true) == 0,
                    "the destination was on screen at \(progress)")
        }
        // A landing whose window IS a card-shaped slice of the page keeps the
        // three acts — there the morph is the transition.
        #expect(RevealStage.fill(at: 1, carriesPage: false) == 1)
    }

    /// And when it does arrive, exactly ONE alpha moves. Ramping the view and
    /// its content together renders the glyph at alpha squared — fading faster
    /// than the disc beneath it, which is the half-drawn overlay the blend law
    /// forbids.
    @Test func exactlyOneAlphaMovesWhenTheArrivalComes() {
        for step in 0...100 {
            #expect(RevealStage.contentOpacity(at: CGFloat(step) / 100, carriesPage: true) == 1)
        }
    }

    /// The page is WHOLE at the landing, under an arrival that has covered it:
    /// a source that fades meets an arrival that is rising and the two cross at
    /// nothing.
    @Test func theLandingPoseHasNoPageLeft() {
        let closed = RevealStage.closed(
            sourceRect: CGRect(x: 300, y: 500, width: 44, height: 44),
            radius: 22, anchor: nil, matchesAnchor: false,
            ridingFrom: CGRect(x: 0, y: 0, width: 402, height: 874),
            fit: .covering
        )
        #expect(closed.pageOpacity == 1, "the source may not fade — the arrival covers it")
        // And an abandoned grab hands a whole page back.
        #expect(RevealStage.open(container: UIView(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874)
        )).pageOpacity == 1)
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

/// Records what a geometry's destination was asked to install.
@MainActor
private final class SceneryBox {
    let anchor = CGRect(x: 16, y: 300, width: 370, height: 120)
    var veilCut: CGFloat?
    var bandAnchor: CGRect?

    func geometry(fit: RevealPageFit) -> RevealGeometry {
        RevealGeometry(
            sourceFrame: { _ in nil },
            sourceCornerRadius: 12,
            sourceFill: .white,
            sourceCaptionEnd: 40,
            installDestinationVeil: { [weak self] cut, _ in self?.veilCut = cut },
            installDestinationAuthorBand: { [weak self] anchor in self?.bandAnchor = anchor },
            sourceCaptionTop: 52,
            pageFit: fit
        )
    }
}

