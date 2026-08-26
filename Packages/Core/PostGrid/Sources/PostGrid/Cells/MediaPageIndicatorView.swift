import DesignSystem
import UIKit

/// Which page of a collection the preview is showing, as the middle chip of the
/// row that already carries the counters and the age.
///
/// ## A sliding window of dots, at any length
///
/// Dots always, because they are the carousel's universal signal and read
/// without being counted. A count — "3 / 14" — was tried and removed: it says
/// how many pages exist and nothing about WHERE you are, which is the one thing
/// an indicator over a photograph is for.
///
/// Fourteen dots would be a texture rather than a count, so at most five are
/// drawn and the window travels with the viewer. The outermost dot SHRINKS when
/// the run continues past it, on whichever side it continues — that is what
/// stops five dots claiming to be the whole gallery, and it is read without
/// being explained.
///
/// ## Why it is a chip at all
///
/// It sits on a photograph, between two chips that already solved that problem.
/// Bare dots over media need a shadow or a scrim to survive a bright frame, and
/// the row would then contain two things that answer the question differently.
/// Same ground, same rule.
public final class MediaPageIndicatorView: PostMetaPillView, HorizontalDragOwning {
    public static let dotDiameter: CGFloat = 6
    public static let dotSpacing: CGFloat = 5

    /// The viewer asked for a page, by tapping a dot or dragging across them.
    /// The HOST moves the carousel — an indicator that scrolled something for
    /// itself would be a second thing deciding where the pages are.
    public var onPageRequested: ((Int) -> Void)?

    /// Asks for the system's interactive glass instead of the card's flat
    /// ground.
    ///
    /// ⚠️ FOR THE POST SCREEN ONLY, and the distinction is the one this
    /// package's chip rule already draws. On a CARD the chip sits on the card's
    /// own fill, where a material resolves to that fill and disappears — which
    /// is why the card's chips carry a flat ground rather than a lens. Over a
    /// full-bleed photograph there IS something behind it, so glass is finally
    /// the honest answer: it takes its cue from the picture instead of pretending
    /// to a colour of its own.
    ///
    /// `isInteractive` is the system's own press response — the material flexes
    /// under a finger. That is the whole of the feedback; there is no scale or
    /// spring of ours near it, and there must not be: a transform on a glass
    /// lens is the thing this codebase already tried once and rejected.
    public func useInteractiveGlass() {
        prefersInteractiveGlass = true
        // ⚠️ Records the CHOICE, and does not put the ground up.
        //
        // It used to attach the glass on the spot, which is what a chip whose
        // capsule is always there wants. This one's appears under a finger (see
        // `showsGroundAtRest`), and attaching here would leave the post screen
        // the one surface still wearing a capsule at rest. A ground already up
        // — the preference arriving mid-scrub — is swapped for the glass rather
        // than left as the material it was.
        if effect != nil { effect = makeGround() }
    }

    private var prefersInteractiveGlass = false

    /// ⚠️ NO GROUND UNTIL A FINGER ARRIVES.
    ///
    /// Every other chip on these surfaces is a NUMBER, and a number over a
    /// photograph needs a floor to be legible on. The dots do not: they are
    /// their own contrast, drawn light with a shadow, and the capsule behind
    /// them was doing nothing except claiming — on a card that shows no other
    /// button — that something here can be pressed. Which is true, and is worth
    /// saying at the moment it becomes relevant rather than for the whole life
    /// of the row.
    ///
    /// So the ground fades in under the finger and back out when it leaves. On
    /// the post screen that ground is glass and on a card it is a material;
    /// both cross-fade the same way, because `effect` is animatable on a
    /// `UIVisualEffectView` and the chip IS one.
    override public var showsGroundAtRest: Bool { false }

    /// Fades the chip's ground in or out. Idempotent — the scrub flag it rides
    /// changes on every gesture edge and only some of those are transitions.
    private func setGroundShown(_ shown: Bool) {
        guard shown != (effect != nil), window != nil else { return }
        UIView.animate(
            withDuration: shown ? 0.18 : 0.28, delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            // ⚠️ Built INSIDE the animation, and only ever with a window: the
            // pill's own note records that attaching an effect off-screen
            // stalls a headless simulator for tens of seconds. A chip being
            // touched is on screen by definition.
            self.effect = shown ? self.makeGround() : nil
        }
    }

