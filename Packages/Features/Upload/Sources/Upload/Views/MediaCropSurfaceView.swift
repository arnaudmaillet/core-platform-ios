import DesignSystem
import UIKit

/// The shape a crop is held to.
///
/// ⚠️ **`free` IS A STATE, NOT AN ABSENT ONE.** With no ratio the handles move
/// each edge on its own; with one, they keep the shape and only change how much
/// is kept. Spelling the free case makes the row of chips say which mode is on,
/// which a `nil` cannot.
enum CropRatio: CaseIterable {
    case free, original, square, portrait, classic, tall, wide

    var name: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .portrait: "4:5"
        case .classic: "3:4"
        case .tall: "9:16"
        case .wide: "16:9"
        }
    }

    /// Nil for `free`, which asks the box to keep whatever shape it was dragged
    /// into. `original` needs the picture to answer at all, which is why this
    /// takes the source rather than being a stored number.
    func value(for source: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: source.height > 0 ? source.width / source.height : nil
        case .square: 1
        case .portrait: 4.0 / 5.0
        case .classic: 3.0 / 4.0
        case .tall: 9.0 / 16.0
        case .wide: 16.0 / 9.0
        }
    }
}

/// The editing surface for a crop: the picture, movable under a fixed box.
///
/// ```
/// ┌─────────────────────────────┐
/// │   ░░░░░░░░░░░░░░░░░░░░░░░   │  ← what is being cut away, dimmed
/// │   ░┌───┬───┬───┐░░░░░░░░░   │
/// │   ░├───┼───┼───┤░  the box  │
/// │   ░└───┴───┴───┘░░░░░░░░░   │
/// └─────────────────────────────┘
/// ```
///
/// ⚠️ **THE BOX STANDS STILL AND THE PICTURE MOVES — THE PHOTOS MODEL, AND THE
/// ONE THE ARITHMETIC IS WRITTEN FOR.** The alternative, a box dragged over a
/// stationary picture, needs a second coordinate system for the kept rectangle
/// and gives the viewer no way to enlarge a detail. Every rule lives in
/// `MediaCropGeometry`; this view owns touches and nothing else.
///
/// ⚠️ **BESPOKE PAN AND PINCH, NOT A `UIScrollView` — A DEPARTURE FROM THE TWO
/// SCROLL-VIEW SUBCLASSES IN THIS FILE'S NEIGHBOURHOOD, STATED ON PURPOSE.** A
/// scroll view would hand over pan and pinch already arbitrated, which is the
/// reason to reach for one. It cannot hold this model: the picture is ROTATED,
/// so a scroll view would have to be rotated with it and its `contentSize`,
/// `contentOffset` and zoom bounds recomputed on every degree — three derived
/// quantities to keep honest instead of the one `CropPlacement` that is already
/// proven against the renderer. What a scroll view was going to buy is bought
/// instead by the three lines in `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)`
/// and by the host suspending the canvas and the stack for the duration.
@MainActor
final class MediaCropSurfaceView: UIView {
    private enum Metrics {
        /// Room around the box, so a corner handle is reachable at the screen's
        /// edge and the dimmed remainder is visibly a remainder.
        static let margin: CGFloat = Spacing.lg
        /// ⚠️ A FINGER, NOT THE INK. The bracket drawn in a corner is a few
        /// points wide; this is what may be taken hold of.
        static let reach: CGFloat = 44
        static let settle: TimeInterval = 0.25
    }

    /// Announced whenever the author has finished a move — never mid-drag, since
    /// the surface itself is the preview and the host's only use for the value is
    /// to store it and re-render the page on the way out.
    var onChange: ((MediaCrop) -> Void)?

    private(set) var crop: MediaCrop = .untouched
    private(set) var ratio: CropRatio = .free

