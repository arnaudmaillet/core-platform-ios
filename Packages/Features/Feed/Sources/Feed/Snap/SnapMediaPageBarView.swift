import DesignSystem
import PostGrid
import UIKit

/// Which picture of a collection the post screen is showing: **one segment per
/// page, laid across the whole width of the column**, and the one you are on is
/// the wide one.
///
/// ## Why a bar and not the card's dots
///
/// The card's chip is furniture in a row of counters, sized to what it can
/// spare — five dots at most, a window sliding through the rest. This screen
/// has the whole width and one thing to say with it, so the strip says it the
/// way a strip can: every page gets a segment, and a segment's LENGTH is its
/// share of the width. Two pictures make two long pills; twelve make twelve
/// short ones, and the difference is legible before it is counted.
///
/// ## The strip is a function of the scroll
///
/// ⚠️ Its whole state is ONE number: where the carousel is, in fractional
/// pages. Width and ink are read off that number, so the strip reflows under
/// the finger for the entire gesture instead of waiting to be told a page has
/// changed — the crossing is a consequence of the drag, not the moment the
/// drawing may begin. Halfway between two pictures, both segments are half
/// grown and half lit.
///
/// The total width is invariant under that interpolation (the weights always
/// sum to the same number), so the run stays edge to edge while its insides
/// move. Anything else would be a strip that breathes at its ends, which reads
/// as a layout bug rather than as motion.
///
/// ## On a clip, the strip becomes the clip's own bar
///
/// A video page has two things to say and they are the same shape: where you
/// are in the post, and where you are in the picture. So the active segment
/// grows to nearly the whole width and carries the playhead inside it, with
/// the neighbouring pages left as slivers at either edge — still there, still
/// tappable, still saying "there is more this way".
///
/// The strip's controls follow the same split: a TAP always selects the segment
/// under it (that is how you move between pages once the segments are slivers),
/// and a DRAG means the finer of the two things on offer — the playhead on a
/// clip, the pages on a photograph.
///
/// ## A window, past ten pictures
///
/// Ten segments is the most the strip draws. Beyond that it stops being a
/// diagram and becomes a texture — at twenty, a segment is thinner than the gap
/// beside it — so a window of ten slides through the run instead, with the mark
/// walking inside it and the run tapering away at whichever end it continues
/// past. That is the card indicator's own system (`PageWindow`), told
/// continuously here because this strip has a continuous position to tell it
/// with: a page leaving narrows and fades out while the one arriving grows in.
///
/// ## Frames, not a stack
///
/// How wide a segment is depends on the width and the count, both of which
/// change under this view; `UIStackView` would have to add and remove arranged
/// subviews inside a layout pass to answer that, which is the fight
/// `PageDotsView` and `MediaCarouselView` both avoid the same way.
///
final class SnapMediaPageBarView: UIView {
    /// The strip's thickness — the card's dot diameter, so this reads as the
    /// same ink stretched rather than as a different control.
    static let thickness: CGFloat = MediaPageIndicatorView.dotDiameter

    /// The gap between two segments. Small enough that the run reads as one
    /// strip, wide enough that the divisions are not a moiré at twelve pages.
    static let gap: CGFloat = Spacing.xs

    /// How much wider the page you are on is than the rest.
    ///
    /// ⚠️ Wide enough that the answer survives a glance at twelve pages: at
    /// 2.6 the active pill is unmistakably the long one whatever the count,
    /// where 1.5 read as "the segments are uneven" rather than as a mark.
    static let activeWidthFactor: CGFloat = 2.6

    /// The ink the pages you are not on are drawn in — the card's own ratio.
    static let restingAlpha: CGFloat = 0.35

    /// How many segments the strip draws at once, however many pictures there
    /// are.
    ///
    /// ⚠️ Past this the strip stops being a diagram and becomes a texture: at
    /// twenty, a segment is narrower than the gap beside it and the mark's
    /// 2.6× is a few points of nothing. Ten is where a run still reads as
    /// countable — and beyond it the WINDOW carries the rest, exactly as the
    /// card's chip does with five dots.
    static let maximumVisibleSegments = 10

    /// How far the whole strip is held back when nothing is happening.
    ///
    /// ⚠️ IT IS FURNITURE MOST OF THE TIME. The strip sits under the caption on
    /// every collection and every clip, and at full strength it competes with
    /// the words above it for a reading nobody is taking — you look at an index
    /// when you are moving, and the rest of the time you are looking at the
    /// picture. So it rests here and comes up to full for as long as something
    /// is happening, which is what a player's own controls do and for the same
    /// reason.
    static let restingOpacity: CGFloat = 0.45

