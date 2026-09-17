import UIKit

/// A row of icons where exactly one is chosen, and the choice can be **tapped or
/// slid to**.
///
/// **What it is not.** `PagedTabBar` is the bar for tabs standing over a pager:
/// its drag publishes a fractional page (`onScrub`) and the PAGER decides where
/// the pages land, announcing that itself. Seven screens are built that way and
/// it is the right shape for them. This is for a host with **no pager at all** —
/// options that switch a mode rather than turn a page — where that contract has
/// nothing on the other end of it. Upload's media editor spent a release fighting
/// it: reading `selectedIndex` back by hand, calling `setProgress` on itself, and
/// still needing a tap after every slide, because a drag legitimately announced
/// nothing.
///
/// So the contract here is the whole of it: **N items, one selected, one event
/// when the selection changes** — from a tap and from a settled slide alike.
///
/// **Why icons.** The words did not fit. Four titles already overran the editor's
/// toolbar, leaving the fourth unreachable by tap; a symbol is a fixed 36pt
/// square, so five fit in 188pt where four words did not fit at all. Overflow
/// still happens once there are enough of them, which is why the pill slides and
/// why a finger held at either end keeps the strip moving.
///
/// ⚠️ **ONE MATERIAL, NEVER TWO.** The capsule is a `UIGlassEffect`; the
/// selection lens is a plain tinted `UIView`, not a second effect view.
/// `PagedTabBar` records what the other way costs: a glass lens inside a glass
/// capsule loses its edge entirely and the selected item stops reading as
/// selected, which is the one thing this control exists to say.
///
/// ⚠️ **THE EFFECT IS SET IN `didMoveToWindow`, NOT IN `init`.** Materialising a
/// blur or glass in a property initialiser contacts the render server, which on a
/// headless CI simulator has stalled the main actor for tens of seconds and
/// starved unrelated tests. Five components in this app state it the same way.
@MainActor
public final class IconSelectorBar: UIView {
    /// One choosable icon.
    ///
    /// The label is required rather than derived: a symbol name is not a word a
    /// screen reader can say, and "crop.rotate" is not "Crop and straighten".
    public struct Item: Sendable, Equatable {
        public let symbolName: String
        public let accessibilityLabel: String

        public init(symbolName: String, accessibilityLabel: String) {
            self.symbolName = symbolName
            self.accessibilityLabel = accessibilityLabel
        }
    }

    /// The selection changed — by tap, or by a slide that settled.
    ///
    /// ⚠️ **ONE CHANNEL FOR BOTH GESTURES, WHICH IS THE POINT.** The bar this
    /// replaces had a tap announce through `.valueChanged` and a drag announce
    /// nothing, on the reasoning that a pager would answer for the drag. With no
    /// pager the drag simply went unheard, and the host needed a tap to finish
    /// what a slide had already decided.
    public var onSelect: ((Int) -> Void)?

    public private(set) var selectedIndex: Int = 0