    /// ⚠️ **THE PREVIEW'S SIZE, AND ONLY ITS PROPORTIONS MATTER.** The picture
    /// being edited is a canvas-sized render, not the photograph that will be
    /// published — but `MediaCrop` is fractions, and the arithmetic is invariant
    /// under a change of unit: doubling the source halves the scale and leaves
    /// every fraction where it was. Proven in `MediaCropGeometryTests`.
    private var source: CGSize = CGSize(width: 1, height: 1)

    private var placement = CropPlacement(centre: .zero, scale: 1, angle: 0)
    private var box: CGRect = .zero
    private var quarters = 0
    private var fine: CGFloat = 0
    private var isMirrored = false

    private let picture = UIImageView()
    private let dimming = UIView()
    private let hole = CAShapeLayer()
    private let outline = CropFrameView()

    private var grip: MediaCropGeometry.Grip = []
    private var isGesturing = false
    /// Guards the derivation in `layoutSubviews`: re-deriving from `crop` while a
    /// finger is down would fight the finger.
    private var laidOutFor: CGRect = .zero

    private lazy var drag = UIPanGestureRecognizer(target: self, action: #selector(dragged))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))

    init() {
        super.init(frame: .zero)
        // The editor's own ground, which follows the device's appearance; anything
        // else would read as a panel laid over the picture rather than as the
        // screen the picture is being edited on.
        backgroundColor = .systemBackground
        clipsToBounds = true

        picture.contentMode = .scaleToFill
        addSubview(picture)

        // ⚠️ **THE SCRIM IS THE GROUND, NOT BLACK.** It covers the picture outside
        // the box AND the bare margins beside it. A black scrim over a white ground
        // makes those margins mid-grey, which reads as a panel nobody placed;
        // dimming TOWARDS the ground washes the discarded picture out to the same
        // colour the margins already are.
        dimming.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.55)
        dimming.isUserInteractionEnabled = false
        hole.fillRule = .evenOdd
        dimming.layer.mask = hole
        addSubview(dimming)

        outline.isUserInteractionEnabled = false
        addSubview(outline)

        drag.delegate = self
        pinch.delegate = self
        addGestureRecognizer(drag)
        addGestureRecognizer(pinch)

        isAccessibilityElement = true
        accessibilityLabel = "Crop"
        accessibilityHint = "Drag to move the picture, pinch to zoom, drag a corner to change the crop"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The area the box may occupy.
    ///
    /// ⚠️ **THE VIEW IS FULL-BLEED AND THE BOX IS NOT — AND THAT SEPARATION IS
    /// WHAT MAKES THE TRANSITION SAFE.** The surface used to be inset to the safe
    /// area itself, which left the canvas's own copy of the picture showing in the
    /// band above it and, worse, meant the two had to be crossfaded against each
    /// other: for one frame neither was opaque and the screen went black
    /// (measured, frame by frame, on a recording). Spanning the whole view makes
    /// this view opaque over everything it replaces, so the canvas can simply be
    /// hidden underneath it once the fade is done. The CHROME is kept off the box
    /// by `safeAreaInsets` instead.
    private var surface: CGRect {
        bounds.inset(by: safeAreaInsets).insetBy(dx: Metrics.margin, dy: Metrics.margin)
    }

    /// ⚠️ THE BOX IS DERIVED FROM THE SAFE AREA, so it has to be re-derived when
    /// the safe area arrives — which is AFTER the first layout pass on a view that
    /// has just been added to a hierarchy.
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        laidOutFor = .zero
        setNeedsLayout()
    }

    // MARK: - What is being edited