    /// How long the strip stays up after the last thing that woke it.
    ///
    /// Long enough to finish a thought — reading where you are after a swipe,
    /// or reaching for a sliver you have just seen — and short enough that a
    /// post left alone settles back to its picture.
    static let wakeDuration: TimeInterval = 3

    /// What is left for a neighbour when the active segment is a clip's bar.
    ///
    /// ⚠️ A SLIVER, NOT NOTHING. The pages either side are the only thing left
    /// saying the post has more than this one picture, and they are the targets
    /// a tap uses to get there — a strip that showed the bar alone would be a
    /// carousel with no way out but the media itself.
    static let clipNeighbourWidth: CGFloat = 14

    /// How many slots the run tapers over at an end it continues past.
    ///
    /// ⚠️ TWO, not one, and the card's note says why: the outermost segment
    /// shrinking says "there is more past here"; the one beside it, part-way
    /// down, says how the row is GOING. A single step from full size to nothing
    /// reads as a run that was cut; a slope reads as a run that continues.
    static let taperSlots: CGFloat = 2

    /// The viewer asked for a page by dragging along the strip. The HOST moves
    /// the carousel — an indicator that scrolled something for itself would be
    /// a second thing deciding where the pages are.
    var onPageRequested: ((Int) -> Void)?

    /// The scrub, exposed so a host can make its OWN pan yield to it.
    ///
    /// ⚠️ A long press of zero duration, not a pan, for the reason the card's
    /// chip states at length: a pan must see movement before it begins, and
    /// every scroll view above this strip is watching for the same movement, so
    /// the ancestor claims it every time. A long press begins on touch-down,
    /// before anything else has anything to go on.
    let scrubGesture: UILongPressGestureRecognizer = {
        let scrub = UILongPressGestureRecognizer()
        scrub.minimumPressDuration = 0
        scrub.allowableMovement = .greatestFiniteMagnitude
        scrub.cancelsTouchesInView = true
        return scrub
    }()

    /// The viewer asked to move the playhead of the clip the strip is drawing.
    /// The HOST owns playback, for the reason it owns the carousel.
    var onSeekRequested: ((Double) -> Void)?

    /// Where the thumb is pointing while it drags a clip's bar: the moment, and
    /// the place along the strip to point at. Nil when the drag ends.
    ///
    /// Separate from `onSeekRequested` because they are answered by different
    /// things — one moves the picture, the other describes where it is going —
    /// and because a preview that arrives late must not re-seek.
    var onScrubPreview: (((fraction: Double, x: CGFloat))?) -> Void = { _ in }

