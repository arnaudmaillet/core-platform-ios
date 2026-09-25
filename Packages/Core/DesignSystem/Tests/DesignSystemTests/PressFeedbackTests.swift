import Testing
import UIKit
@testable import DesignSystem

/// A control that gives under a press, springs back, and ticks on a tap — and a
/// surface that grows while held.
///
/// ⚠️ **THE DECISIONS ARE WHAT IS ASSERTED, BECAUSE THE DRAWING CANNOT BE
/// ASKED.** The press lives only in the render tree (additive layers, never the
/// model), and a test host that never renders computes no presentation layer.
/// What each touch DECIDED — pressed to what, released how, ticked or not — is
/// recorded by the feedback and read here. The one piece of the drawing that is
/// answerable, the held factor being on the layer by its key, is asked too.
///
/// ⚠️ **A CONTROL IS DRIVEN THROUGH `sendActions(for:)`,** which runs the very
/// actions `attach` registered — the events are the wiring under test. A plain
/// view is driven through its recogniser's own routines, the ones its
/// `touches…` overrides call, since no test can make a `UITouch`.
@MainActor
struct PressFeedbackTests {
    private func control(width: CGFloat = 80, height: CGFloat = 30) -> UIControl {
        UIControl(frame: CGRect(x: 0, y: 0, width: width, height: height))
    }

    // MARK: - The app-wide dim

    /// ⚠️ **THE APP'S ONE PRESS IS A SHRINK AND A SLIGHT FADE** (25 September
    /// 2026). The fade is held on the layer by its key while pressed, and gone
    /// with the release — and it is not motion, so Reduce Motion keeps it.
    @Test func aDimmingPressHoldsItsFadeUntilTheRelease() {
        let button = control()
        let feedback = PressFeedback.attach(to: button, sound: nil, dims: true, reducesMotion: { false })

        button.sendActions(for: .touchDown)
        #expect(feedback.debugIsDimmedOnTheLayer, "the dim is not on the layer")
        #expect(feedback.debugIsHeldOnTheLayer, "guard: the shrink is held too")
        #expect(button.alpha == 1, "the dim wrote the model")

        button.sendActions(for: .touchUpInside)
        #expect(!feedback.debugIsDimmedOnTheLayer, "the dim outlived the press")
    }

    @Test func underReduceMotionTheDimStaysAndNothingMoves() {
        let button = control()
        let feedback = PressFeedback.attach(to: button, sound: nil, dims: true, reducesMotion: { true })

        button.sendActions(for: .touchDown)
        #expect(feedback.debugIsDimmedOnTheLayer, "Reduce Motion took the dim, which is not motion")
        #expect(!feedback.debugIsHeldOnTheLayer, "something moved under Reduce Motion")
        button.sendActions(for: .touchCancel)
        #expect(!feedback.debugIsDimmedOnTheLayer)
    }

    @Test func aPressWithoutTheDimDoesNotFade() {
        let button = control()
        let feedback = PressFeedback.attach(to: button, reducesMotion: { false })
        button.sendActions(for: .touchDown)
        #expect(!feedback.debugIsDimmedOnTheLayer, "a press that did not ask to dim dimmed")
    }