    /// Hands over a picture and the crop it already carries.
    func show(_ image: UIImage?, crop: MediaCrop, ratio: CropRatio = .free) {
        picture.image = image
        source = image.map { size in
            size.size.width > 0 && size.size.height > 0 ? size.size : CGSize(width: 1, height: 1)
        } ?? CGSize(width: 1, height: 1)
        self.crop = crop
        self.ratio = ratio
        let split = MediaCropGeometry.split(crop.angle)
        quarters = split.quarters
        fine = split.fine
        isMirrored = crop.isMirrored
        placement.isMirrored = crop.isMirrored
        laidOutFor = .zero
        // ⚠️ **LAID OUT NOW, NOT AT THE NEXT PASS.** Until the box is re-derived
        // from this picture it is still the one derived from the PLACEHOLDER the
        // surface was holding — a one-point square — and the host enables touches
        // the moment this returns. One frame is enough for a finger already on the
        // glass to resize a box that belongs to nothing. It also makes the box
        // readable immediately, which is what a test needs to see.
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The fine straightening, from the dial.
    ///
    /// ⚠️ **THIS ANNOUNCES, AND `turn()` DOES NOT.** A dial drag is sixty of
    /// these a second and each one is a different photograph; the host has to be
    /// told, or letting go of the dial would leave the stored crop at whatever
    /// the last SETTLED gesture said. The arithmetic is a handful of
    /// multiplications, so announcing per frame costs nothing — what would cost
    /// is re-rendering per frame, and nothing here does that.
    func setAngle(_ degrees: CGFloat) {
        fine = degrees
        turn()
        emit()
    }

    /// The picture as its own reflection, left for right.
    ///
    /// ⚠️ **THE BOX DOES NOT MOVE AND THE PICTURE DOES NOT SHIFT.** A reflection
    /// about the picture's own centre maps its rectangle onto itself, so what the
    /// box frames is the mirror of what it framed — no clamp is needed and no
    /// scale changes. Only the content under the frame is different, which is the
    /// whole point.
    func flipAcross() {
        isMirrored.toggle()
        placement.isMirrored = isMirrored
        UIView.transition(
            with: picture, duration: 0.22,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
        ) {
            self.apply()
        }
        emit()
    }

    /// A quarter turn clockwise.
    ///
    /// ⚠️ **IT WRAPS, AND WITHOUT THE WRAP FOUR TAPS WERE NOT A NO-OP.** Turning
    /// four times leaves the picture exactly where it began and the kept rectangle
    /// at the whole frame — but the stored angle was 360, and `snapped` requires
    /// an angle of exactly zero before it will call a crop untouched. So the entry
    /// survived in `edits`, undo stayed lit, the finalisation screen paid for a
    /// full-resolution render, and the post carried a 360° rotation of a
    /// photograph nobody had turned.
    func turnQuarter() {
        quarters = (quarters + 1) % 4
        turn()
        emit()
    }

    private func turn() {
        guard surface.width > 0, box.width > 0 else { return }
        let whole = MediaCropGeometry.whole(quarters: quarters, fine: fine)
        let pivot = CGPoint(x: box.midX, y: box.midY)
        placement = MediaCropGeometry.covering(
            MediaCropGeometry.turning(
                placement, to: whole, about: pivot, coveringBox: box, source: source
            ),
            source: source, box: box
        )
        apply()
    }

    /// Back to the whole picture, unturned.
    func reset() {
        quarters = 0
        fine = 0
        isMirrored = false
        placement.isMirrored = false
        crop = .untouched
        ratio = .free
        laidOutFor = .zero
        setNeedsLayout()
        layoutIfNeeded()
        emit()
    }

    /// Holds the box to a shape.
    ///
    /// ⚠️ **THE SHAPE IS MEASURED FROM THE WHOLE PICTURE EVERY TIME, NEVER FROM
    /// THE RECTANGLE THE LAST SHAPE LEFT — REPORTED, AND THE REPORT WAS RIGHT.**
    /// This used to settle the existing placement with `covering`, which only
    /// ever enlarges: 1:1 then 4:5 kept the taller shape's scale, and coming back
    /// to 1:1 framed 48% of the photograph where the first tap had framed 75%.
    /// Playing with the chips zoomed in further and further and nothing gave the
    /// room back. `filling` derives the scale and the centre from the picture
    /// alone, so the same tap is always the same rectangle — the largest one of
    /// that shape the picture can give, centred on the picture rather than on
    /// whatever the author had framed.
    ///
    /// ⚠️ **AND THAT COSTS THE AUTHOR'S OWN ZOOM, DELIBERATELY — IT IS THE ONE
    /// THING THAT CANNOT BE BOTH KEPT AND IDEMPOTENT.** A turn keeps it
    /// (`MediaCropGeometry.zoom`) because a turn adjusts the framing the author
    /// is holding; a chip is an absolute statement about shape, and the accrued
    /// zoom IS the defect. Carrying the centre instead of recentring fails for
    /// the same reason one step later: each shape clamps the slide to its own
    /// room, and `min(min(x, roomB), roomA)` is not `min(x, roomA)` for a picture
    /// the author has panned.
    ///
    /// "Free" returns before any of it, which is what keeps it meaning the
    /// author's own rectangle rather than a shape in disguise.
    func choose(_ newRatio: CropRatio) {
        ratio = newRatio
        guard surface.width > 0 else { return }
        guard let value = newRatio.value(for: turnedSource) else { return }
        box = MediaCropGeometry.box(ratio: value, in: surface)
        placement = MediaCropGeometry.filling(
            box, source: source, angle: placement.angle, isMirrored: placement.isMirrored
        )
        UIView.animate(withDuration: Metrics.settle, delay: 0, options: [.curveEaseOut]) {
            self.apply()
        }
        emit()
    }

    /// ⚠️ **"ORIGINAL" MEANS THE PICTURE AS IT NOW STANDS, QUARTER TURNS
    /// INCLUDED.** A portrait photograph turned on its side is a landscape one;
    /// offering its upright proportions after the turn would put the box across
    /// the picture rather than around it.
    private var turnedSource: CGSize {
        quarters % 2 == 0 ? source : CGSize(width: source.height, height: source.width)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        dimming.frame = bounds
        // ⚠️ DERIVED FROM THE CROP, NOT KEPT ACROSS A RESIZE. The surface changes
        // size when the band opens under it; re-deriving is exact because
        // `framing` is `crop`'s inverse — pinned by
        // `whatWasFramedComesBackFramedTheSameWay`.
        if !isGesturing, laidOutFor != bounds {
            laidOutFor = bounds
            let framing = MediaCropGeometry.framing(for: crop, source: source, in: surface)
            box = framing.box
            placement = framing.placement
        }
        apply()
    }

    private func apply() {
        picture.bounds = CGRect(origin: .zero, size: source)
        picture.center = placement.centre
        // ⚠️ SCALE INSIDE THE ROTATION, so the picture is enlarged about its own
        // centre and then turned — which is the order `CropPlacement` describes
        // and the order the renderer bakes.
        // ⚠️ **THE REFLECTION IS A NEGATIVE X SCALE, AND IT IS APPLIED BEFORE THE
        // ROTATION.** `scaledBy` post-multiplies, so the scale runs first and the
        // rotation second — the same order `MediaCropRenderer` bakes in. Mirroring
        // after the turn would reflect about a different axis and the preview would
        // stop agreeing with the post.
        picture.transform = CGAffineTransform(
            rotationAngle: MediaCropGeometry.radians(placement.angle)
        ).scaledBy(x: placement.isMirrored ? -placement.scale : placement.scale, y: placement.scale)

        outline.frame = box
        hole.frame = bounds
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(rect: box))
        hole.path = path.cgPath
    }