    private var segments: [UIView] = []
    /// The played part of each segment — minted only for the page that is a
    /// clip, because that is the only one that ever draws it.
    private var fills: [Int: UIView] = [:]
    private var pageCount = 0
    /// Which picture of how many, in the corner the run leaves for it.
    ///
    /// ⚠️ THE COUNT IS THE ANSWER THE SEGMENTS CANNOT GIVE. A run of pills says
    /// where you are in a gallery and, once a window is sliding through a long
    /// one, stops being able to say how big the gallery is — and on a clip the
    /// run is a bar and says neither. Two characters and a slash say both, for
    /// the width of a word.
    private let counter: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        return label
    }()

    /// The counter's own plate, so it survives a bright photograph the way the
    /// scrub card's does.
    private let counterPlate: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        view.layer.cornerCurve = .continuous
        view.isUserInteractionEnabled = false
        return view
    }()

    /// What the counter's plate adds around its text.
    static let counterPadding = CGSize(width: 12, height: 4)

    /// The gap between the run of segments and the counter — wider than the
    /// gap between two segments, because it separates two DIFFERENT things
    /// rather than two of a kind.
    static let counterInset: CGFloat = Spacing.sm

    /// Whether there is anything to draw: more than one picture, or one that is
    /// a clip and therefore has a playhead to show.
    private var hasStrip: Bool { pageCount >= 2 || (pageCount == 1 && clipPages.contains(0)) }

    /// Which pages carry a clip: the strip draws those differently and reads a
    /// drag on them differently.
    private var clipPages: Set<Int> = []
    /// How far through the clip on the page the viewer is on, when there is one
    /// and its length is known. Nil draws nothing rather than zero — see
    /// `VideoPlaybackController.playhead`.
    private var playhead: Double?
    /// Where the carousel is, in fractional pages — the strip's entire state.
    private var position: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isExclusiveTouch = true
        alpha = Self.restingOpacity
        scrubGesture.addTarget(self, action: #selector(handleScrubGesture))
        addGestureRecognizer(scrubGesture)
        addSubview(counterPlate)
        counterPlate.addSubview(counter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.thickness)
    }

    /// One segment per page — with one exception, and the exception is the
    /// point of the clip's bar.
    ///
    /// A single PHOTOGRAPH has no position to report and gets no strip: one
    /// full-width pill would claim it did. A single CLIP has a position to
    /// report — where you are in it — so it gets the strip, drawn as the bar
    /// with nothing either side of it. Same view, same drag, same tap; there
    /// are simply no pages to walk to.
    func configure(count: Int, current: Int, clipPages: Set<Int> = []) {
        self.clipPages = clipPages
        wakeTimer?.invalidate()
        wakeTimer = nil
        alpha = Self.restingOpacity
        pageCount = count
        isHidden = !hasStrip
        guard hasStrip else { return }
        if segments.count != count {
            segments.forEach { $0.removeFromSuperview() }
            segments = (0..<count).map { _ in
                let view = UIView()
                view.backgroundColor = .white
                view.layer.cornerRadius = Self.thickness / 2
                view.isUserInteractionEnabled = false
                addSubview(view)
                return view
            }
        }
        position = CGFloat(min(max(current, 0), count - 1))
        // A lone clip has nothing to count — "1/1" is a fact nobody asked for.
        counterPlate.isHidden = count < 2
        updateCounter()
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The count reads the page the viewer is ON — the rounded position — so it
    /// changes once, where the swipe crosses, rather than flickering between
    /// two numbers across a drag.
    private func updateCounter() {
        guard pageCount >= 2 else { return }
        let page = min(max(Int(position.rounded()), 0), pageCount - 1)
        counter.text = "\(page + 1)/\(pageCount)"
        counter.sizeToFit()
        // ⚠️ AND IT DOES NOT ASK FOR A LAYOUT. This runs from inside
        // `layoutSegments`, which runs from `layoutSubviews` — dirtying the
        // view there marks it for a pass that dirties it again, and the
        // `layoutIfNeeded` in `setPages` spins on that forever with the main
        // thread in its hand. Both callers already place the counter: the run
        // lays it out in the same pass, and `setPages` asks for the pass.
    }

    /// How far through the clip on the page the viewer is on. Nil when there is
    /// no clip, or none whose length is known yet.
    func setPlayhead(_ fraction: Double?) {
        guard playhead != fraction else { return }
        playhead = fraction
        layoutSegments()
    }

    /// The carousel moved, in fractional pages.
    ///
    /// Applied IMMEDIATELY and with NOTHING ELSE: this is the transposition,
    /// and a strip that eased its way toward the finger would lag the pictures
    /// it describes.
    ///
    /// ⚠️ AND NOTHING ELSE HAPPENS HERE — no accent, no easing, no second
    /// motion of any kind.
    ///
    /// A bounce lived here for two versions: first at the crossing, where it
    /// stretched a segment while the widths were still reflowing under the
    /// finger, and then at the settle, where it was at least alone. Both were
    /// removed. The strip already MOVES — its widths and its ink are a function
    /// of the scroll — and an accent laid over a thing that is already moving
    /// is a second motion on one object however well timed it is. What reads as
    /// alive here is the reflow itself.
    func setPosition(_ newPosition: CGFloat) {
        guard pageCount >= 2 else { return }
        position = min(max(newPosition, 0), CGFloat(pageCount - 1))
        layoutSegments()
        // ⚠️ AND SCROLLING THE PICTURES DOES NOT LIGHT THE STRIP. It did, on
        // the reading that the strip is about the pages and the pages were
        // moving — but a viewer swiping through a gallery is looking at the
        // gallery, and an index that brightens under every swipe is a second
        // thing moving in the corner of the eye for the whole gesture. The
        // strip comes up when it is TOUCHED, which is when it is being used
        // rather than merely being true.
    }

    /// Brings the strip up to full and starts the clock that takes it back down.
    ///
    /// ⚠️ THE ONE ANIMATION IN THIS FILE, and it is not of the strip's shape —
    /// the widths and the ink stay a function of the scroll, with nothing of
    /// their own to animate. This is the control APPEARING, which is a
    /// different kind of event and the only one the strip has.
    private func wake() {
        wakeTimer?.invalidate()
        wakeTimer = Timer.scheduledTimer(withTimeInterval: Self.wakeDuration, repeats: false) {
            [weak self] _ in self?.rest()
        }
        guard alpha < 1 else { return }
        UIView.animate(withDuration: 0.18, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 1
        }
    }

    private func rest() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        UIView.animate(withDuration: 0.45, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = Self.restingOpacity
        }
    }

    private var wakeTimer: Timer?

    /// A page arrived as a NUMBER rather than as a position — a post reopened
    /// on page three, a page set from outside.
    ///
    /// ⚠️ IT MUST NOT ACT ON A PAGE THE STRIP IS ALREADY ON, and "already on"
    /// means the rounded position, not an exact match. The carousel reports
    /// both signals: a fraction on every scroll callback and a page number at
    /// the crossing. Halfway through a drag the fraction is 0.52 and the page
    /// number is 1 — both true, and a strip that sprang to 1.0 on the second
    /// would jump ahead of the finger and be dragged back by the next fraction.
    /// A page it already agrees with is nothing to do.
    func setCurrent(_ page: Int) {
        guard pageCount >= 2 else { return }
        let target = CGFloat(min(max(page, 0), pageCount - 1))
        guard Int(position.rounded()) != Int(target) else { return }
        position = target
        layoutSegments()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutSegments()
    }

    /// Every segment's geometry and ink, from `position` and the window alone.
    ///
    /// Two curves, multiplied.
    ///
    /// The MARK is a tent: a segment is fully grown at its own page, resting a
    /// page away, linear in between — so two neighbours share the growth
    /// exactly while the viewer is between them.
    ///
    /// PRESENCE is how much of the strip a page is entitled to at all: 1 inside
    /// the window, tapering to nothing across the last two slots of an end the
    /// run continues past, 0 beyond. A page leaving therefore narrows and fades
    /// out while the one arriving grows in — the same information the card's
    /// dots give with a shrunken edge dot, told continuously because this strip
    /// has a continuous position to tell it with.
    ///
    /// The widths are shares of what is left after the gaps, so the run spans
    /// the column exactly at every position — including mid-slide, where the
    /// gaps of a half-arrived segment are themselves half-width.
    private func layoutSegments() {
        guard !segments.isEmpty, bounds.width > 0 else { return }
        updateCounter()
        layoutCounter()
        let visible = visibleSlots
        updateWindowOrigin(visible: visible)
        let rooms = segments.indices.map { room(forPage: $0, visible: visible) }
        let weights = segments.indices.map {
            rooms[$0] * (1 + (Self.activeWidthFactor - 1) * proximity(toPage: $0))
        }
        let total = max(weights.reduce(0, +), 0.0001)
        // ⚠️ THE CLIP'S SHAPE HAS TO REACH THE GAPS TOO. A page the bar has
        // squeezed to nothing still sat between two seams, so seven pages of a
        // long post contributed seven gaps of pure air — the bar was 28pt short
        // of the width it claimed and a tap could land on a segment with no
        // width at all. What a seam is worth is what the SEGMENTS either side
        // are drawn as, clip shape included.
        let clipness = clipPageProximity
        let clipWeights = clipness > 0 ? clipShapeWeights(available: runWidth) : nil
        let shown = segments.indices.map { index -> CGFloat in
            guard let clipWeights else { return rooms[index] }
            // ⚠️ A DISTANCE, NOT A BOOLEAN — the same mistake this file made in
            // the taper, made again here and costing the same thing.
            //
            // Written as `weight > 0 ? 1 : 0` this flips from one to nothing at
            // exactly two slots from the clip, which is exactly where a swipe
            // onto that clip ENDS. The flip is not visible on the page that
            // flips — it is already down to a hair — but `shown` is what the
            // GAPS are drawn from, and the gaps are what `available` has left
            // for everyone: two seams closing in a single frame handed four
            // points back to the run at the last moment of the swipe, and the
            // bar surged into them after having been slowing down. Measured on
            // a five-page post with a clip at index two: the run's widths summed
            // to 307.59 at position 1.98 and 311.67 at 2.00.
            //
            // As a distance it fades over the same slot the sliver fades over,
            // so the seam closes across the swipe instead of at the end of it.
            let inTheClipsShape = min(clipWeights[index] / Self.clipNeighbourWidth, 1)
            return rooms[index] * (1 - clipness * (1 - inTheClipsShape))
        }
        // A gap belongs to a seam, and a seam is only as present as the thinner
        // of the two segments it separates.
        let gaps = segments.indices.dropLast().map { Self.gap * min(shown[$0], shown[$0 + 1]) }
        // The run gets what the counter leaves it: the counter is the one thing
        // here whose width comes from its text rather than from the column.
        let available = max(runWidth - gaps.reduce(0, +), 1)
        // ⚠️ THE CLIP'S SHAPE IS BLENDED IN, not switched to. `clipness` is the
        // tent again — how much of the page you are on is the clip — so the
        // strip grows into a progress bar across the swipe that arrives at one
        // and shrinks back across the swipe that leaves. A mode switched at the
        // crossing would be the boolean mistake this file has already made
        // once, in the taper.
        let clipTargets = clipWeights.map { targets in
            // Re-scaled to what is actually left after the gaps this shape
            // leaves behind, so the bar fills the width rather than most of it.
            let sum = max(targets.reduce(0, +), 0.0001)
            return targets.map { $0 / sum * available }
        }
        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            let share = available * weights[index] / total
            let width = clipTargets.map { share + ($0[index] - share) * clipness } ?? share
            // ⚠️ bounds + centre rather than frame. They are the same thing
            // while nothing is transformed, and they stay right if anything
            // ever is: assigning a frame to a transformed view re-derives its
            // bounds and cancels the transform silently — the trap
            // `SnapFeedCell.pageStage` documents one view up.
            segment.bounds = CGRect(x: 0, y: 0, width: max(width, 0), height: bounds.height)
            segment.center = CGPoint(x: x + width / 2, y: bounds.height / 2)
            segment.layer.cornerRadius = min(bounds.height, max(width, 0)) / 2
            // ⚠️ A CLIP'S BAR IS A TRACK, so the segment carrying it steps back
            // to the resting ink and the PLAYED part is the bright thing. Left
            // at full white it would be a bar that reads as finished from the
            // first frame.
            //
            // ⚠️ AND THE DIMMING IS IN THE COLOUR, NOT IN `alpha`. A view's
            // alpha applies to its whole subtree, so a track dimmed that way
            // dims the played part inside it by exactly the same amount — the
            // fill was drawn, correctly sized, and invisible. `alpha` is left
            // to carry PRESENCE alone, which is a property of the segment and
            // everything in it.
            let lit = Self.restingAlpha + (1 - Self.restingAlpha) * proximity(toPage: index)
            let ink = lit - (lit - Self.restingAlpha) * clipness
            segment.alpha = shown[index]
            segment.backgroundColor = UIColor.white.withAlphaComponent(ink)
            layoutFill(onPage: index, width: width, clipness: clipness)
            x += width + (index < gaps.count ? gaps[index] : 0)
        }
    }

    /// How much of where the viewer IS, is clip.
    ///
    /// ⚠️ THE SUM, NOT THE NEAREST ONE — and the difference is a defect you can
    /// see. Proximity is a tent whose two halves add to one, so between two
    /// pages each contributes half. Taking the nearest gave 0.5 in the middle
    /// of a swipe from one clip to the NEXT clip, and the strip dutifully
    /// blended half way back to its ordinary shape: the other pages flashed
    /// into view and out again between two videos, for no reason a viewer could
    /// name. Added, two consecutive clips hold this at 1 all the way across,
    /// and a clip beside a photograph still hands over smoothly.
    private var clipPageProximity: CGFloat {
        min(clipPages.reduce(0) { $0 + proximity(toPage: $1) }, 1)
    }

    /// The widths the strip would have if where the viewer is were wholly clip:
    /// the bar, its two slivers, and nothing beyond them.
    ///
    /// ⚠️ NO DISCRETE CENTRE. Written as "the page you are on gets the bar" it
    /// swapped bar and sliver at the half-way point of a swipe — an instant
    /// exchange of a full width for fourteen points, in a strip that has spent
    /// this whole file refusing to jump. So the bar is the TENT again, shared
    /// between the two pages a swipe is between, and a sliver fades in over the
    /// slot beyond it. Every term is a distance, so nothing switches.
    ///
    /// The two are combined with `max` rather than added: a page half-way to
    /// being the bar is already wider than a sliver, and adding would make the
    /// hand-over bulge.
    private func clipShapeWeights(available: CGFloat) -> [CGFloat] {
        let sliver = Self.clipNeighbourWidth
        let bar = max(available - 2 * sliver - 2 * Self.gap, 1)
        return segments.indices.map { index in
            let distance = abs(CGFloat(index) - position)
            let asBar = bar * max(0, 1 - distance)
            // A slot away is a whole sliver; two away is none, and the fade
            // between them is what a page leaving the shape does.
            let asSliver = sliver * min(max(2 - distance, 0), 1)
            return max(asBar, asSliver)
        }
    }

    /// The played part of a clip's bar, drawn inside the segment that carries
    /// it. Minted on the page that needs one and never on any other.
    private func layoutFill(onPage index: Int, width: CGFloat, clipness: CGFloat) {
        // The playhead the host feeds belongs to the clip being WATCHED, which
        // is the page nearest the viewer — so only that page draws a fill, and
        // it wears its own proximity as opacity. Mid-swipe both candidates are
        // at half strength, so the moment the watched page changes hands the
        // fill is already faint enough that the change cannot be seen.
        let watched = index == Int(position.rounded())
        let isBar = clipPages.contains(index) && clipness > 0 && watched
        guard isBar, let playhead else {
            fills[index]?.isHidden = true
            return
        }
        let fill = fills[index] ?? {
            let view = UIView()
            view.backgroundColor = .white
            view.isUserInteractionEnabled = false
            segments[index].addSubview(view)
            fills[index] = view
            return view
        }()
        fill.isHidden = false
        fill.alpha = clipness * proximity(toPage: index)
        let played = max(min(CGFloat(playhead), 1), 0) * width
        fill.frame = CGRect(x: 0, y: 0, width: played, height: bounds.height)
        fill.layer.cornerRadius = min(bounds.height, played) / 2
    }

    /// 1 on the page itself, 0 a page away, linear between — the tent above.
    private func proximity(toPage index: Int) -> CGFloat {
        max(0, 1 - abs(CGFloat(index) - position))
    }

    /// How much strip a page is entitled to: presence, except that the MARK is
    /// never tapered.
    ///
    /// ⚠️ The card's rule, and it exists because the two signals collide by
    /// construction: the taper says "the run continues past here" and the mark
    /// says "you are here", and the window deliberately parks the mark one slot
    /// in from the end it is heading for — which is exactly the slot the taper
    /// reaches. Shrinking the mark to say what its neighbours already say costs
    /// the one thing the strip is for.
    private func room(forPage index: Int, visible: Int) -> CGFloat {
        max(presence(ofPage: index, visible: visible), proximity(toPage: index))
    }

    /// 1 inside the window, tapering to 0 across `taperSlots` at an end the run
    /// continues past, 0 beyond it. Always 1 when the whole run fits.
    ///
    /// ⚠️ "CONTINUES PAST" IS A QUANTITY, NOT A YES OR NO — and reading it as a
    /// yes or no is what put a jump in an otherwise continuous strip.
    ///
    /// The taper used to be gated on a boolean: are there pages beyond this
    /// end. Sliding the window onto the last page flipped it, and the two
    /// tapered segments went from a sliver to full width between one frame and
    /// the next — reported, exactly, as the last segment popping to normal size
    /// with no animation as you reach the second-to-last page, and the same
    /// thing mirrored at the first.
    ///
    /// So it is measured instead: how MANY pages are still out there, clamped
    /// to one. A window with a whole page beyond it tapers fully; one with a
    /// third of a page left tapers a third as much; one sitting on the end does
    /// not taper at all. The strip stays what it is everywhere else — a
    /// function of the scroll, with no state of its own to animate.
    private func presence(ofPage index: Int, visible: Int) -> CGFloat {
        guard segments.count > visible else { return 1 }
        let slot = CGFloat(index) - windowOrigin
        let beyondBefore = min(max(windowOrigin, 0), 1)
        let beyondAfter = min(
            max(CGFloat(segments.count - visible) - windowOrigin, 0), 1
        )
        // Half a slot of overhang either side, so the outermost segment is
        // fully out of the window before it is gone.
        let leadingRamp = min(max((slot + 0.5) / Self.taperSlots, 0), 1)
        let trailingRamp = min(max((CGFloat(visible) - 0.5 - slot) / Self.taperSlots, 0), 1)
        // Each end's taper is worn only as far as that end continues.
        let leading = 1 - beyondBefore * (1 - leadingRamp)
        let trailing = 1 - beyondAfter * (1 - trailingRamp)
        return min(max(min(leading, trailing), 0), 1)
    }

    /// How wide the run of segments is: the strip, less the counter's corner.
    private var runWidth: CGFloat {
        max(bounds.width - counterFootprint, 1)
    }

    private var counterFootprint: CGFloat {
        counterPlate.isHidden ? 0 : counterPlate.bounds.width + Self.counterInset
    }

    /// The counter sits at the trailing end, vertically centred on the run —
    /// taller than the strip, which is why the strip's touch area was already
    /// grown to a thumb's size.
    private func layoutCounter() {
        guard !counterPlate.isHidden else { return }
        let size = CGSize(
            width: counter.bounds.width + Self.counterPadding.width * 2,
            height: counter.bounds.height + Self.counterPadding.height * 2
        )
        counterPlate.bounds = CGRect(origin: .zero, size: size)
        counterPlate.center = CGPoint(x: bounds.width - size.width / 2, y: bounds.height / 2)
        counterPlate.layer.cornerRadius = size.height / 2
        counter.center = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// How many segments the strip draws at once.
    private var visibleSlots: Int { min(segments.count, Self.maximumVisibleSegments) }

    /// The window's leading slot, kept between passes: the mark walks inside
    /// the window and the window follows only when it has to. Fractional, so a
    /// window that has to follow slides with the finger instead of jumping a
    /// whole slot at the crossing.
    private var windowOrigin: CGFloat = 0

    private func updateWindowOrigin(visible: Int) {
        windowOrigin = PageWindow.start(
            current: position, visible: visible, count: segments.count, from: windowOrigin
        )
    }

    // MARK: - Scrubbing

    @objc private func handleScrubGesture(_ recognizer: UIGestureRecognizer) {
        handleScrub(recognizer.state, atX: recognizer.location(in: self).x)
    }

    /// ⚠️ A TAP SELECTS; A DRAG MEANS THE FINER OF THE TWO THINGS ON OFFER.
    ///
    /// The card's chip refuses a tap outright — it is 50pt of dots between two
    /// counters, so a press there is as often a miss as an instruction. This
    /// strip is the width of the column with segments a thumb can hit, and once
    /// the active segment becomes a clip's bar the neighbours are slivers that
    /// a viewer has no other way to reach. So a press that does not travel
    /// selects the segment under it, absolutely.
    ///
    /// A drag that does travel asks for the finer thing: the PLAYHEAD on a
    /// clip, where the segment under the finger IS the clip, and the pages on a
    /// photograph. Both are relative to where the touch went down, so nothing
    /// jumps under the thumb that landed on it.
    private func handleScrub(_ state: UIGestureRecognizer.State, atX x: CGFloat) {
        guard hasStrip else { return }
        switch state {
        case .began:
            wake()
            touchDownX = x
            travelled = false
            seekAnchor = playhead
        case .changed:
            wake()
            if abs(x - touchDownX) > Self.travelThreshold { travelled = true }
            guard travelled else { return }
            // ⚠️ A DRAG MEANS THE PLAYHEAD OR IT MEANS NOTHING. It used to page
            // the carousel as well, one slot per segment — a second way to do
            // what a swipe on the picture already does, on a control the width
            // of the column, where the pages it walks past are the pages the
            // media is flying through underneath. Selecting is what a strip of
            // segments is for, and a tap says it exactly; dragging is for the
            // one thing that has no other control, which is where you are
            // inside a clip.
            guard isScrubbingAClip else { return }
            seek(draggedTo: x)
        case .ended, .cancelled, .failed:
            // The card belongs to the gesture: it goes when the thumb does,
            // including on a cancel, which is the case a rule written only for
            // `.ended` leaves a card hanging on screen.
            onScrubPreview(nil)
            wake()
            guard state == .ended, !travelled else { return }
            let hit = page(under: x)
            // ⚠️ A TAP ON THE BAR IS A TAP ON A CLIP, and the only thing a tap
            // there can mean is "go to that moment" — the page it lands on is
            // the page you are already on. On a lone clip it is the only
            // instruction the strip can carry at all.
            if isBar(hit), let fraction = fractionAlongBar(hit, atX: x) {
                onSeekRequested?(fraction)
            } else {
                onPageRequested?(hit)
            }
        default:
            break
        }
    }

    /// Whether this drag is moving the playhead rather than the pages: the page
    /// the viewer is ON carries a clip, and the strip is drawn as its bar.
    private var isScrubbingAClip: Bool { isBar(Int(position.rounded())) }

    /// Whether a page is currently drawn as a clip's bar — a clip, watched, and
    /// with a playhead worth drawing.
    private func isBar(_ index: Int) -> Bool {
        clipPages.contains(index) && index == Int(position.rounded()) && playhead != nil
    }

    /// Where along a bar a point falls, as a fraction of the clip.
    private func fractionAlongBar(_ index: Int, atX x: CGFloat) -> Double? {
        guard let frame = segmentFrame(index), frame.width > 1 else { return nil }
        return Double(min(max((x - frame.minX) / frame.width, 0), 1))
    }

    /// A segment's laid-out rectangle, from bounds and centre — the same pair
    /// the layout assigns, so a reader and the writer cannot disagree.
    private func segmentFrame(_ index: Int) -> CGRect? {
        guard segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        return CGRect(
            x: segment.center.x - segment.bounds.width / 2,
            y: segment.center.y - segment.bounds.height / 2,
            width: segment.bounds.width, height: segment.bounds.height
        )
    }

    /// The playhead the drag started from, so the seek is relative — the same
    /// rule the pages get, for the same reason: a thumb landing mid-bar must
    /// not throw the clip to the middle before it has moved.
    private var seekAnchor: Double?
    private var touchDownX: CGFloat = 0
    private var travelled = false

    /// How far a finger must move before it stops being a tap. A few points:
    /// enough to absorb the roll of a thumb, far less than the shortest
    /// deliberate drag.
    private static let travelThreshold: CGFloat = 6

    private func seek(draggedTo x: CGFloat) {
        guard let seekAnchor, let bar = barWidth, bar > 0 else { return }
        let moved = Double((x - touchDownX) / bar)
        let fraction = min(max(seekAnchor + moved, 0), 1)
        onSeekRequested?(fraction)
        onScrubPreview((fraction: fraction, x: x))
    }

    /// The drawn width of the segment carrying the clip's bar — the distance
    /// the whole clip is worth, which is what makes the seek 1:1 with the thumb.
    private var barWidth: CGFloat? {
        let centre = Int(position.rounded())
        guard segments.indices.contains(centre) else { return nil }
        return segments[centre].bounds.width
    }

    /// The segment under a point, for the tap. Absolute on purpose: a tap is an
    /// instruction to go somewhere, and the somewhere is where the thumb is.
    ///
    /// ⚠️ AMONG THE SEGMENTS ACTUALLY DRAWN. A clip's bar squeezes the pages
    /// beyond its neighbours to nothing, and a nearest-centre search that
    /// counted them would answer with a page that is not on the strip: a tap on
    /// the right-hand sliver of an eight-page post asked for page five, because
    /// five zero-width segments were stacked at that end.
    private func page(under x: CGFloat) -> Int {
        let drawn = segments.indices.filter { segments[$0].bounds.width > 1 }
        let hit = drawn.min { first, second in
            abs(segments[first].center.x - x) < abs(segments[second].center.x - x)
        }
        return hit ?? Int(position.rounded())
    }

    /// ⚠️ A STRIP THIS THIN NEEDS A TALLER TARGET. Six points is a legible
    /// mark and an unhittable control, so the touch area is grown to the
    /// platform's minimum around it — outward only, which costs the layout
    /// nothing because the band it grows into is the breathing room between
    /// the caption and the bar.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let grown = bounds.insetBy(dx: 0, dy: -(Self.minimumTouchHeight - bounds.height) / 2)
        return grown.contains(point)
    }

    private static let minimumTouchHeight: CGFloat = 44

    #if DEBUG
    /// Where a segment is drawn, so a spec can state the claims that make this
    /// view different from the dots: the segments SHARE the width, and the one
    /// you are on takes the larger share.
    ///
    /// Read from bounds + centre rather than `frame`, which is also how the
    /// layout assigns them.
    func debugSegmentFrame(_ index: Int) -> CGRect? { segmentFrame(index) }

    /// How strongly a segment is drawn — the mark, read without a screenshot.
    ///
    /// ⚠️ Both halves multiplied: the segment's own `alpha` carries presence and
    /// its colour carries the ink, and a reader asking "how strong is this"
    /// means the product. Reading either alone was how a track that dimmed its
    /// own fill went unnoticed.
    func debugSegmentAlpha(_ index: Int) -> CGFloat? {
        guard segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        var ink: CGFloat = 1
        segment.backgroundColor?.getWhite(nil, alpha: &ink)
        return segment.alpha * ink
    }

    /// Whether anything about a segment is animating.
    ///
    /// ⚠️ Kept after the accent was removed, because the claim it checks is now
    /// an ABSENCE — the strip is a function of the scroll and nothing about it
    /// animates on its own. An absence with no test is an absence that comes
    /// back.
    func debugSegmentIsAnimating(_ index: Int) -> Bool {
        guard segments.indices.contains(index) else { return false }
        return (segments[index].layer.animationKeys() ?? []).isEmpty == false
    }

    /// Drives the scrub without a finger; the simulator injects none.
    func debugScrub(_ state: UIGestureRecognizer.State, atX x: CGFloat) {
        handleScrub(state, atX: x)
    }

    /// What the counter reads, and how much room it takes from the run.
    var debugCounterText: String? { counterPlate.isHidden ? nil : counter.text }
    var debugCounterFrame: CGRect? {
        counterPlate.isHidden ? nil : CGRect(
            x: counterPlate.center.x - counterPlate.bounds.width / 2,
            y: counterPlate.center.y - counterPlate.bounds.height / 2,
            width: counterPlate.bounds.width, height: counterPlate.bounds.height
        )
    }

    /// How lit the strip is as a whole — the wake, which is a property of the
    /// container and not of any segment.
    var debugContainerOpacity: CGFloat { alpha }

    /// Runs the wake's clock out now, so a spec need not wait three seconds for
    /// a timer whose duration is not the claim under test.
    func debugElapseWake() {
        rest()
    }

    /// A press that lands and lifts without travelling — the tap.
    func debugTap(atX x: CGFloat) {
        handleScrub(.began, atX: x)
        handleScrub(.ended, atX: x)
    }

    /// The played part of a clip's bar, as a rectangle in the strip's own
    /// coordinates — nil when the page draws no bar.
    func debugFillFrame(_ index: Int) -> CGRect? {
        guard let fill = fills[index], !fill.isHidden, fill.alpha > 0.01 else { return nil }
        return fill.convert(fill.bounds, to: self)
    }
    #endif
}