    /// A view whose host already owns the touch (the page indicator's scrub)
    /// drives the same press by hand — no recogniser installed.
    @Test func aDrivenPressIsTheSamePressWithNoHook() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 60, height: 32))
        let feedback = PressFeedback.driven(by: view, dims: true, reducesMotion: { false })
        #expect(view.gestureRecognizers?.isEmpty ?? true, "a driven press installed a recogniser")
        #expect(PressFeedback.attached(to: view) === feedback)

        feedback.press()
        #expect(feedback.debugIsHeldOnTheLayer && feedback.debugIsDimmedOnTheLayer)
        feedback.release(asTap: false)
        #expect(!feedback.debugIsHeldOnTheLayer && !feedback.debugIsDimmedOnTheLayer)
        #expect(feedback.debugEvents.last == .released(tap: false, sprang: true), "\(feedback.debugEvents)")
    }

    // MARK: - A control

    @Test func aControlGivesUnderThePressAndTicksOnTheTap() throws {
        let button = control()
        let feedback = PressFeedback.attach(to: button, reducesMotion: { false })

        button.sendActions(for: .touchDown)
        let pressed = PressFeedback.pressedScale(for: button.bounds.size)
        #expect(feedback.debugEvents == [.pressed(scale: pressed)], "\(feedback.debugEvents)")
        #expect(feedback.isPressed)
        #expect(feedback.debugIsHeldOnTheLayer, "the held factor is not on the layer")

        button.sendActions(for: .touchUpInside)
        #expect(feedback.debugEvents.last == .released(tap: true, sprang: true), "\(feedback.debugEvents)")
        #expect(!feedback.isPressed)
        #expect(!feedback.debugIsHeldOnTheLayer, "the held factor outlived the press")
    }

    /// ⚠️ **A SCROLL THAT STARTS ON A CHIP CANCELS ITS TOUCH, AND MUST NOT
    /// TICK.** The scroller hands a drag to the scroll by cancelling the chip's
    /// tracking; that is `.touchCancel`, and it is a release with no sound.
    @Test func aPressTheScrollTakesAwaySpringsBackSilently() {
        let button = control()
        let feedback = PressFeedback.attach(to: button, reducesMotion: { false })

        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchCancel)

        #expect(feedback.debugEvents.last == .released(tap: false, sprang: true), "\(feedback.debugEvents)")
        #expect(!feedback.debugIsHeldOnTheLayer)
    }

    /// A finger that strays off a control lets it go, and pressing it again by
    /// coming back is a press like any other — UIButton's own highlight does
    /// exactly this.
    @Test func aFingerThatStraysLetsGoAndComingBackPressesAgain() {
        let button = control()
        let feedback = PressFeedback.attach(to: button, reducesMotion: { false })
        let pressed = PressFeedback.pressedScale(for: button.bounds.size)

        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchDragExit)
        button.sendActions(for: .touchDragEnter)
        button.sendActions(for: .touchUpInside)

        #expect(feedback.debugEvents == [
            .pressed(scale: pressed),
            .released(tap: false, sprang: true),
            .pressed(scale: pressed),
            .released(tap: true, sprang: true)
        ], "\(feedback.debugEvents)")
    }

    /// And one that strays and lifts outside is not a tap.
    @Test func aLiftOutsideIsNotATap() {
        let button = control()
        let feedback = PressFeedback.attach(to: button, reducesMotion: { false })

        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchDragExit)
        button.sendActions(for: .touchUpOutside)

        #expect(!feedback.debugEvents.contains(.released(tap: true, sprang: true)), "\(feedback.debugEvents)")
        #expect(!feedback.debugEvents.contains(.released(tap: true, sprang: false)), "\(feedback.debugEvents)")
    }

    /// ⚠️ **THE MODEL IS NOT TOUCHED — THAT IS THE DESIGN, NOT AN ACCIDENT.**
    /// Upload's band writes these same transforms to pop its elements in, and
    /// layout reads frames through them; a press that wrote the model would race
    /// the first and lie to the second.
    @Test func thePressNeverWritesTheModelTransform() {
        let button = control()
        button.transform = CGAffineTransform(scaleX: 0.76, y: 0.76)
        PressFeedback.attach(to: button, reducesMotion: { false })

        button.sendActions(for: .touchDown)

        #expect(button.transform == CGAffineTransform(scaleX: 0.76, y: 0.76),
                "the press overwrote a transform somebody else owns: \(button.transform)")
    }

    /// A clear control over what the author sees moves what they see.
    @Test func aControlCanMoveTheViewItStandsFor() {
        let chip = UIView(frame: CGRect(x: 0, y: 0, width: 56, height: 76))
        let button = UIButton(frame: chip.bounds)
        chip.addSubview(button)
        let feedback = PressFeedback.attach(to: button, moving: chip, reducesMotion: { false })

        button.sendActions(for: .touchDown)

        #expect(chip.layer.animation(forKey: "designSystem.pressFeedback.hold") != nil, "the chip does not give")
        #expect(button.layer.animation(forKey: "designSystem.pressFeedback.hold") == nil, "the clear button gives instead")
        #expect(feedback.debugEvents == [.pressed(scale: PressFeedback.pressedScale(for: chip.bounds.size))])
    }

    /// ⚠️ **REDUCE MOTION: NOTHING MOVES, AND THE TAP STILL TICKS.** The sound is
    /// not motion, and it is what says the tap was taken.
    @Test func underReduceMotionNothingMovesAndTheTapStillTicks() {
        let button = control()
        let feedback = PressFeedback.attach(to: button, reducesMotion: { true })

        button.sendActions(for: .touchDown)
        #expect(!feedback.debugIsHeldOnTheLayer, "something moved under Reduce Motion")
        button.sendActions(for: .touchUpInside)

        #expect(feedback.debugEvents == [.pressed(scale: 1), .released(tap: true, sprang: false)],
                "\(feedback.debugEvents)")
    }

    /// A control that already answers the finger (interactive glass) ticks and
    /// does nothing else.
    @Test func aControlThatMovesItselfOnlyTicks() {
        let button = control()
        let feedback = PressFeedback.attach(to: button, scales: false, reducesMotion: { false })

        button.sendActions(for: .touchDown)
        #expect(!feedback.debugIsHeldOnTheLayer)
        button.sendActions(for: .touchUpInside)

        #expect(feedback.debugEvents == [.pressed(scale: 1), .released(tap: true, sprang: false)],
                "\(feedback.debugEvents)")
    }

    @Test func theFeedbackIsFoundOnTheViewItWasAttachedTo() {
        let button = control()
        let plain = UIView()

        let onControl = PressFeedback.attach(to: button)
        let onView = PressFeedback.attach(toView: plain)

        #expect(PressFeedback.attached(to: button) === onControl)
        #expect(PressFeedback.attached(to: plain) === onView)
        #expect(PressFeedback.attached(to: UIView()) == nil)
    }

    // MARK: - A plain view

    /// ⚠️ **A `UIImageView` IS BORN IGNORING TOUCHES**, so a photograph's tile
    /// would never feel a finger: attaching has to turn them on.
    @Test func aPlainViewIsPressedThroughItsRecogniserAndTicksOnTheLift() throws {
        let tile = UIImageView(frame: CGRect(x: 0, y: 0, width: 117, height: 208))
        try #require(!tile.isUserInteractionEnabled, "guard: an image view starts deaf")
        let feedback = PressFeedback.attach(toView: tile, reducesMotion: { false })
        let recognizer = try #require(feedback.debugRecognizer as? PressGestureRecognizer)

        #expect(tile.isUserInteractionEnabled, "the tile still ignores touches")
        #expect(tile.gestureRecognizers?.contains(recognizer) == true)

        recognizer.debugTouchDown()
        recognizer.debugTouchUp()

        #expect(feedback.debugEvents == [
            .pressed(scale: PressFeedback.pressedScale(for: tile.bounds.size)),
            .released(tap: true, sprang: true)
        ], "\(feedback.debugEvents)")
    }

    /// ⚠️ **A DRAG TAKING THE TOUCH IS A RESET, NOT A CANCEL** — the only call a
    /// prevented recogniser gets — and it must release without a sound.
    @Test func aDragThatTakesTheTouchReleasesSilently() throws {
        let tile = UIView(frame: CGRect(x: 0, y: 0, width: 117, height: 208))
        let feedback = PressFeedback.attach(toView: tile, reducesMotion: { false })
        let recognizer = try #require(feedback.debugRecognizer as? PressGestureRecognizer)

        recognizer.debugTouchDown()
        recognizer.debugTakenByADrag()

        #expect(feedback.debugEvents.last == .released(tap: false, sprang: true), "\(feedback.debugEvents)")
        #expect(!feedback.isPressed)
    }

    @Test func aButtonLikeViewLetsGoWhenTheFingerLeavesIt() throws {
        let tile = UIView(frame: CGRect(x: 0, y: 0, width: 117, height: 208))
        let feedback = PressFeedback.attach(toView: tile, reducesMotion: { false })
        let recognizer = try #require(feedback.debugRecognizer as? PressGestureRecognizer)

        recognizer.debugTouchDown()
        recognizer.debugTouchMoved(inside: true)
        try #require(feedback.isPressed, "guard: moving inside is still pressing")
        recognizer.debugTouchMoved(inside: false)

        #expect(!feedback.isPressed)
        #expect(feedback.debugEvents.last == .released(tap: false, sprang: true), "\(feedback.debugEvents)")
    }

    /// ⚠️ **IT GIVES WAY TO SOMEBODY ELSE'S DRAG, NEVER TO A TAP, AND NEVER
    /// PREVENTS ANYTHING.** A scroller's pan takes the press away; the view's
    /// own pan (a ruler's) is the interaction it is for; a tap recognising
    /// beside it is the press completing.
    @Test func theRecogniserGivesWayOnlyToAnotherViewsDrag() throws {
        let host = UIView()
        let tile = UIView()
        host.addSubview(tile)
        let feedback = PressFeedback.attach(toView: tile)
        let recognizer = try #require(feedback.debugRecognizer)
        let scroll = UIPanGestureRecognizer()
        host.addGestureRecognizer(scroll)
        let own = UIPanGestureRecognizer()
        tile.addGestureRecognizer(own)
        let tap = UITapGestureRecognizer()
        tile.addGestureRecognizer(tap)
        // ⚠️ **AND A TAP ON AN ANCESTOR — THE CASE THAT IS REAL.** The
        // finalisation screen puts a keyboard-dismissing tap on the whole list,
        // and it recognises on every tap of a thumbnail; a press it could take
        // away would never tick there.
        let ancestorTap = UITapGestureRecognizer()
        host.addGestureRecognizer(ancestorTap)

        #expect(recognizer.canBePrevented(by: scroll), "a scroll would leave the press held")
        #expect(!recognizer.canBePrevented(by: own), "the view's own drag would end its own press")
        #expect(!recognizer.canBePrevented(by: tap), "a tap would swallow the tick")
        #expect(!recognizer.canBePrevented(by: ancestorTap), "an ancestor's tap would swallow the tick")
        #expect(!recognizer.canPrevent(scroll))
        #expect(!recognizer.canPrevent(tap))
        #expect(!recognizer.cancelsTouchesInView)
        #expect(!recognizer.delaysTouchesEnded)
    }

    // MARK: - A held surface

    /// A ruler grows while the finger is on it — dragged well past its bounds —
    /// and settles back without a sound when the finger lifts.
    @Test func aHeldSurfaceGrowsOutlastsItsBoundsAndIsSilent() throws {
        let ruler = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 56))
        let strip = UIView(frame: CGRect(x: 0, y: 22, width: 390, height: 34))
        ruler.addSubview(strip)
        let feedback = PressFeedback.attach(toView: ruler, style: .hold, moving: strip, reducesMotion: { false })
        let recognizer = try #require(feedback.debugRecognizer as? PressGestureRecognizer)

        recognizer.debugTouchDown()
        #expect(feedback.scale == PressFeedback.Metrics.heldScale, "held at \(feedback.scale)")
        #expect(strip.layer.animation(forKey: "designSystem.pressFeedback.hold") != nil, "the strip does not grow")
        recognizer.debugTouchMoved(inside: false)
        #expect(feedback.isPressed, "a drag past the ruler's edge let it go")
        recognizer.debugTouchUp()

        #expect(feedback.debugEvents == [
            .pressed(scale: PressFeedback.Metrics.heldScale),
            .released(tap: false, sprang: true)
        ], "\(feedback.debugEvents)")
        #expect(feedback.scale == 1)
    }

    // MARK: - The numbers

    /// ⚠️ **A DEPTH, HELD WITHIN BOUNDS.** Three points off each end of the
    /// longer side — a 26pt swatch would go to 0.77 and is held at 0.9; a 208pt
    /// tile would go to 0.971 and is held at 0.97.
    @Test func aPressIsTheSameFewPointsWhateverTheSize() {
        #expect(PressFeedback.pressedScale(for: CGSize(width: 26, height: 26)) == 0.9)
        #expect(abs(PressFeedback.pressedScale(for: CGSize(width: 80, height: 30)) - 0.925) < 0.0001)
        #expect(abs(PressFeedback.pressedScale(for: CGSize(width: 120, height: 30)) - 0.95) < 0.0001)
        #expect(PressFeedback.pressedScale(for: CGSize(width: 117, height: 208)) == 0.97)
        #expect(PressFeedback.pressedScale(for: .zero) == 0.97, "an element with no size must not vanish")
    }

    /// ⚠️ **THE RELEASE PASSES REST BY WHAT A BAND ELEMENT LANDS WITH,
    /// WHATEVER IT TRAVELLED.** The first overshoot of an underdamped spring is
    /// `travel × e^(−πζ/√(1−ζ²))`; asked at three travels, it must come out at
    /// `landingOvershoot` every time.
    @Test func theReleaseOvershootsByTheSameAmountWhateverItTravelled() {
        for travel: CGFloat in [0.03, 0.06, 0.1] {
            let damping = PressFeedback.releaseDampingRatio(travel: travel)
            let overshoot = travel * exp(-.pi * damping / (1 - damping * damping).squareRoot())
            #expect(abs(overshoot - PressFeedback.Metrics.landingOvershoot) < 0.0001,
                    "travel \(travel): ζ \(damping) overshoots by \(overshoot)")
        }
        #expect(PressFeedback.releaseDampingRatio(travel: 0.005) == 1, "a travel smaller than the overshoot rang")
    }
}