    // MARK: - The drag

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            isGesturing = true
            takeHold(at: pan.location(in: self), fingers: pan.numberOfTouches)
            outline.setGuidesVisible(true)
        case .changed:
            // ⚠️ A SECOND FINGER MID-DRAG GIVES THE BOX BACK — see `takeHold`.
            if pan.numberOfTouches > 1 { grip = [] }
            let travel = pan.translation(in: self)
            pan.setTranslation(.zero, in: self)
            track(by: travel)
        case .ended, .cancelled, .failed:
            finishDrag()
        default:
            break
        }
    }

    /// What the finger has hold of at the start of a drag.
    ///
    /// ⚠️ **TWO FINGERS NEVER TAKE A HANDLE, AND THIS WAS A REAL DEFECT.** A pan
    /// recogniser's minimum is one touch and its maximum is unbounded, and this
    /// view deliberately lets the pan and the pinch run together — so a two-finger
    /// pinch ALSO begins the pan, and the grip was taken from the centroid of the
    /// two fingers. Pinch anywhere within 44pt of an edge, which on a box inset
    /// only 16pt from the screen is most of the places a thumb and forefinger
    /// naturally land, and zooming the picture dragged the crop box instead.
    /// A pinch is never a resize; it can only ever move and scale the picture.
    private func takeHold(at point: CGPoint, fingers: Int) {
        grip = fingers > 1
            ? []
            : MediaCropGeometry.grip(at: point, box: box, reach: Metrics.reach)
    }

    /// ⚠️ **ONE ROUTINE, BECAUSE THE DEBUG ENTRY POINT RE-ENTERS IT.**
    /// `IconSelectorBar` states the rule: a hook that copies the handler's body
    /// tests the copy, and the two drift the first time only one of them is
    /// edited. `debugDrag(by:)` calls this, it does not reproduce it.
    private func track(by travel: CGPoint) {
        if grip.movesThePicture {
            placement = MediaCropGeometry.covering(
                MediaCropGeometry.moving(placement, by: travel), source: source, box: box
            )
        } else {
            box = MediaCropGeometry.resized(
                box, grip: grip, by: travel,
                ratio: ratio.value(for: turnedSource), in: surface
            )
            placement = MediaCropGeometry.covering(placement, source: source, box: box)
        }
        apply()
    }

    private func finishDrag() {
        isGesturing = false
        outline.setGuidesVisible(false)
        if !grip.movesThePicture {
            // ⚠️ THE BOX GROWS BACK AND THE PICTURE FOLLOWS IT. Leaving a dragged
            // box small shows the author a postage stamp of their own photograph
            // and shrinks every later target; `reframed` is the arithmetic that
            // keeps the same content while doing it.
            let grown = MediaCropGeometry.reframed(box: box, placement: placement, in: surface)
            box = grown.box
            placement = grown.placement
            UIView.animate(withDuration: Metrics.settle, delay: 0, options: [.curveEaseOut]) {
                self.apply()
            }
        }
        grip = []
        emit()
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            isGesturing = true
        case .changed:
            pinch(by: gesture.scale, about: gesture.location(in: self))
            gesture.scale = 1
        case .ended, .cancelled, .failed:
            isGesturing = false
            emit()
        default:
            break
        }
    }

    /// The other half of the same rule as `track(by:)`: one routine, re-entered.
    private func pinch(by factor: CGFloat, about anchor: CGPoint) {
        placement = MediaCropGeometry.covering(
            MediaCropGeometry.scaling(placement, by: factor, about: anchor),
            source: source, box: box
        )
        apply()
    }

    /// States what the author now keeps.
    ///
    /// ⚠️ **SNAPPED TO A TRUE NEUTRAL, BECAUSE `MediaCrop.isUntouched` IS AN
    /// EXACT `==`.** A picture dragged back to where it started comes out as
    /// (0.0000001, …) rather than as the whole frame, and the renderer would
    /// then pay a full GPU round trip and a resample to hand back a picture
    /// indistinguishable from the one it was given.
    private func emit() {
        let measured = MediaCropGeometry.crop(box: box, placement: placement, source: source)
        crop = Self.snapped(measured)
        onChange?(crop)
    }

    static func snapped(_ crop: MediaCrop) -> MediaCrop {
        let slack: CGFloat = 0.004
        let whole = abs(crop.rect.minX) < slack && abs(crop.rect.minY) < slack
            && abs(crop.rect.width - 1) < slack && abs(crop.rect.height - 1) < slack
        // ⚠️ A REFLECTION IS A CHANGE. A picture mirrored and otherwise untouched
        // frames the whole photograph at zero degrees, and calling that "untouched"
        // would drop the one thing the author did.
        guard whole, crop.angle == 0, !crop.isMirrored else { return crop }
        return .untouched
    }
}

