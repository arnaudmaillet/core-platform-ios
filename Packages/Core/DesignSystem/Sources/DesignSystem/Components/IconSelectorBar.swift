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

    /// The item that is ALREADY selected was tapped.
    ///
    /// ⚠️ **A SECOND CHANNEL, NOT A LOOSER `onSelect`.** `onSelect` is silent on
    /// a repeat tap and must stay so — a host that rebuilds its mode on every
    /// announcement would rebuild it for a tap that chose nothing. But a mode
    /// whose tools can be put away (the media editor's Effects is selected at
    /// launch with an empty band) needs a way back in, and the only gesture
    /// left is a tap on the icon already chosen. Taps only: a slide that comes
    /// home is not a request for anything.
    public var onReselect: ((Int) -> Void)?

    /// The bar went neutral — nothing is chosen any more.
    ///
    /// ⚠️ **A CHANNEL OF ITS OWN, NOT A SENTINEL THROUGH `onSelect`.** An index
    /// of -1 travelling down a path typed `Int` is a value every caller has to
    /// remember to refuse, and the ones that forget clamp it back to the first
    /// item — which is how `rebuildSegments` used to lose a selection.
    public var onSelectNothing: (() -> Void)?

    public private(set) var selectedIndex: Int = 0

    /// Whether NOTHING is chosen.
    ///
    /// ⚠️ **A STATE THE BAR COULD NOT HOLD, AND A HOST NEEDED.** `selectedIndex`
    /// is an `Int` with no room for "none" — -1 is refused by `select(_:)` and
    /// clamped away by `rebuildSegments` — so a screen whose tools can all be
    /// put away had to keep pretending one of them was open. The media editor
    /// opens on nothing, and a second tap on the chosen icon puts its tools away
    /// again. `IconActionBar` has held the same shape since it was written
    /// (`activeIndex: Int?`), which is where the lens-hiding below comes from.
    ///
    /// `selectedIndex` keeps its last value while neutral, so a host that asks
    /// "which one was it" still gets an answer; `selection` is the one to read
    /// for "which one is it NOW".
    public private(set) var isNeutral = false

    /// The chosen item, or nil while the bar is neutral.
    public var selection: Int? { isNeutral ? nil : selectedIndex }

    /// Who draws the capsule — see `SelectorHosting` for the one rule the three
    /// selectors share.
    ///
    /// ⚠️ **`.platter` INSIDE A BAR.** The iOS 26 toolbar and navigation bar
    /// composite every custom view through their own neutral glass platter, so a
    /// control carrying its own backdrop renders as a bubble inside a bubble —
    /// a defect this repository has already shipped once, in the picker's first
    /// cut. The platter is also 4pt larger than the view it hosts, so the pill's
    /// clearance inside the view goes to zero with it: keeping both would double
    /// the ring. What does NOT go to zero is the capsule: it is laid out at the
    /// platter's size, reaching beyond this view, so the strip scrolls its
    /// icons right up to the glass the viewer sees.
    public var hosting: SelectorHosting = .standalone {
        didSet {
            guard hosting != oldValue else { return }
            if !hosting.drawsBackdrop {
                capsule.effect = nil
            } else if window != nil {
                materialiseCapsule()
            }
            applyHosting()
        }
    }

    /// How far the visible capsule reaches beyond this view, per axis — and so,
    /// how far inside the capsule the row begins. Measured once the bar is in a
    /// platter and in a window; the hosting's stated number until then.
    private var platterOverhang: CGSize?
    private var overhangX: CGFloat { platterOverhang?.width ?? hosting.overhang }
    private var overhangY: CGFloat { platterOverhang?.height ?? hosting.overhang }

    /// The pill's own clearance inside its segment: the visible clearance less
    /// what the ring above and below already supplies, so the two never stack.
    /// NEGATIVE in a ring deeper than the clearance — the pill then reaches
    /// past the segment, so that it still stands the same 4pt off the glass.
    private var lensClearance: CGFloat { Metrics.clearance - overhangY }

    /// Re-states every constant that follows from the hosting and the ring.
    private func applyHosting() {
        for (edge, reach) in zip(capsuleEdges, [-overhangX, overhangX, -overhangY, overhangY]) {
            edge.constant = reach
        }
        rowLeading?.constant = overhangX
        rowTrailing?.constant = -overhangX
        rowTop?.constant = overhangY
        rowBottom?.constant = -overhangY
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// Takes the platter's real reach once there is one to measure — see
    /// `SelectorHosting.measuredPlatterOverhang(around:)`. Guarded on change.
    private func measurePlatterIfHosted() {
        let measured = hosting == .platter ? SelectorHosting.measuredPlatterOverhang(around: self) : nil
        if hosting == .platter, window != nil {
            remeasure.arm { [weak self] in self?.measurePlatterIfHosted() }
        } else {
            remeasure.reset()
        }
        guard measured != platterOverhang else { return }
        platterOverhang = measured
        applyHosting()
    }

    /// The re-asks that land the platter's true reach — see
    /// `PlatterRemeasureSchedule` for why one measurement is not enough.
    private let remeasure = PlatterRemeasureSchedule()

    /// The pill's side, which grows to the whole segment when the clearance goes.
    private var lensSide: CGFloat { Metrics.segmentSide - lensClearance * 2 }

    /// The capsule's four edges, whose constants ARE the overhang.
    private var capsuleEdges: [NSLayoutConstraint] = []

    // MARK: - The lens as Liquid Glass (SPIKE) — see `SelectorGlassLens`

    /// Whether the selection pill is a Liquid Glass lens that lifts while it
    /// is held or travelling — `SelectorGlassLens`, shared with `PagedTabBar`.
    /// This bar says when: a grab, or a tap on another icon; it lands on the
    /// icon the bar itself settles on.
    public var liftsLensAsGlass = SelectorGlassLens.isAskedFor
    private var glassLens: SelectorGlassLens?

    private enum Metrics {
        /// How faint a resting item is drawn — the shape the camera locks.
        static let restingAlpha: CGFloat = 0.35
        /// The square each icon occupies. Stated once for every icon bar in
        /// `IconBarMetrics`, because the action bar sits beside this one.
        static var segmentSide: CGFloat { IconBarMetrics.segmentSide }
        /// Visible capsule edge to selection pill, on every side and every host.
        ///
        /// ⚠️ **ONE NUMBER GOVERNS BOTH GAPS.** Two numbers here would let the
        /// pill drift off centre vertically without any arithmetic disagreeing —
        /// the shape of the defect `PagedTabBar` records from having had 5
        /// horizontally and 4 vertically. Inside a platter the number is the
        /// platter's own, and the pill's clearance INSIDE THIS VIEW is zero —
        /// see `hosting`.
        static var clearance: CGFloat { IconBarMetrics.clearance }
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
    private var rowTop: NSLayoutConstraint?
    private var rowBottom: NSLayoutConstraint?
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

        // ⚠️ THE CAPSULE IS THE VISIBLE ONE, NOT THIS VIEW. Inside a platter it
        // reaches `overhang` beyond every edge, so that its clip — and the
        // scroll viewport inside it — end where the viewer sees the glass end
        // rather than 4pt short of it. This view does not clip; the capsule
        // does, at the visible capsule's own radius.
        capsuleEdges = [
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -overhangX),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: overhangX),
            capsule.topAnchor.constraint(equalTo: topAnchor, constant: -overhangY),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: overhangY)
        ]
        NSLayoutConstraint.activate(capsuleEdges + [
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
            rowTopConstraint(),
            rowBottomConstraint()
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

    /// The row begins `overhang` inside the scrolled content — the platter's
    /// own ring, which is scroll CONTENT here, not a margin of the viewport: a
    /// crowded strip carries its first icon under the ring and out to the edge.
    private func rowLeadingConstraint() -> NSLayoutConstraint {
        let constraint = row.leadingAnchor.constraint(
            equalTo: content.leadingAnchor, constant: overhangX
        )
        rowLeading = constraint
        return constraint
    }

    /// The same on the vertical axis: the icons stay in this view's rect, and a
    /// platter's capsule stands `overhang` above and below them.
    private func rowTopConstraint() -> NSLayoutConstraint {
        let constraint = row.topAnchor.constraint(equalTo: content.topAnchor, constant: overhangY)
        rowTop = constraint
        return constraint
    }

    private func rowBottomConstraint() -> NSLayoutConstraint {
        let constraint = row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -overhangY)
        rowBottom = constraint
        return constraint
    }

    private func rowTrailingConstraint() -> NSLayoutConstraint {
        let constraint = row.trailingAnchor.constraint(
            equalTo: content.trailingAnchor, constant: -overhangX
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
        // ⚠️ **A SELECTION THE NEW LIST NO LONGER HAS IS LET GO, NOT CLAMPED.**
        // Clamping moved a viewer sitting on the last item onto its neighbour
        // silently, so the host kept showing the tools of an item the strip no
        // longer offered. Going neutral says what happened, once.
        if !items.indices.contains(selectedIndex) {
            selectedIndex = max(0, min(selectedIndex, items.count - 1))
            if !isNeutral {
                isNeutral = true
                onSelectNothing?()
            }
        }
        restingNotes = restingNotes.filter { items.indices.contains($0.key) }
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

    // MARK: - Resting items

    /// Dims one item while leaving it tappable, or lifts the dimming.
    ///
    /// ⚠️ **DIMMED, NOT DISABLED.** A resting item still answers a tap, so the
    /// host can say WHY it rests — the camera's shape, locked once a take has a
    /// clip, explains that undoing the clips frees it. A disabled one would
    /// swallow the tap and explain nothing. `note` is what VoiceOver reads as
    /// the item's value while it rests.
    ///
    /// ⚠️ **KEPT ACROSS `setItems`** for the indices the new list still has:
    /// a host that re-dresses its icons (a state drawn into a symbol) must not
    /// have to remember to dim again. The camera found its item by its
    /// accessibility label before this existed.
    public func setDimmed(_ dimmed: Bool, at index: Int, note: String? = nil) {
        if dimmed {
            restingNotes[index] = note ?? ""
        } else {
            restingNotes[index] = nil
        }
        applySelectionAppearance()
    }

    /// Whether the item at `index` is resting.
    public func isDimmed(at index: Int) -> Bool { restingNotes[index] != nil }

    /// What each resting item says as its value; present means resting.
    private var restingNotes: [Int: String] = [:]

    // MARK: - Choosing

    /// Chooses an item exactly as a tap would.
    ///
    /// `notify: false` is for a host adopting a stored choice before the viewer
    /// has touched anything — telling it about its own decision is noise.
    public func select(_ index: Int, notify: Bool = true) {
        guard items.indices.contains(index) else { return }
        let changed = index != selectedIndex || isNeutral
        isNeutral = false
        selectedIndex = index
        progress = CGFloat(index)
        applySelectionAppearance()
        applyProgress()
        keepLensVisible(animated: false)
        if changed, notify { onSelect?(index) }
    }

    /// Puts every choice down: nothing filled, no pill, and the host's tools
    /// closed. What the media editor's screen opens on, and where a second tap
    /// on the chosen icon returns it.
    public func selectNothing(notify: Bool = true) {
        guard !isNeutral else { return }
        isNeutral = true
        applySelectionAppearance()
        if notify { onSelectNothing?() }
    }

    private func tapped(_ index: Int) {
        guard index != selection else {
            onReselect?(index)
            return
        }
        let wasNeutral = isNeutral
        isNeutral = false
        // Coming back from neutral there is nothing to travel from: the pill
        // appears at rest where it is going. Otherwise it travels as glass.
        if !wasNeutral {
            liftLens()
            awaitLanding(index)
        }
        UIView.animate(withDuration: Metrics.settle, delay: 0, options: [.curveEaseOut]) {
            // Coming back from neutral the pill has nowhere to travel FROM, so
            // it appears where it is going rather than sliding in from the item
            // it happened to be on last time.
            if wasNeutral { self.progress = CGFloat(index) }
            self.selectedIndex = index
            self.progress = CGFloat(index)
            self.applyProgress()
            self.keepLensVisible(animated: false)
        }
        // The progress is at the landing now (set in the block above), and
        // nothing else reports it — without this the lens waited out its
        // fallback, filmed as a second of glass sitting on the chosen icon.
        glassLens?.noteProgress()
        applySelectionAppearance()
        onSelect?(index)
    }

    private func applySelectionAppearance() {
        lens.isHidden = isNeutral
        glassLens?.place(hidden: isNeutral)
        for (index, button) in buttons.enumerated() {
            let item = items[index]
            let isSelected = index == selection
            // Selection = the filled variant where the symbol has one, which is
            // the rule `GlassSegmentRow` already follows.
            let name = isSelected ? item.symbolName + ".fill" : item.symbolName
            let image = UIImage(systemName: name) ?? UIImage(systemName: item.symbolName)
            button.configuration?.image = image
            button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
            let note = restingNotes[index]
            button.alpha = note == nil ? 1 : Metrics.restingAlpha
            button.accessibilityValue = note.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    // MARK: - Layout

    public override var intrinsicContentSize: CGSize {
        CGSize(
            width: IconBarMetrics.intrinsicWidth(count: items.count),
            height: Metrics.capsuleHeight
        )
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // ⚠️ SHAPE BEFORE MATERIAL. `didMoveToWindow` can land before the first
        // layout pass has given the capsule real bounds, and a glass effect
        // switched on over a zero-radius layer draws one frame of hard corners.
        //
        // The CAPSULE's height, not this view's: inside a platter the two differ
        // by the overhang, and the radius has to be the visible capsule's.
        measurePlatterIfHosted()
        capsule.layer.cornerCurve = .continuous
        capsule.layer.cornerRadius = capsule.bounds.height / 2
        lens.layer.cornerRadius = lensSide / 2
        if liftsLensAsGlass, glassLens == nil, bounds.width > 0 { _ = ensureGlassLens() }
        if SelectorGlassLens.keepsLifted, bounds.width > 0, window != nil { liftLens() }
        applyProgress()
        #if DEBUG
        traceChainOnce()
        #endif
    }

    #if DEBUG
    private var lastTracedKey = ""
    /// The chain of views UIKit puts this bar in, once per size it takes — the
    /// measurement behind `SelectorHosting.measuredPlatterOverhang`. Same
    /// instrument and same launch argument as `PagedTabBar`'s.
    private func traceChainOnce() {
        let traceKey = "\(bounds.size)-\(String(describing: platterOverhang))"
        guard lastTracedKey != traceKey, bounds.width > 0, window != nil,
              ProcessInfo.processInfo.arguments.contains("-tabbar-shape-trace") else { return }
        lastTracedKey = traceKey
        var chain: [String] = []
        var view: UIView? = self
        for _ in 0..<5 {
            guard let current = view else { break }
            let frame = current.convert(current.bounds, to: nil)
            chain.append(String(format: "%@ %.1fx%.1f@%.1f,%.1f",
                                String(describing: type(of: current)),
                                frame.width, frame.height, frame.minX, frame.minY))
            view = current.superview
        }
        print("[tabshape] chain hosting=\(hosting) measured=\(platterOverhang.map { "\($0.width)x\($0.height)" } ?? "nil") "
              + chain.joined(separator: " < "))
    }
    #endif

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // A bar that leaves its window starts its platter measurement over
        // when it comes back — the next host may be a different ring.
        if window == nil { remeasure.reset(); glassLens?.cancel() }
        guard window != nil, capsule.effect == nil, hosting.drawsBackdrop else { return }
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
        // clearance number — so the pill cannot drift on one axis only. In the
        // scrolled content's space, which is the visible capsule's: the pill
        // stands `clearance` off the visible edge on every host, as the overhang
        // and the clearance inside the segment between them.
        let centring = (Metrics.segmentSide - lensSide) / 2
        // ⚠️ THE CAPSULE's height, not the scrolled content's: this runs from
        // this view's own layout pass, where a direct subview's bounds are
        // already current and a grandchild's are a pass stale — the content
        // read 0 tall on the first pass and the pill was placed 14pt above it.
        lens.frame = CGRect(
            x: overhangX + centring + progress * stride,
            y: (capsule.bounds.height - lensSide) / 2,
            width: lensSide, height: lensSide
        )
        glassLens?.place(hidden: isNeutral)
    }

    /// Brings the lens back into the viewport by the minimum that shows it —
    /// with its clearance, so a revealed pill never reads as clipped.
    private func keepLensVisible(animated: Bool) {
        guard scroller.bounds.width > 0 else { return }
        let visible = CGRect(origin: scroller.contentOffset, size: scroller.bounds.size)
        var offset = scroller.contentOffset.x
        if lens.frame.minX < visible.minX {
            offset = lens.frame.minX - Metrics.clearance
        } else if lens.frame.maxX > visible.maxX {
            offset = lens.frame.maxX + Metrics.clearance - scroller.bounds.width
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
        let reach = max(0, lensClearance)
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
        liftLens()
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
        // The inverse of `applyProgress`: the pill's centre sits half a segment
        // past the row's start, whatever clearance it keeps inside the segment.
        let raw = (centre - overhangX - Metrics.segmentSide / 2) / stride
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
        guard current.moved else {
            settleLens()
            return
        }

        let landing = landingIndex(from: progress, speed: current.speed)
        let changed = landing != selectedIndex
        selectedIndex = landing
        applySelectionAppearance()
        awaitLanding(landing)
        UIView.animate(withDuration: Metrics.settle, delay: 0, options: [.curveEaseOut]) {
            self.progress = CGFloat(landing)
            self.applyProgress()
            self.keepLensVisible(animated: false)
        }
        glassLens?.noteProgress()
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

// MARK: - The lens as Liquid Glass (SPIKE) — see `SelectorGlassLens`

extension IconSelectorBar {
    private func ensureGlassLens() -> SelectorGlassLens {
        if let glassLens { return glassLens }
        let overlay = SelectorGlassLens(tint: Self.lensTint) { [weak self] in
            guard let self else { return .zero }
            return content.convert(lens.frame, to: self)
        }
        overlay.isHeld = { [weak self] in self?.drag != nil }
        // The strip the lens refracts a copy of, and masks beneath itself.
        overlay.source = { [weak self] in self?.content }
        // Beneath the capsule, above the host's glass, where the host draws
        // the glass — the icons above it stay crisp.
        if hosting.drawsBackdrop {
            addSubview(overlay.view)
        } else {
            insertSubview(overlay.view, belowSubview: capsule)
        }
        glassLens = overlay
        lens.alpha = 0
        overlay.place(hidden: isNeutral)
        return overlay
    }

    private func liftLens() {
        guard liftsLensAsGlass, !isNeutral else { return }
        ensureGlassLens().lift()
    }

    private func settleLens() { glassLens?.settle() }

    /// The lens lands when the bar's own progress reaches `index`.
    private func awaitLanding(_ index: Int) {
        glassLens?.awaitLanding { [weak self] in
            guard let self else { return true }
            return abs(progress - CGFloat(index)) < 0.01
        }
    }
}

#if DEBUG
extension IconSelectorBar {
    /// Whether the pill is currently lifted glass.
    public var debugLensIsGlass: Bool { glassLens?.isLifted ?? false }
    public func debugRunLensSpringToRest() { glassLens?.runSpringToRest() }
    public var debugItemCount: Int { items.count }
    public var debugLensFrame: CGRect { lens.frame }
    /// Whether the pill is drawn at all — it is not, while the bar is neutral.
    public var debugLensIsShowing: Bool { !lens.isHidden }
    public var debugStripOffset: CGFloat { scroller.contentOffset.x }
    public var debugStripAcceptsScrolling: Bool { scroller.isScrollEnabled }
    public var debugEdgeScrollIsArmed: Bool { edgeLink != nil }
    /// Which items are marked chosen — the trait VoiceOver reads, set by
    /// `applySelectionAppearance` and nowhere else. Empty while neutral.
    ///
    /// ⚠️ **NOT `debugIsSelectedFilled` BELOW**, which only answers whether the
    /// selected button has an image at all — true of every button, filled or
    /// not, and it let a neutral bar look chosen.
    public var debugChosenIndices: [Int] {
        buttons.indices.filter { buttons[$0].accessibilityTraits.contains(.selected) }
    }

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
    /// Internal for tests: how opaque the item at `index` is DRAWN, and what
    /// VoiceOver reads as its value.
    public func debugDrawnAlpha(at index: Int) -> CGFloat { buttons[index].alpha }
    public func debugSpokenValue(at index: Int) -> String? { buttons[index].accessibilityValue }

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