    /// The host draws the capsule; this one draws none.
    ///
    /// ⚠️ **SET THIS INSIDE A BAR.** The iOS 26 toolbar and navigation bar
    /// composite every custom view through their own neutral glass platter, so a
    /// control carrying its own backdrop renders as a bubble inside a bubble —
    /// a defect this repository has already shipped once, in the picker's first
    /// cut. The platter is also 4pt larger than the view it hosts, so the outer
    /// clearance goes to zero with it: keeping both would double the ring.
    public var suppressesBackdrop: Bool = false {
        didSet {
            guard suppressesBackdrop != oldValue else { return }
            if suppressesBackdrop {
                capsule.effect = nil
            } else if window != nil {
                materialiseCapsule()
            }
            rowLeading?.constant = outerInset
            rowTrailing?.constant = -outerInset
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// The clearance this view keeps around its own row — nil when something
    /// else is supplying it.
    private var outerInset: CGFloat { suppressesBackdrop ? 0 : Metrics.lensInset }

    /// The pill's own clearance inside its segment — nil when something else is
    /// supplying it, so the two never stack.
    private var lensClearance: CGFloat { suppressesBackdrop ? 0 : Metrics.lensInset }

    /// The pill's side, which grows to the whole segment when the clearance goes.
    private var lensSide: CGFloat { Metrics.segmentSide - lensClearance * 2 }

    private enum Metrics {
        /// The square each icon occupies. Stated once for every icon bar in
        /// `IconBarMetrics`, because the action bar sits beside this one.
        static var segmentSide: CGFloat { IconBarMetrics.segmentSide }
        /// Capsule edge to selection pill.
        ///
        /// ⚠️ **ONE NUMBER GOVERNS BOTH GAPS, AND THAT IS WHY IT IS SMALL.**
        /// Shrinking this grows the pill by twice as much, which is the trade
        /// asked for: the pill sits closer to the capsule and the icon gets more
        /// air inside it. Two numbers here would let the pill drift off centre
        /// vertically without any arithmetic disagreeing — the shape of the defect
        /// `PagedTabBar` records from having had 5 horizontally and 4 vertically.
        static var lensInset: CGFloat { IconBarMetrics.clearance }
        /// The selection background, when this view draws its own capsule. What
        /// is left of a segment once the clearance is taken off both sides.
        ///
        /// ⚠️ **INSIDE A BAR THE CLEARANCE IS THE PLATTER'S, AND THIS ONE GOES TO
        /// ZERO.** A toolbar's platter is 4pt larger than the view it hosts, so
        /// keeping a clearance of our own stacks on top of it: the pill reads 6pt
        /// off the edge where `PagedTabBar`, which zeroes its own padding for
        /// exactly this reason, reads 4. Matching the rest of the app is therefore
        /// not a smaller number picked by eye — it is the same rule.
        static var lensSide: CGFloat { segmentSide - lensInset * 2 }
        static var interSegmentSpacing: CGFloat { IconBarMetrics.interSegmentSpacing }
        static var capsuleHeight: CGFloat { segmentSide }
        /// How far a finger travels before a press on the pill stops being a tap.
        static let dragSlop: CGFloat = 3
        /// How close to an end a dragging finger must be before the strip moves.
        static let edgeZone: CGFloat = 36
        /// Points per second while a finger is held in the corner.
        static let edgeScrollSpeed: CGFloat = 520
        static let settle: TimeInterval = 0.25
        /// Below this, the finger was PLACING the pill rather than throwing it,
        /// and the release must not move it. In items per second: roughly one
        /// segment's width covered in a third of a second.
        static let flickSpeed: CGFloat = 3
        /// How much of the new reading a speed sample takes, so one jittery frame
        /// at the moment of release cannot decide the landing on its own. The
        /// symptom of no smoothing is a drag that lands correctly most of the time
        /// — which is the hardest kind of defect to trust a fix for.
        static let speedSmoothing: CGFloat = 0.4
    }

    /// The bar's own height, so a host can lay it out before it has items.
    public static var height: CGFloat { Metrics.capsuleHeight }

    private static var lensTint: UIColor { IconBarMetrics.lensTint }

    private var items: [Item]
    private let capsule = UIVisualEffectView(effect: nil)
    private let scroller = UIScrollView()
    private let content = UIView()
    /// The active marker. A tint, not a material — see the type comment.
    private let lens = UIView()
    private let row = UIStackView()
    private var buttons: [UIButton] = []
    /// Fractional position of the lens, in item units. Only meaningful during a
    /// drag and its settle; at rest it equals `selectedIndex`.
    private var progress: CGFloat = 0

    private struct Drag {
        /// Where the finger sits relative to the lens's centre, so a pill picked
        /// up off-centre does not jump under the finger.
        let grip: CGFloat
        let start: CGFloat
        var lastProgress: CGFloat
        var lastMoment: CFTimeInterval
        var speed: CGFloat
        var moved: Bool
    }
    private var drag: Drag?
    private var rowLeading: NSLayoutConstraint?
    private var rowTrailing: NSLayoutConstraint?
    private var edgeLink: CADisplayLink?
    private var lastTouchX: CGFloat = 0

    public init(items: [Item]) {
        self.items = items
        super.init(frame: .zero)
        build()
        rebuildSegments()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Building

    private func build() {
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.clipsToBounds = true
        addSubview(capsule)

        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.showsHorizontalScrollIndicator = false
        scroller.showsVerticalScrollIndicator = false
        // The lens is dragged across this; a bounce would fight the grip.
        scroller.bounces = false
        capsule.contentView.addSubview(scroller)

        content.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(content)

        // ⚠️ THE LENS LIVES IN THE SCROLLED CONTENT, not in the capsule. Pinned
        // outside it, every frame of both gestures would have to subtract the
        // content offset back out of its position.
        lens.backgroundColor = Self.lensTint
        lens.isUserInteractionEnabled = false
        lens.layer.cornerCurve = .continuous
        content.addSubview(lens)

        row.axis = .horizontal
        row.spacing = Metrics.interSegmentSpacing
        row.alignment = .fill
        // ⚠️ **`.fill` WITH FIXED SEGMENTS, NEVER `.fillEqually`.** Equal
        // distribution stretches the segments to whatever width the bar is given,
        // while the lens is placed on a fixed stride — so the two agree only when
        // the bar happens to be exactly its intrinsic width, and drift apart by
        // more at every index after that. Measured at 15.8pt on the third icon
        // inside a toolbar. Fixed widths make the arithmetic and the layout the
        // same statement, and make the overflow real: the content outgrows the
        // viewport and scrolls, rather than spreading to fill it.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)

        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),

            scroller.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor),
            scroller.topAnchor.constraint(equalTo: capsule.contentView.topAnchor),
            scroller.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor),

            content.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            content.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),