// MARK: - The surface wins its own touches

extension MediaCropSurfaceView: UIGestureRecognizerDelegate {
    /// ⚠️ **ITS OWN TWO, AND NOTHING ELSE.** A pinch and a pan must run together
    /// or a two-finger gesture that drifts stops scaling. Answering `true`
    /// wholesale would also pair them with the sheet's dismissal and the stack's
    /// back-swipe, which are the two gestures this surface exists to keep out.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        let mine: Set<ObjectIdentifier> = [ObjectIdentifier(drag), ObjectIdentifier(pinch)]
        return mine.contains(ObjectIdentifier(gestureRecognizer)) && mine.contains(ObjectIdentifier(other))
    }

    /// ⚠️ **FIRST REFUSAL, NOT OWNERSHIP — THE FILTER ROW'S RULE, WITH THE GUARD
    /// THIS SURFACE NEEDS.** An outsider's recogniser must wait for this one to
    /// fail, so a drag on the picture is the picture's; a recogniser inside this
    /// view keeps its ordinary relationship. NOT an `override`: UIKit finds it by
    /// selector on the delegate, and writing `override` here does not compile.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === drag || gestureRecognizer === pinch else { return false }
        guard let owner = other.view else { return true }
        return !owner.isDescendant(of: self)
    }
}

