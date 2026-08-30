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

    private var segments: [UIView] = []
    /// The played part of each segment — minted only for the page that is a
    /// clip, because that is the only one that ever draws it.
    private var fills: [Int: UIView] = [:]
    private var pageCount = 0
    /// Which pages carry a clip: the strip draws those differently and reads a
    /// drag on them differently.
    private var clipPages: Set<Int> = []
    /// How far through the clip on the page the viewer is on, when there is one
    /// and its length is known. Nil draws nothing rather than zero — see
    /// `VideoPlaybackController.playhead`.
    private var playhead: Double?
    /// Where the carousel is, in fractional pages — the strip's entire state.
    private var position: CGFloat = 0
    /// The shared arithmetic; its scale is set from the layout, below.
    private var scrubber = PageScrubber(pointsPerPage: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isExclusiveTouch = true
        scrubGesture.addTarget(self, action: #selector(handleScrubGesture))
        addGestureRecognizer(scrubGesture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.thickness)
    }

    /// One segment per page. Hidden entirely below two — a single picture has
    /// no position to report, and one full-width pill would claim it did.
    ///
    /// ⚠️ A SINGLE CLIP IS STILL A SINGLE PICTURE. A one-page post keeps no
    /// strip even when it is a video: the post screen's clip has no pages to
    /// index, and a lone progress bar under the caption is a different feature
    /// from this one — it would need its own answer about what a drag on it
    /// means while the page can also be swiped away.
    func configure(count: Int, current: Int, clipPages: Set<Int> = []) {
        self.clipPages = clipPages
        pageCount = count
        isHidden = count < 2
        guard count >= 2 else { return }
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
        setNeedsLayout()
        layoutIfNeeded()
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
    }

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
        let clipWeights = clipness > 0 ? clipShapeWeights(available: bounds.width) : nil
        let shown = segments.indices.map { index -> CGFloat in
            guard let clipWeights else { return rooms[index] }
            let inTheClipsShape: CGFloat = clipWeights[index] > 0 ? 1 : 0
            return rooms[index] * (1 - clipness * (1 - inTheClipsShape))
        }
        // A gap belongs to a seam, and a seam is only as present as the thinner
        // of the two segments it separates.
        let gaps = segments.indices.dropLast().map { Self.gap * min(shown[$0], shown[$0 + 1]) }
        let available = max(bounds.width - gaps.reduce(0, +), 1)
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
        // ⚠️ THE SCRUB TRACKS THE STRIP IT IS DRAWN ON. One page per average
        // slot, so the mark keeps pace with the thumb — the same rule as the
        // card's chip, at this strip's own scale. The AVERAGE, not the active
        // segment's own width, or the gesture's scale would change as it
        // travelled. Off the WINDOW, not the count: with a long run the thumb
        // still walks one slot per page, and the pages beyond simply arrive.
        scrubber.pointsPerPage = (bounds.width + Self.gap) / CGFloat(visible)
    }

    /// How much of the page under the viewer is a clip: 1 on one, 0 on a
    /// photograph, and shared across a swipe between the two.
    private var clipPageProximity: CGFloat {
        clipPages.reduce(0) { max($0, proximity(toPage: $1)) }
    }

    /// The widths the strip would have if the page under the viewer were wholly
    /// a clip: slivers for the neighbours, everything else for the bar, nothing
    /// at all for the pages beyond them.
    private func clipShapeWeights(available: CGFloat) -> [CGFloat] {
        let centre = Int(position.rounded())
        let sliver = Self.clipNeighbourWidth
        let neighbours = segments.indices.filter { abs($0 - centre) == 1 }
        let bar = max(available - sliver * CGFloat(neighbours.count), 1)
        return segments.indices.map { index in
            if index == centre { return bar }
            return abs(index - centre) == 1 ? sliver : 0
        }
    }

    /// The played part of a clip's bar, drawn inside the segment that carries
    /// it. Minted on the page that needs one and never on any other.
    private func layoutFill(onPage index: Int, width: CGFloat, clipness: CGFloat) {
        let isBar = clipPages.contains(index) && clipness > 0 && index == Int(position.rounded())
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
        fill.alpha = clipness
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
        guard pageCount >= 2 else { return }
        switch state {
        case .began:
            touchDownX = x
            travelled = false
            scrubber.begin(atX: x, page: Int(position.rounded()))
            seekAnchor = playhead
        case .changed:
            if abs(x - touchDownX) > Self.travelThreshold { travelled = true }
            guard travelled else { return }
            if isScrubbingAClip {
                seek(draggedTo: x)
            } else if let page = scrubber.page(draggedTo: x, pageCount: pageCount) {
                onPageRequested?(page)
            }
        case .ended:
            guard !travelled else { return }
            onPageRequested?(page(under: x))
        default:
            break
        }
    }

    /// Whether this drag is moving the playhead rather than the pages: the page
    /// the viewer is ON carries a clip, and the strip is drawn as its bar.
    private var isScrubbingAClip: Bool {
        clipPages.contains(Int(position.rounded())) && playhead != nil
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
        onSeekRequested?(min(max(seekAnchor + moved, 0), 1))
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
    func debugSegmentFrame(_ index: Int) -> CGRect? {
        guard segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        return CGRect(
            x: segment.center.x - segment.bounds.width / 2,
            y: segment.center.y - segment.bounds.height / 2,
            width: segment.bounds.width, height: segment.bounds.height
        )
    }

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