            rowLeadingConstraint(),
            rowTrailingConstraint(),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let grab = UILongPressGestureRecognizer(target: self, action: #selector(handleGrab))
        grab.minimumPressDuration = 0
        // The default cancels a press that travels, and travelling is the point.
        grab.allowableMovement = .greatestFiniteMagnitude
        // ⚠️ FALSE: cancelling would take the touch from the button under the
        // finger, and a tap on the already-selected icon is a real request. The
        // drag takes the touch by hand instead, once it has actually moved.
        grab.cancelsTouchesInView = false
        grab.delaysTouchesBegan = false
        grab.delaysTouchesEnded = false
        grab.delegate = self
        addGestureRecognizer(grab)
    }

    private func rowLeadingConstraint() -> NSLayoutConstraint {
        let constraint = row.leadingAnchor.constraint(
            equalTo: content.leadingAnchor, constant: outerInset
        )
        rowLeading = constraint
        return constraint
    }

    private func rowTrailingConstraint() -> NSLayoutConstraint {
        let constraint = row.trailingAnchor.constraint(
            equalTo: content.trailingAnchor, constant: -outerInset
        )
        rowTrailing = constraint
        return constraint
    }

    private func rebuildSegments() {
        for button in buttons {
            row.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons = items.enumerated().map { index, item in
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = .zero
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = item.accessibilityLabel
            button.addAction(
                UIAction { [weak self] _ in self?.tapped(index) }, for: .primaryActionTriggered
            )
            row.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: Metrics.segmentSide).isActive = true
            return button
        }
        selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
        progress = CGFloat(selectedIndex)
        applySelectionAppearance()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    public func setItems(_ newItems: [Item]) {
        guard newItems != items else { return }
        items = newItems
        rebuildSegments()
    }

    // MARK: - Choosing

    /// Chooses an item exactly as a tap would.
    ///
    /// `notify: false` is for a host adopting a stored choice before the viewer
    /// has touched anything — telling it about its own decision is noise.
    public func select(_ index: Int, notify: Bool = true) {
        guard items.indices.contains(index) else { return }
        let changed = index != selectedIndex
        selectedIndex = index
        progress = CGFloat(index)
        applySelectionAppearance()
        applyProgress()
        keepLensVisible(animated: false)
        if changed, notify { onSelect?(index) }
    }

    private func tapped(_ index: Int) {
        guard index != selectedIndex else { return }
        UIView.animate(withDuration: Metrics.settle, delay: 0, options: [.curveEaseOut]) {
            self.selectedIndex = index
            self.progress = CGFloat(index)
            self.applyProgress()
            self.keepLensVisible(animated: false)
        }
        applySelectionAppearance()
        onSelect?(index)
    }

    private func applySelectionAppearance() {
        for (index, button) in buttons.enumerated() {
            let item = items[index]
            let isSelected = index == selectedIndex
            // Selection = the filled variant where the symbol has one, which is
            // the rule `GlassSegmentRow` already follows.
            let name = isSelected ? item.symbolName + ".fill" : item.symbolName
            let image = UIImage(systemName: name) ?? UIImage(systemName: item.symbolName)
            button.configuration?.image = image
            button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
        }
    }

    // MARK: - Layout

    public override var intrinsicContentSize: CGSize {
        CGSize(
            width: IconBarMetrics.intrinsicWidth(count: items.count, outerInset: outerInset),
            height: Metrics.capsuleHeight
        )
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // ⚠️ SHAPE BEFORE MATERIAL. `didMoveToWindow` can land before the first
        // layout pass has given the capsule real bounds, and a glass effect
        // switched on over a zero-radius layer draws one frame of hard corners.
        capsule.layer.cornerCurve = .continuous
        capsule.layer.cornerRadius = bounds.height / 2
        lens.layer.cornerRadius = lensSide / 2
        applyProgress()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, capsule.effect == nil, !suppressesBackdrop else { return }
        materialiseCapsule()
    }

    private func materialiseCapsule() {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        capsule.effect = glass
    }

    /// Puts the lens where `progress` says, in the scrolled content's space.
    private func applyProgress() {
        guard !buttons.isEmpty else { return }
        let stride = Metrics.segmentSide + Metrics.interSegmentSpacing
        // Centred in its segment, horizontally AND vertically, from the one
        // clearance number — so the pill cannot drift on one axis only.
        let centring = (Metrics.segmentSide - lensSide) / 2
        lens.frame = CGRect(
            x: outerInset + centring + progress * stride,
            y: (bounds.height - lensSide) / 2,
            width: lensSide, height: lensSide
        )
    }

    /// Brings the lens back into the viewport by the minimum that shows it.
    private func keepLensVisible(animated: Bool) {
        guard scroller.bounds.width > 0 else { return }
        let visible = CGRect(origin: scroller.contentOffset, size: scroller.bounds.size)
        var offset = scroller.contentOffset.x
        if lens.frame.minX < visible.minX {
            offset = lens.frame.minX - Metrics.lensInset
        } else if lens.frame.maxX > visible.maxX {
            offset = lens.frame.maxX + Metrics.lensInset - scroller.bounds.width
        }
        let maximum = max(0, scroller.contentSize.width - scroller.bounds.width)
        offset = min(max(0, offset), maximum)
        guard abs(offset - scroller.contentOffset.x) > 0.5 else { return }
        scroller.setContentOffset(CGPoint(x: offset, y: 0), animated: animated)
    }
}

// MARK: - Sliding the pill

extension IconSelectorBar: UIGestureRecognizerDelegate {
    /// ⚠️ **ONLY A TOUCH THAT LANDS ON THE LENS PICKS IT UP.** A touch anywhere
    /// else on the capsule belongs to the strip, which scrolls, or to the button
    /// under it, which selects. Asked at touch-down, where "did this land on the
    /// pill" has an answer; ten points later it is a guess.
    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        acceptsGrab(at: gestureRecognizer.location(in: content))
    }