/// The lines drawn over the kept rectangle: brackets at the corners always, the
/// thirds only while a finger is down.
///
/// ⚠️ **DRAWN, NOT ASSEMBLED.** Four brackets and four rules are eight subviews
/// to lay out on every frame of a drag, against one `draw(_:)` that costs a
/// redraw of a rectangle nobody else composites.
private final class CropFrameView: UIView {
    private enum Metrics {
        /// How far the corner brackets run along each edge. ⚠️ THE INK, NOT THE
        /// TARGET: what may be taken hold of is `MediaCropSurfaceView.Metrics.reach`,
        /// which is twice this — a bracket sized to the finger would be a frame
        /// made of corners.
        static let bracket: CGFloat = 22
        static let bracketWidth: CGFloat = 3
        static let outline: CGFloat = 1
        static let inset: CGFloat = 1.5
    }

    private var showsGuides = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        // ⚠️ **A `CGColor` IS RESOLVED WHERE IT IS READ, AND `draw` READS THESE.**
        // Without this the frame would keep the appearance the device had when the
        // mode was opened, which on a switch to dark is a black frame on black.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (frame: CropFrameView, _) in
            frame.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Internal for tests: the ink the frame is drawn in, so it can be held
    /// against the ground it stands beside.
    var debugInk: UIColor { .label }

    override var frame: CGRect { didSet { setNeedsDisplay() } }

    /// ⚠️ **NO ANIMATION HERE, AND THE LINE THAT USED TO BE HERE WAS A NO-OP.**
    /// It animated `alpha` from 1 to 1 while claiming to fade the guides in, which
    /// is the shape of an animation that cannot be seen — this repository has paid
    /// for a from-value that was already the to-value before. The thirds appear and
    /// leave with the finger, redrawn; if they ever should fade, the thing to fade
    /// is a separate layer holding them, not this view's own alpha, which also
    /// carries the brackets.
    func setGuidesVisible(_ visible: Bool) {
        guard visible != showsGuides else { return }
        showsGuides = visible
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), bounds.width > 0 else { return }

        if showsGuides {
            context.setLineWidth(1 / (window?.screen.scale ?? 2))
            context.setStrokeColor(UIColor.label.withAlphaComponent(0.45).cgColor)
            for step in 1...2 {
                let x = bounds.minX + bounds.width * CGFloat(step) / 3
                let y = bounds.minY + bounds.height * CGFloat(step) / 3
                context.move(to: CGPoint(x: x, y: bounds.minY))
                context.addLine(to: CGPoint(x: x, y: bounds.maxY))
                context.move(to: CGPoint(x: bounds.minX, y: y))
                context.addLine(to: CGPoint(x: bounds.maxX, y: y))
            }
            context.strokePath()
        }

