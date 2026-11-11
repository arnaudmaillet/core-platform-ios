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

    // MARK: - The swell: the ground grows, the content scales evenly (#2284)

    /// A swelling control drawn as a button is: a capsule ground (with a fill
    /// laid on all of it, and something smaller inside it) under a label.
    private func swellingButton(
        width: CGFloat, height: CGFloat, reduced: Bool = false
    ) -> (button: UIControl, ground: UIView, fill: CALayer, inner: CALayer, label: UILabel, feedback: PressFeedback) {
        let button = control(width: width, height: height)
        let ground = UIView(frame: button.bounds)
        ground.layer.cornerRadius = height / 2
        let fill = CALayer()
        fill.frame = ground.bounds
        fill.cornerRadius = height / 2
        ground.layer.addSublayer(fill)
        let inner = CALayer()
        inner.frame = ground.bounds.insetBy(dx: 10, dy: 10)
        ground.layer.addSublayer(inner)
        button.addSubview(ground)
        let label = UILabel(frame: button.bounds.insetBy(dx: 20, dy: 14))
        button.addSubview(label)
        let feedback = PressFeedback.attach(to: button, style: .swell, sound: nil, reducesMotion: { reduced })
        feedback.grounds = { [ground.layer] }
        return (button, ground, fill, inner, label, feedback)
    }

    /// The split: the content's one factor is the ground's across factor,
    /// and the ground's growth under it brings the ground drawn to the
    /// swell's two factors — the same few points whatever the width.
    @Test(arguments: [
        CGSize(width: 361, height: 52), CGSize(width: 329, height: 50), CGSize(width: 96, height: 32),
        CGSize(width: 80, height: 36), CGSize(width: 44, height: 44),
    ])
    func theSwellSplitsIntoAnEvenContentAndAGrowingGround(_ size: CGSize) {
        let swell = PressFeedback.swell(for: size)
        let ground = PressFeedback.swelledScale(for: size)
        #expect(swell.content == ground.x, "the content's factor is the across one")
        let drawn = CGSize(
            width: (size.width + swell.groundGrowth.width) * swell.content,
            height: (size.height + swell.groundGrowth.height) * swell.content
        )
        #expect(abs(drawn.width - size.width * ground.x) < 0.001)
        #expect(abs(drawn.height - size.height * ground.y) < 0.001)
        #expect(abs((drawn.width - size.width) - 2 * PressFeedback.Metrics.swellAcross * size.height) < 0.001
                || size.width == size.height, "\(size): not the same points across")
        #expect(abs((drawn.height - size.height) - 2 * PressFeedback.Metrics.swellDown * size.height) < 0.001)
        #expect(swell.groundGrowth.width == 0, "the even scale already takes the ground across")
    }

    /// At the crest, a wide button's content is held at ONE factor on both
    /// axes, and its ground — the fill laid on it with it — has grown by the
    /// swell's points across and down, a capsule still; what sits inside the
    /// ground is not stretched to it. Released, the growth springs back.
    @Test func aWideButtonsContentScalesEvenlyWhileItsGroundGrows() throws {
        let (button, ground, fill, inner, label, feedback) = swellingButton(width: 361, height: 52)
        button.sendActions(for: .touchDown)

        let held = try #require(PressFeedback.debugHeldScale(on: button.layer))
        #expect(held.x == held.y, "the content is stretched: \(held)")
        #expect(abs(held.x - (1 + 2 * PressFeedback.Metrics.swellAcross * 52 / 361)) < 0.0001)
        #expect(feedback.scale == held.x)

        let grown = try #require(PressFeedback.debugHeldGround(on: ground.layer))
        let drawn = CGSize(width: grown.size.width * held.x, height: grown.size.height * held.y)
        #expect(abs((drawn.width - 361) - 2 * PressFeedback.Metrics.swellAcross * 52) < 0.01, "across: \(drawn)")
        #expect(abs((drawn.height - 52) - 2 * PressFeedback.Metrics.swellDown * 52) < 0.01, "down: \(drawn)")
        #expect(abs(grown.cornerRadius - grown.size.height / 2) < 0.001, "the capsule's ends turned oval")
        let filled = try #require(PressFeedback.debugHeldGround(on: fill))
        #expect(filled.size == grown.size && filled.cornerRadius == grown.cornerRadius, "the fill did not grow with its ground")
        #expect(PressFeedback.debugHeldGround(on: inner) == nil, "what sits inside the ground was stretched to it")
        #expect(PressFeedback.debugHeldGround(on: label.layer) == nil, "the content's size grew")
        #expect(ground.bounds.size == CGSize(width: 361, height: 52), "the swell wrote the model")

        button.sendActions(for: .touchUpInside)
        #expect(PressFeedback.debugHeldGround(on: ground.layer) == nil, "the growth outlived the press")
        #expect(PressFeedback.debugHeldGround(on: fill) == nil)
        #expect(feedback.debugEvents.last == .released(tap: false, sprang: true))
    }

    /// A bubble is square: its ground and its content scale alike, by the
    /// swell's one factor, and nothing grows on top — it swells as it did.
    @Test func aBubblesGroundAndContentScaleAlike() throws {
        let (button, ground, _, _, _, feedback) = swellingButton(width: 44, height: 44)
        button.sendActions(for: .touchDown)
        let held = try #require(PressFeedback.debugHeldScale(on: button.layer))
        let swelled = PressFeedback.swelledScale(for: CGSize(width: 44, height: 44))
        #expect(held.x == swelled.x && held.y == swelled.y && held.x == held.y)
        #expect(PressFeedback.debugHeldGround(on: ground.layer) == nil, "a square's ground grew past its content")
        #expect(feedback.debugGrownGrounds.isEmpty)
    }

    /// A stand-in taking the button's place (`AppButton`'s content change)
    /// follows the content's factor, not the ground's — whether it is there
    /// when the finger lands or takes over mid-press — and its own layer, the
    /// ground's shape, grows as the ground does.
    @Test func aStandInFollowsTheContentsFactor() throws {
        let (button, ground, _, _, _, feedback) = swellingButton(width: 329, height: 50)
        let early = CALayer()
        early.frame = button.bounds
        early.cornerRadius = 25
        feedback.mirrors = [early]
        button.sendActions(for: .touchDown)
        let late = CALayer()
        late.frame = button.bounds
        late.cornerRadius = 25
        feedback.copyPress(to: late)

        let held = try #require(PressFeedback.debugHeldScale(on: button.layer))
        let grown = try #require(PressFeedback.debugHeldGround(on: ground.layer))
        for (name, mirror) in [("early", early), ("late", late)] {
            let scale = try #require(PressFeedback.debugHeldScale(on: mirror), "\(name): not scaled")
            #expect(scale.x == held.x && scale.y == held.y, "\(name): \(scale) against \(held)")
            let mirrored = try #require(PressFeedback.debugHeldGround(on: mirror), "\(name): its ground did not grow")
            #expect(mirrored.size == grown.size && mirrored.cornerRadius == grown.cornerRadius, "\(name)")
        }
        button.sendActions(for: .touchUpInside)
        #expect(PressFeedback.debugHeldGround(on: late) == nil, "the stand-in's growth outlived the press")
    }

    /// Under Reduce Motion a swell moves nothing: no scale, no growth.
    @Test func underReduceMotionASwellMovesNothing() {
        let (button, ground, fill, _, _, feedback) = swellingButton(width: 361, height: 52, reduced: true)
        button.sendActions(for: .touchDown)
        #expect(!feedback.debugIsHeldOnTheLayer)
        #expect(PressFeedback.debugHeldGround(on: ground.layer) == nil && PressFeedback.debugHeldGround(on: fill) == nil)
        #expect(feedback.scale == 1)
    }

    /// A corner rule: a capsule stays a capsule as it grows; a card keeps
    /// its corner.
    @Test func aCapsuleStaysACapsuleAndACardKeepsItsCorner() {
        let size = CGSize(width: 300, height: 50)
        let growth = CGSize(width: 0, height: 7)
        #expect(PressFeedback.grownCornerRadius(25, of: size, by: growth) == 28.5)
        #expect(PressFeedback.grownCornerRadius(12, of: size, by: growth) == 12)
        #expect(PressFeedback.grownCornerRadius(0, of: size, by: growth) == 0)
    }
}