    /// ⚠️ ONE ROUTINE, because the debug entry point below uses it too. A test
    /// that re-implemented this predicate would be testing its own copy, and the
    /// half it got wrong would be exactly the half with no coverage.
    private func acceptsGrab(at point: CGPoint) -> Bool {
        guard items.count > 1 else { return false }
        // ⚠️ THE INFLATION FOLLOWS THE PILL. It was a fixed 2pt, written when the
        // pill was inset inside its segment; now that the pill fills the segment
        // in a bar, a fixed inflation overlaps both neighbours and steals touches
        // meant for them.
        let reach = lensClearance
        return lens.frame.insetBy(dx: -reach, dy: -reach).contains(point)
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        false
    }

    @objc private func handleGrab(_ grab: UILongPressGestureRecognizer) {
        let x = grab.location(in: capsule.contentView).x
        switch grab.state {
        case .began: beginDrag(at: x)
        case .changed: track(to: x)
        case .ended, .cancelled, .failed: endDrag()
        default: break
        }
    }

    private func beginDrag(at x: CGFloat) {
        lastTouchX = x
        drag = Drag(
            grip: x + scroller.contentOffset.x - lens.frame.midX,
            start: x,
            lastProgress: progress,
            lastMoment: CACurrentMediaTime(),
            speed: 0,
            moved: false
        )
        // ⚠️ **THE STRIP STANDS DOWN — a lock, not a `require(toFail:)`.** A
        // failure requirement into a scroll view's recognizer graph froze a whole
        // subtree once in this codebase; suspending the competing scroller for
        // the life of the gesture is what replaced it. A disabled scroll view
        // still accepts a `contentOffset` assignment, which is the only way this
        // drag moves it anyway.
        scroller.isScrollEnabled = false
        startEdgeScroll()
    }