        context.setLineWidth(Metrics.outline)
        context.setStrokeColor(UIColor.label.withAlphaComponent(0.7).cgColor)
        context.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))

        context.setLineWidth(Metrics.bracketWidth)
        context.setLineCap(.square)
        // ⚠️ **`.label`, NOT WHITE — AND WHITE WAS RIGHT UNTIL THE GROUND MOVED.**
        // A white frame on a black editor is the universal convention and it was
        // crisp. On a white one it vanishes: seen on screen, the corner brackets
        // disappeared into the margin entirely and read as a faint edge over the
        // photograph. What the frame actually sits beside is the SCRIM, which is
        // the ground colour at 55% — so an ink that turns with the ground is
        // legible against it in both appearances.
        context.setStrokeColor(UIColor.label.cgColor)
        let reach = Metrics.bracket
        let inset = Metrics.inset
        let corners = [
            (CGPoint(x: bounds.minX + inset, y: bounds.minY + inset), CGFloat(1), CGFloat(1)),
            (CGPoint(x: bounds.maxX - inset, y: bounds.minY + inset), CGFloat(-1), CGFloat(1)),
            (CGPoint(x: bounds.minX + inset, y: bounds.maxY - inset), CGFloat(1), CGFloat(-1)),
            (CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset), CGFloat(-1), CGFloat(-1))
        ]
        for (corner, alongX, alongY) in corners {
            context.move(to: CGPoint(x: corner.x + alongX * reach, y: corner.y))
            context.addLine(to: corner)
            context.addLine(to: CGPoint(x: corner.x, y: corner.y + alongY * reach))
        }
        context.strokePath()
    }
}

extension MediaCropSurfaceView {
    /// Internal for tests: where the kept rectangle sits on the surface.
    var debugBox: CGRect { box }
    /// Internal for tests: where the picture sits under it.
    var debugPlacement: CropPlacement { placement }
    /// Internal for tests: the ink of the frame drawn over the picture.
    var debugFrameInk: UIColor { outline.debugInk }
    /// Internal for tests: whether a picture has actually landed on the surface.
    var debugHasPicture: Bool { picture.image != nil }
    /// Internal for tests: the area the box may occupy.
    var debugSurface: CGRect { surface }
    /// Internal for tests: the quarter turns and the fine angle, separately.
    var debugTurn: (quarters: Int, fine: CGFloat) { (quarters, fine) }
    /// Internal for tests: whether the picture is showing as its own reflection.
    var debugIsMirrored: Bool { isMirrored }
    /// Internal for tests: the path a real drag takes, without a finger.
    func debugBeginDrag(at point: CGPoint, fingers: Int = 1) {
        isGesturing = true
        takeHold(at: point, fingers: fingers)
    }
    func debugDrag(by travel: CGPoint) { track(by: travel) }
    func debugEndDrag() { finishDrag() }
    /// Internal for tests: the path a pinch takes, without two fingers.
    func debugPinch(by factor: CGFloat, about anchor: CGPoint) {
        pinch(by: factor, about: anchor)
        emit()
    }
    /// Internal for tests: what the surface has hold of at a point.
    func debugGrip(at point: CGPoint) -> MediaCropGeometry.Grip {
        MediaCropGeometry.grip(at: point, box: box, reach: Metrics.reach)
    }
    /// Internal for tests: whether the surface is asked before an outsider.
    func debugIsAskedBefore(_ other: UIGestureRecognizer) -> Bool {
        gestureRecognizer(drag, shouldBeRequiredToFailBy: other)
    }
    /// Internal for tests: that its own two run together.
    var debugPanAndPinchRunTogether: Bool {
        gestureRecognizer(drag, shouldRecognizeSimultaneouslyWith: pinch)
    }
    /// Internal for tests: that UIKit asks this view and not somebody else.
    var debugOwnsItsGestures: Bool { drag.delegate === self && pinch.delegate === self }
}