    /// The chip's own press response, for the surfaces that have no glass to
    /// give them one.
    ///
    /// ⚠️ ONLY WHERE THERE IS NO LENS. On the post screen the chip IS glass, and
    /// `isInteractive` already flexes the material under a finger — adding a
    /// transform there would be a second effect fighting the system's, and this
    /// codebase has already tried transforming a glass lens once and rejected
    /// it. On a card the chip is a flat capsule with no such response, so it
    /// gets one of its own: the same read, arrived at differently.
    private func applyPressFeedback() {
        guard !prefersInteractiveGlass else { return }
        UIView.animate(
            withDuration: 0.5, delay: 0,
            usingSpringWithDamping: 0.52, initialSpringVelocity: 0.9,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.transform = self.isScrubbing
                ? CGAffineTransform(scaleX: Self.pressedScale, y: Self.pressedScale)
                : .identity
        }
    }

    /// How far the card's chip swells under a finger.
    ///
    /// ⚠️ THIS IS NOT THE EXPANSION THAT WAS REJECTED. That one changed the
    /// chip's WIDTH, which re-laid the dots out: the target moved away from the
    /// finger that had just landed on it. A uniform scale about the centre
    /// magnifies the control without re-aiming it — and `location(in:)` reports
    /// through the transform, so the page under the finger is the page the
    /// arithmetic reads either way.
    private static let pressedScale: CGFloat = 1.26

    override public func makeGround() -> UIVisualEffect? {
        guard prefersInteractiveGlass else { return super.makeGround() }
        // Shape before material, for the reason `PagedTabBar` records: a glass
        // effect switched on over a layer that has not been given its radius
        // yet draws one frame of hard corners.
        layoutIfNeeded()
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        return glass
    }

    /// The scrub, exposed so a host can make its OWN pan yield to it.
    ///
    /// ⚠️ A LONG PRESS OF ZERO DURATION, NOT A PAN — and that is the whole
    /// reason dragging the chip did nothing while tapping it worked.
    ///
    /// A pan must see MOVEMENT before it begins, and every scroll view above
    /// this chip is watching for exactly the same movement. The feed's
    /// collection view is an ancestor; it claimed the drag every time, so the
    /// pan here never got past `.possible` and the chip only ever responded to
    /// taps.
    ///
    /// A long press with no minimum duration begins on TOUCH-DOWN, before any
    /// scroll view has anything to go on, and then reports `.changed` for every
    /// movement — which is a scrubber exactly. `allowableMovement` is lifted
    /// because the default cancels a long press that travels, and travelling is
    /// the point.
    public let scrubGesture: UILongPressGestureRecognizer = {
        let scrub = UILongPressGestureRecognizer()
        scrub.minimumPressDuration = 0
        scrub.allowableMovement = .greatestFiniteMagnitude
        return scrub
    }()

    private let dots = PageDotsView()
    private let label = UILabel()
    private var pageCount = 0
    private var currentPage = 0