    private func track(to x: CGFloat, at now: CFTimeInterval = CACurrentMediaTime()) {
        guard var current = drag, buttons.count > 1 else { return }
        lastTouchX = x
        // ⚠️ BELOW THE SLOP, NOTHING MOVES AT ALL. A finger resting on the icon
        // it already has is a tap, and a tap must leave everything where it found
        // it — including the end-of-strip scroll, which must not arm for a press
        // that never travelled.
        if !current.moved {
            guard abs(x - current.start) > Metrics.dragSlop else { return }
            current.moved = true
            // The clock starts here, not at touch-down: a press held still for
            // half a second would otherwise average its velocity over the wait
            // and report a flick as a crawl.
            current.lastProgress = progress
            current.lastMoment = now
            cancelButtonTracking()
        }

        let stride = Metrics.segmentSide + Metrics.interSegmentSpacing
        let centre = x + scroller.contentOffset.x - current.grip
        let raw = (centre - Metrics.lensInset - Metrics.lensSide / 2) / stride
        let clamped = min(max(0, raw), CGFloat(items.count - 1))

        let elapsed = now - current.lastMoment
        if elapsed > 0 {
            let sample = (clamped - current.lastProgress) / CGFloat(elapsed)
            // ⚠️ BLENDED, NOT REPLACED. A single sample is one frame's worth of
            // finger, and the frame that happens to be last is the one that
            // decides where a release lands.
            current.speed = current.speed * (1 - Metrics.speedSmoothing)
                + sample * Metrics.speedSmoothing
            current.lastProgress = clamped
            current.lastMoment = now
        }
        drag = current

        progress = clamped
        applyProgress()
        keepLensVisible(animated: false)
    }

    private func endDrag() {
        guard let current = drag else { return }
        drag = nil
        stopEdgeScroll()
        scroller.isScrollEnabled = true
        // A press that never travelled is a tap, and the button under it has
        // already answered. Publishing a settle here would re-commit the host to
        // the item it is already on.
        guard current.moved else { return }

        let landing = landingIndex(from: progress, speed: current.speed)
        let changed = landing != selectedIndex
        selectedIndex = landing
        applySelectionAppearance()
        UIView.animate(withDuration: Metrics.settle, delay: 0, options: [.curveEaseOut]) {
            self.progress = CGFloat(landing)
            self.applyProgress()
            self.keepLensVisible(animated: false)
        }
        // ⚠️ ONLY A REAL CHANGE. A drag that wandered off an icon and came back
        // changed nothing and must say nothing, or every host is told to re-open
        // the mode it is already showing.
        guard changed else { return }
        onSelect?(landing)
    }

    /// Where a release commits.
    ///
    /// ⚠️ **NOT `position + speed * 0.5`, WHICH IS THE PAGER FIGURE AND IS WRONG
    /// HERE BY ABOUT AN ORDER OF MAGNITUDE.** That half-second of throw is sized
    /// for pages a screen wide. A segment here is 38pt, and the speed is in ITEMS
    /// per second, so a finger still drifting at 100pt/s on release — imperceptible
    /// — projects 1.3 items past where it stopped, and 300pt/s projects four.
    /// Reported as "I stop on an icon and it goes to the one next to it".
    ///
    /// So the rule is the one a viewer actually expects: **place it and it stays
    /// where you placed it; flick it and it moves exactly one.** Never more than
    /// one, because there is no gesture on a 38pt strip that means "three along".
    private func landingIndex(from position: CGFloat, speed: CGFloat) -> Int {
        let nearest = Int(position.rounded())
        guard abs(speed) >= Metrics.flickSpeed else { return clampedIndex(nearest) }
        // From the icon the finger is OVER, not from the nearest — a flick begun
        // at 2.6 carries to 3, not to 4.
        let carried = speed > 0
            ? Int(position.rounded(.down)) + 1
            : Int(position.rounded(.up)) - 1
        return clampedIndex(carried)
    }

    private func clampedIndex(_ index: Int) -> Int {
        min(max(index, 0), max(0, items.count - 1))
    }

    /// ⚠️ **THE DRAGGED BUTTON HAS TO STOP TRACKING, OR THE DRAG ENDS AS A TAP.**
    /// This recognizer deliberately does not cancel touches in view, so the button
    /// under the finger keeps tracking for the whole drag and fires its action if
    /// the finger happens to lift back inside it.
    private func cancelButtonTracking() {
        for button in buttons { button.cancelTracking(with: nil) }
    }