    public init() {
        label.font = PostMetaPillView.font
        label.textColor = PostMetaPillView.foreground
        label.adjustsFontForContentSizeCategory = true
        // ⚠️ NO HORIZONTAL PADDING HERE; THE DOTS VIEW CARRIES IT INSTEAD.
        //
        // The chip is exactly as wide as it was — `PageDotsView` adds the same
        // 12pt back into its own intrinsic width — but the padding is now
        // INSIDE the dots view rather than around it, which is what gives a
        // dot leaving the window somewhere to go. See `PageDotsView.overhang`.
        super.init(
            contents: [dots, label], spacing: 0,
            insets: NSDirectionalEdgeInsets(
                top: PostMetaPillView.insets.top, leading: 0,
                bottom: PostMetaPillView.insets.bottom, trailing: 0
            )
        )
        // The one chip that IS a control. `PostMetaPillView` turns interaction
        // off because a counter that swallowed touches would put a dead corner
        // on the preview; this one has something to do with them.
        isUserInteractionEnabled = true
        // No separate tap: a zero-duration long press already fires `.began` on
        // touch-down and `.ended` on lift, which IS a tap — and a second
        // recognizer competing for the same touch is how the drag was lost in
        // the first place.
        scrubGesture.addTarget(self, action: #selector(handleTouch))
        addGestureRecognizer(scrubGesture)
        // ⚠️ NOTHING ELSE MAY CLAIM THIS TOUCH.
        //
        // The chip sits inside a carousel that pans and, on the post screen,
        // under a dismissal that pans too — and a scrub is a horizontal drag,
        // which is exactly what both are looking for. Whoever won the race got
        // it, so scrubbing sometimes paged the carousel and sometimes dismissed
        // the post.
        //
        // Two halves here: `cancelsTouchesInView` keeps the touch from reaching
        // the views underneath, and `isExclusiveTouch` keeps a second finger
        // from starting something else mid-scrub. The third cannot live here —
        // a recognizer on an ANCESTOR is blocked by neither, so hosts must make
        // theirs stand down. See `scrubGesture`.
        scrubGesture.cancelsTouchesInView = true
        isExclusiveTouch = true
        // ⚠️ This chip YIELDS horizontal space; the counters and the date do not.
        //
        // It is the only one of the four whose content can be shown partially
        // and still mean something — a window of dots still says "there are
        // more, you are here" — while half a count or half a date says nothing.
        // So it compresses first, down to the floor `PageDotsView` sets.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// - Parameters:
    ///   - count: how many pages the post has. One or zero hides the whole
    ///     chip — an indicator for a single page is furniture answering a
    ///     question nobody asked, and the chip row is already the busiest part
    ///     of the card.
    ///   - current: the page showing, clamped.
    public func configure(count: Int, current: Int) {
        pageCount = count
        isHidden = count < 2
        guard count >= 2 else { return }

        applyPresentation()
        setCurrent(current)
    }

    /// Dots or a count, decided in ONE place.
    ///
    /// ⚠️ Always dots, at every count. A "3 / 12" told the viewer how many pages
    /// there are and nothing about WHERE they are, which is the one thing an
    /// indicator over a photograph is for — and it read as a label bolted onto a
    /// row of chips rather than as part of the carousel. A sliding window of
    /// dots says both, at any length, in a fixed amount of room.
    /// chip shows "3 / 12", because a dozen dots squeezed into a corner is a
    /// smear that says less than the number does. But the moment a finger is on
    /// it the chip is not a label any more, it is the thing being dragged — and
    /// what it must show then is WHERE the pages are, which only dots can say.
    private func applyPresentation() {
        dots.isHidden = false
        label.isHidden = true
        dots.configure(count: pageCount)
    }



    /// Moves the mark without rebuilding, because this is called on every
    /// scroll callback of a carousel the viewer is dragging.
    public func setCurrent(_ current: Int) {
        guard pageCount >= 2 else { return }
        let page = min(max(current, 0), pageCount - 1)
        currentPage = page
        dots.setCurrent(page)
    }

    /// The viewer began or ended scrubbing.
    ///
    /// Reported out, like the page request, because what "expanded" costs is a
    /// LAYOUT decision — which neighbours must yield, and whether any need to at
    /// all — and only the row that owns those neighbours can make it.
    public var onScrubbingChanged: ((Bool) -> Void)?

    /// Whether a finger is on the chip right now.
    public private(set) var isScrubbing = false {
        didSet {
            guard isScrubbing != oldValue else { return }
            setGroundShown(isScrubbing)
            applyPressFeedback()
            onScrubbingChanged?(isScrubbing)
        }
    }

    @objc private func handleTouch(_ recognizer: UIGestureRecognizer) {
        handleScrub(recognizer.state, atX: recognizer.location(in: self).x)
    }

    /// The gesture's whole meaning, in one place a test can reach.
    ///
    /// ⚠️ TOUCHING IT ASKS FOR NOTHING; ONLY DRAGGING DOES.
    ///
    /// A press used to select the page under the finger, which put two meanings
    /// on one touch: a tap changed the page, and a tap that became a drag
    /// changed it twice — once to wherever it landed and again to wherever it
    /// went. The dots are narrow and sit between two counters, so the first of
    /// those was as often a miss as an instruction. Sliding is unambiguous: the
    /// page follows the finger, and letting go where you started leaves
    /// everything as it was.
    private func handleScrub(_ state: UIGestureRecognizer.State, atX x: CGFloat) {
        guard pageCount >= 2 else { return }
        switch state {
        case .began:
            isScrubbing = true
            anchor(at: x)
        case .changed:
            isScrubbing = true
            requestPage(draggedTo: x)
        case .ended, .cancelled, .failed:
            isScrubbing = false
        default:
            break
        }
    }

    /// ⚠️ THE PAGE YOU ARE ON IS WHERE THE DRAG STARTS FROM, wherever the
    /// finger lands.
    ///
    /// The touch used to be read ABSOLUTELY — the strip divided into as many
    /// bands as there are pages, and wherever you pressed is the page you got.
    /// Which meant putting a finger on the middle of the chip teleported a
    /// twelve-page post to page six before the drag had moved at all. The chip
    /// looked like a scrubber and behaved like a row of targets.
    ///
    /// So the touch-down point is an ORIGIN, not a coordinate: it pins the
    /// current page, and only movement from there asks for anything. Nothing
    /// jumps, and the dots track the finger.
    private func anchor(at x: CGFloat) {
        scrubAnchorX = x
        scrubAnchorPage = currentPage
        lastRequestedPage = currentPage
    }

    /// One dot's slot per page, which is what makes the gesture legible: the
    /// mark advances by exactly the distance between two dots, so the finger
    /// and the strip move at the same rate.
    ///
    /// The chip is only ~50pt of dots, which would cap a single stroke at four
    /// or five pages — except that the scrub is a long press with its movement
    /// limit lifted, so it keeps tracking well outside the chip. A drag across
    /// the screen covers thirty pages; the chip's width bounds what is DRAWN,
    /// never what is reachable.
    static var pointsPerPage: CGFloat { dotDiameter + dotSpacing }

    private var scrubAnchorX: CGFloat = 0
    private var scrubAnchorPage = 0
    private var lastRequestedPage: Int?

    private func requestPage(draggedTo x: CGFloat) {
        let travelled = Int(((x - scrubAnchorX) / Self.pointsPerPage).rounded())
        let raw = scrubAnchorPage + travelled
        let page = min(max(raw, 0), pageCount - 1)
        // ⚠️ RE-ANCHOR AT THE ENDS, or the gesture goes numb.
        //
        // Drag twenty pages past the last one and `raw` is twenty out of range.
        // Without this the finger would have to travel all twenty back before
        // the strip moved again — the control would feel stuck exactly when the
        // viewer is trying to correct an overshoot. Pinning the anchor to the
        // edge means the way back responds on the first slot.
        if raw != page {
            scrubAnchorPage = page
            scrubAnchorX = x
        }
        // Only when it CHANGES: `.changed` fires on every touch move, and the
        // host's answer to a page request is to scroll a carousel.
        guard page != lastRequestedPage else { return }
        lastRequestedPage = page
        onPageRequested?(page)
    }

    #if DEBUG
    /// Where the dots sit inside the chip — the runway is only real if the dots
    /// view actually reaches the capsule's ends.
    var debugDotsFrame: CGRect { dots.frame }

    /// Drives the scrub without a finger — the simulator injects none.
    ///
    /// Goes through `handleScrub`, not around it: a test that reimplemented the
    /// rule would pin a route nobody uses.
    func debugScrub(_ state: UIGestureRecognizer.State, atX x: CGFloat) {
        handleScrub(state, atX: x)
    }
    #endif

    /// The floor this chip may be compressed to: two dots and their runway.
    ///
    /// ⚠️ The padding is NOT added on top. It used to be — the chip held it and
    /// the dots view did not — but the dots view now spans it, so `minimumWidth`
    /// already counts it. Adding it again reserved 24pt of nothing and made the
    /// chip the last thing on the row to compress instead of the first.
    public var minimumChipWidth: CGFloat { dots.minimumWidth }
}

/// The dots themselves, laid out by hand so the chip can be narrower than its
/// content.
///
/// ⚠️ A WINDOW, not a clipped row. When the counters and the date take the
/// space, this shows as many dots as fit — centred on the current page — rather
/// than the first N. Clipping would hide exactly the dot the viewer is looking
/// for the moment there are more pages than room, which is when an indicator
/// starts earning its place.
///
/// Frames rather than a stack, for the reason the carousel uses frames: how many
/// dots are visible is a function of the WIDTH, and a stack's arranged subviews
/// cannot be added and removed inside a layout pass without fighting it.
final class PageDotsView: UIView {
    /// The floor: two dots. One dot says nothing a single page would not, and
    /// the chip has to keep saying "there is more than one" at every width.
    static let minimumVisibleDots = 2

    /// The window: five dots, at any length, at rest and under a finger alike.
    ///
    /// ⚠️ FIXED ON PURPOSE. The chip used to grow while being scrubbed, which
    /// meant the dots moved under the finger that had just landed on them — the
    /// scrub began with a jump, and the page it selected was not the page that
    /// had been under the thumb a frame earlier. A control whose targets move
    /// when you touch it cannot be aimed.
    ///
    /// So the width never changes and the WINDOW slides instead. Five, because
    /// four leaves only two full-size dots once both edges are shrunken, and two
    /// is not enough to read a position from.
    static let maximumVisibleDots = 5

    private var count = 0
    private var current = 0
    /// Which way the viewer last moved: +1 forward, -1 back, 0 before anyone
    /// has moved at all. See `currentSlot`.
    private var travelDirection = 0
    private var dots: [UIView] = []

    /// ⚠️ THE STRIP ENDS IN A FADE, NOT IN A CUT.
    ///
    /// Every dot keeps a frame on the strip so the window can SLIDE, which
    /// means a dot leaving the window has to cross the container's edge. Under
    /// a plain clip that edge is a blade: the dot went out as a half-moon, then
    /// a crescent, then nothing — a shape no dot ever has at rest, and the eye
    /// reads it as breakage rather than as travel.
    ///
    /// The mask is applied ONLY on a side the run actually continues past. A
    /// gallery that fits has nothing arriving or leaving, and fading its first
    /// and last dot would dim them for no reason at all.
    private let edgeFade = CAGradientLayer()

    /// ⚠️ THE RUNWAY EITHER SIDE OF THE WINDOW, and the fix to a dot being cut
    /// in half on its way out.
    ///
    /// A fade at the container's edge was not enough on its own: the dot was
    /// still travelling when it reached that edge, so it went out as a vertical
    /// slice — faint, but a straight line where a curve should be. Fading it
    /// harder would only have dimmed the dots that are meant to be READ.
    ///
    /// The room was already there, on the wrong side of the boundary. The chip
    /// pads its contents by 12pt, so the dots view used to stop 12pt short of
    /// the capsule's ends with nothing in between. Now the dots view spans that
    /// padding itself and lays its window out 12pt in, which leaves a dot a
    /// whole slot of runway to disappear over — outside the window, inside the
    /// view, and never near the edge while it is still visible.
    ///
    /// Taken FROM the chip's padding rather than added to it: the capsule is
    /// the same size it always was.
    static let overhang = PostMetaPillView.insets.leading

    /// The fade covers the runway exactly. A dot at rest is never touched by it
    /// — the window begins where the fade ends — and a dot leaving reaches zero
    /// as it reaches the edge.
    static var edgeFadeWidth: CGFloat { overhang }

    /// What the chip is: dots, plus the runway on both sides.
    static func chipWidth(forDots visible: Int) -> CGFloat {
        width(forDots: visible) + 2 * overhang
    }

    /// The part of the view the window is laid out in.
    private var windowWidth: CGFloat { max(bounds.width - 2 * Self.overhang, 0) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // Kept as the backstop: the mask decides how a dot LEAVES, the clip
        // guarantees nothing is ever drawn outside the chip.
        clipsToBounds = true
        edgeFade.startPoint = CGPoint(x: 0, y: 0.5)
        edgeFade.endPoint = CGPoint(x: 1, y: 0.5)
        edgeFade.colors = [
            UIColor.clear.cgColor, UIColor.white.cgColor,
            UIColor.white.cgColor, UIColor.clear.cgColor,
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(count: Int) {
        guard count != self.count else { return }
        self.count = count
        // ⚠️ A NEW POST HAS NOT BEEN TRAVELLED YET. Inherited from the row's
        // previous tenant, the direction would offset the window of a viewer
        // who has not touched this one — the recycled-cell fault this file's
        // neighbours have met in half a dozen other shapes.
        travelDirection = 0
        dots.forEach { $0.removeFromSuperview() }
        dots = (0..<count).map { _ in
            let dot = UIView()
            // ⚠️ THE DATE'S INK, because the dots stand on the same thing the
            // date does: a photograph.
            //
            // They were `PostMetaPillView.foreground` — a dark grey chosen for
            // a LIGHT material — which was right for exactly as long as there
            // was always a capsule under them. There is not: the ground now
            // arrives with the finger, so at rest these are dark marks on
            // whatever the picture happens to be, and on a dark frame they were
            // measured as invisible. A control nobody can see is a worse answer
            // than the capsule that was removed.
            //
            // Light fill plus a counter-toned halo is what `MediaDateInk`
            // already worked out for the same problem, and it holds under the
            // material too: that ground is translucent and follows the picture,
            // so ink that survives the picture survives the ground.
            dot.backgroundColor = MediaDateInk.colour
            dot.layer.shadowColor = MediaDateInk.halo.cgColor
            dot.layer.shadowOffset = .zero
            dot.layer.shadowRadius = MediaDateInk.haloRadius
            dot.layer.shadowOpacity = MediaDateInk.haloOpacity
            dot.layer.cornerRadius = MediaPageIndicatorView.dotDiameter / 2
            addSubview(dot)
            return dot
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func setCurrent(_ page: Int) {
        guard page != current else { return }
        let previousStart = Self.windowStart(
            current: current,
            visible: Self.visibleDots(in: windowWidth, count: count),
            count: count,
            direction: travelDirection
        )
        // ⚠️ REMEMBERED, because `layoutSubviews` decides the window too and the
        // two must agree. A direction computed here and forgotten would be
        // undone by the next unrelated layout pass — a rotation, a re-measure —
        // which would slide the row back to centre under a finger that has not
        // moved.
        travelDirection = page > current ? 1 : -1
        current = page
        // ⚠️ EVERYTHING — position, size and opacity — is decided in
        // `layoutSubviews` and nowhere else. Opacity was set here as well, and
        // two places deciding one dot's appearance is how an edge dot ended up
        // full-size and half-lit at the same time.
        let start = Self.windowStart(
            current: page,
            visible: Self.visibleDots(in: windowWidth, count: count),
            count: count,
            direction: travelDirection
        )
        // ⚠️ TWO DURATIONS, because two different things move.
        //
        // The mark passing between dots that stay put is a change of STATE; the
        // window travelling is a change of PLACE, and a place takes longer to
        // follow than a colour does. Both are springs — a dot that switches
        // colour and size on one frame reads as a light being flicked rather
        // than as a mark moving along a row, and a linear crossfade between two
        // greys reads as a dissolve rather than as something arriving.
        //
        // Neither is so long that the chip stops feeling attached to the finger:
        // the mark is where the finger is on the frame it gets there, and only
        // its APPEARANCE catches up.
        setNeedsLayout()
        let travelling = start != previousStart
        UIView.animate(
            withDuration: travelling ? 0.44 : 0.32, delay: 0,
            usingSpringWithDamping: travelling ? 0.72 : 0.9, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) { self.layoutIfNeeded() }
    }

    /// What the chip asks for when nothing is competing: every dot, and the
    /// runway either side of them.
    override var intrinsicContentSize: CGSize {
        CGSize(
            width: Self.chipWidth(forDots: min(count, Self.maximumVisibleDots)),
            height: MediaPageIndicatorView.dotDiameter
        )
    }

    /// The floor the chip may be compressed to.
    var minimumWidth: CGFloat { Self.chipWidth(forDots: Self.minimumVisibleDots) }

    static func width(forDots visible: Int) -> CGFloat {
        guard visible > 0 else { return 0 }
        let diameter = MediaPageIndicatorView.dotDiameter
        let spacing = MediaPageIndicatorView.dotSpacing
        return CGFloat(visible) * diameter + CGFloat(visible - 1) * spacing
    }

    /// How many dots fit in `width`, never fewer than the floor and never more
    /// than there are pages.
    static func visibleDots(in width: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let diameter = MediaPageIndicatorView.dotDiameter
        let spacing = MediaPageIndicatorView.dotSpacing
        let fitted = Int(floor((width + spacing) / (diameter + spacing)))
        return min(count, max(fitted, minimumVisibleDots))
    }

    /// Which slot of the window the current page occupies, given the direction
    /// the viewer is travelling.
    ///
    /// ⚠️ THE WINDOW TRAILS THE GESTURE — it does not centre on it.
    ///
    /// Centred, the mark never moves: every page change slides the whole row
    /// under a dot that stays put in the middle, so the thing that is actually
    /// happening — the viewer moving ALONG the run — is the one thing the
    /// indicator does not show. Trailing, the mark sits toward the edge it is
    /// heading for and the row behind it stays put, which reads as travel.
    ///
    /// Moving forward the current page is the fourth of five, moving back the
    /// second — one slot either side of the middle, so a direction change costs
    /// two slots of travel rather than a jump across the window. At rest
    /// (`direction` 0, which is only ever the first layout) it is centred, the
    /// only honest answer before anyone has moved.
    ///
    /// Clamped into the window, because a narrow chip can be three dots wide
    /// and "one past the middle" of three is the last one — and of two, off the
    /// end entirely.
    static func currentSlot(visible: Int, direction: Int) -> Int {
        min(max(visible / 2 + direction, 0), max(visible - 1, 0))
    }

    /// The first dot of the window, chosen so the current page sits in its
    /// direction-dependent slot and the window never runs off either end.
    static func windowStart(current: Int, visible: Int, count: Int, direction: Int = 0) -> Int {
        guard count > visible else { return 0 }
        return min(max(current - currentSlot(visible: visible, direction: direction), 0),
                   count - visible)
    }

    /// How small an edge dot goes when the run continues past it.
    ///
    /// ⚠️ THE ONLY THING THAT SAYS "THERE IS MORE", now that the chip no longer
    /// grows. A window of five identical dots is a lie at page one of twelve —
    /// it says "five pages, you are on the first". A shrunken dot at the edge
    /// says the run is cut off there, and the eye reads it without being told.
    static let edgeDotScale: CGFloat = 0.55

    /// The step between `edgeDotScale` and full size, worn by the dot one in
    /// from each continuing end.
    ///
    /// Half way in AREA rather than in diameter, which is what the eye reads:
    /// the dots are filled circles, so a linear midpoint between the two
    /// diameters looks closer to the small one than to the large. `sqrt` of the
    /// mid-area lands where "half way between them" actually looks.
    static let penultimateDotScale: CGFloat = ((edgeDotScale * edgeDotScale + 1) / 2).squareRoot()

    /// The drawn size of each VISIBLE dot, in order — how a test asks which
    /// ones were cut without reading the layout arithmetic back to itself.
    var debugDotSizes: [CGFloat] {
        dots.filter { $0.alpha > 0 }.map(\.frame.width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !dots.isEmpty else { return }
        let visible = Self.visibleDots(in: windowWidth, count: count)
        let start = Self.windowStart(
            current: current, visible: visible, count: count, direction: travelDirection
        )
        let diameter = MediaPageIndicatorView.dotDiameter
        let spacing = MediaPageIndicatorView.dotSpacing
        // Centred in whatever width the row left: a window narrower than the
        // chip would otherwise sit against one edge and read as misaligned.
        let used = Self.width(forDots: visible)
        let originX = ((bounds.width - used) / 2).rounded()
        let centreY = (bounds.height / 2).rounded()
        for (index, dot) in dots.enumerated() {
            let offset = index - start
            // ⚠️ A SLOT PAST THE WINDOW IS STILL POSITIONED, not hidden.
            //
            // The dots SLIDE when the window moves, and a dot that pops into
            // existence at the edge cannot slide in from anywhere. Every dot
            // keeps a frame on the strip; the chip clips, so the ones outside
            // simply are not seen — and when the window shifts they travel in
            // from where they already were.
            let isVisible = offset >= 0 && offset < visible
            // ⚠️ THE RUN TAPERS OVER TWO DOTS, not one.
            //
            // The outermost dot shrinking says "there is more past here"; the
            // one beside it, at an intermediate size, says how the row is
            // GOING. A single step from full size to the smallest reads as a
            // dot that has been cut off, and one taper on each end reads as a
            // row that continues — the same information, told as a slope
            // instead of a cliff.
            //
            // Both tiers are conditional on the same thing: the run continuing
            // past that end. A window sitting on the true first or last page
            // tapers on one side only, because on the other there is genuinely
            // nothing more.
            let continuesBefore = start > 0
            let continuesAfter = start + visible < count
            // ⚠️ THE MARK NEVER TAPERS, wherever the window happens to put it.
            //
            // The taper says "the run continues past here"; the mark says
            // "you are here". Shrinking the second to tell you the first
            // trades the one thing the indicator exists for against a hint
            // its neighbours are already giving — and the two collide
            // constantly rather than rarely, because the window trails the
            // gesture: the current page sits one slot in from an end, which is
            // exactly the slot the taper's second step lands on.
            let scale: CGFloat
            if index == current {
                scale = 1
            } else {
                switch offset {
                case 0 where continuesBefore, visible - 1 where continuesAfter:
                    scale = Self.edgeDotScale
                case 1 where continuesBefore, visible - 2 where continuesAfter:
                    scale = Self.penultimateDotScale
                default:
                    scale = 1
                }
            }
            // ⚠️ SCALED BY TRANSFORM, NEVER BY RESIZING.
            //
            // A dot laid out at a smaller SIZE needs a smaller corner radius to
            // stay round, and `cornerRadius` is a layer property: it lands on
            // the next frame while the size springs over a quarter of a second.
            // A dot on its way in or out went briefly square. A transform
            // carries the curve with it, so the dot is a circle the whole way.
            dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            dot.transform = CGAffineTransform(scaleX: scale, y: scale)
            dot.center = CGPoint(
                x: originX + CGFloat(offset) * (diameter + spacing) + diameter / 2,
                y: centreY
            )
            dot.alpha = isVisible ? (index == current ? 1 : 0.35) : 0
        }
        applyEdgeFade(start: start, visible: visible)
    }

    /// Softens whichever ends have somewhere to arrive from.
    private func applyEdgeFade(start: Int, visible: Int) {
        let leading = start > 0
        let trailing = start + visible < count
        guard leading || trailing, bounds.width > 0 else {
            layer.mask = nil
            return
        }
        layer.mask = edgeFade
        edgeFade.frame = bounds
        let fade = Self.edgeFadeWidth / bounds.width
        edgeFade.locations = [
            0,
            NSNumber(value: Double(leading ? fade : 0)),
            NSNumber(value: Double(trailing ? 1 - fade : 1)),
            1,
        ]
    }

    /// How far in the fade reaches at each end, IN POINTS — so a test can ask
    /// whether it overlaps a dot rather than read a gradient's stops back to
    /// itself.
    var debugFadeExtent: (leading: CGFloat, trailing: CGFloat) {
        guard layer.mask === edgeFade,
              let stops = edgeFade.locations?.map(\.doubleValue), stops.count == 4
        else { return (0, 0) }
        return (CGFloat(stops[0...1].max() ?? 0) * bounds.width,
                CGFloat(1 - (stops[2...3].min() ?? 1)) * bounds.width)
    }

    /// Which ends are faded at all.
    var debugEdgeFade: (leading: Bool, trailing: Bool) {
        let extent = debugFadeExtent
        return (extent.leading > 0, extent.trailing > 0)
    }

    /// Where the visible dots actually sit, so a test can check they are clear
    /// of both the fade and the edge.
    var debugDotFrames: [CGRect] {
        dots.filter { $0.alpha > 0 }.map(\.frame)
    }

    /// Every dot's frame, INCLUDING the ones parked outside the window — which
    /// is the set that matters when the question is whether anything is being
    /// cut, since a dot on its way out is exactly a dot that is no longer in it.
    var debugAllDotFrames: [CGRect] {
        dots.map(\.frame)
    }
}