    // MARK: - The ends of the strip

    /// ⚠️ `keepLensVisible` IS NOT ENOUGH ON ITS OWN. It moves the strip when the
    /// pill is dragged past an edge, but it is driven by movement — a finger held
    /// still at the end of a crowded strip would stop the world, with the icon it
    /// is reaching for two segments away and nothing bringing it closer.
    private func startEdgeScroll() {
        guard edgeLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(stepEdgeScroll))
        // `.common`, so it survives the tracking run loop — the only mode this
        // ever runs in, since a finger is down for all of it.
        link.add(to: .main, forMode: .common)
        edgeLink = link
    }

    private func stopEdgeScroll() {
        edgeLink?.invalidate()
        edgeLink = nil
    }

    @objc private func stepEdgeScroll(_ link: CADisplayLink) {
        guard let current = drag, current.moved, scroller.bounds.width > 0 else { return }
        let width = scroller.bounds.width
        let maximum = max(0, scroller.contentSize.width - width)
        guard maximum > 0.5 else { return }

        var direction: CGFloat = 0
        if lastTouchX > width - Metrics.edgeZone { direction = 1 }
        if lastTouchX < Metrics.edgeZone { direction = -1 }
        guard direction != 0 else { return }

        let step = Metrics.edgeScrollSpeed * CGFloat(link.duration) * direction
        let next = min(max(0, scroller.contentOffset.x + step), maximum)
        guard abs(next - scroller.contentOffset.x) > 0.01 else { return }
        scroller.contentOffset.x = next
        // The strip moved under a still finger, which is the same relationship
        // changing as the finger moving over a still strip.
        track(to: lastTouchX)
    }
}

#if DEBUG
extension IconSelectorBar {
    public var debugItemCount: Int { items.count }
    public var debugLensFrame: CGRect { lens.frame }
    public var debugStripOffset: CGFloat { scroller.contentOffset.x }
    public var debugStripAcceptsScrolling: Bool { scroller.isScrollEnabled }
    public var debugEdgeScrollIsArmed: Bool { edgeLink != nil }
    public var debugIsSelectedFilled: Bool {
        guard buttons.indices.contains(selectedIndex) else { return false }
        return buttons[selectedIndex].configuration?.image != nil
    }

    /// The drag, entered through the same three functions the recognizer calls —
    /// the shipping path, not a copy of it.
    public func debugBeginDrag(atX x: CGFloat) { beginDrag(at: x) }
    public func debugDrag(toX x: CGFloat, after seconds: CFTimeInterval = 1.0 / 60.0) {
        track(to: x, at: CACurrentMediaTime() + seconds)
    }
    public func debugEndDrag() { endDrag() }
    public func debugStepEdgeScroll() {
        guard let link = edgeLink else { return }
        stepEdgeScroll(link)
    }
    public var debugLensCentreX: CGFloat { lens.frame.midX }
    public var debugHasCapsuleMaterial: Bool { capsule.effect != nil }
    public var debugLensSide: CGFloat { lensSide }
    public func debugLanding(from position: CGFloat, speed: CGFloat) -> Int {
        landingIndex(from: position, speed: speed)
    }

    /// A tap on a segment, through the SAME routine the button's action calls.
    /// `select(_:notify:)` is the programmatic door and takes a different path;
    /// a test that used it would be testing the wrong one.
    public func debugTap(_ index: Int) { tapped(index) }

    /// Whether a touch at this point in the scrolled content would pick the pill
    /// up — the same predicate the recognizer is asked.
    public func debugAcceptsGrab(at point: CGPoint) -> Bool { acceptsGrab(at: point) }

    /// The pill and the segment it claims to be on, in one coordinate space.
    ///
    /// ⚠️ TWO RECTANGLES, NOT A BOOLEAN. "Is the pill on the right segment" has
    /// an answer a test can print when it fails; `isAligned` has one nobody can
    /// diagnose from.
    public var debugLensAlignment: (lens: CGRect, segment: CGRect)? {
        guard buttons.indices.contains(selectedIndex) else { return nil }
        let button = buttons[selectedIndex]
        return (lens.frame, button.convert(button.bounds, to: content))
    }
}
#endif
