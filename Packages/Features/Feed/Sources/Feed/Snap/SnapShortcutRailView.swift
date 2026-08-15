import CoreModels
import CoreStorage
import DesignSystem
import UIKit

/// The vertical shortcut wheel: a right-edge rail of quick-react shortcuts,
/// spanning from the comment ticker's top edge up to the navigation bar. The
/// payload is temporary — randomized SF Symbol bubbles standing in for the
/// user's favorite react-GIFs — but the geometry and interaction contract are
/// the real feature: icons only, no text or counts.
///
/// # Wheel
/// A plain vertical `UIScrollView`, not a collection view: the payload is a
/// handful of fixed-size bubbles with no reuse pressure, and frames are laid
/// manually (the hot-cell doctrine — no Auto Layout inside a surface that
/// moves every frame). `decelerationRate = .fast` plus detent snapping in
/// `scrollViewWillEndDragging` gives the wheel feel — releases settle on
/// the step grid. Snapping applies ONLY to in-range targets: an edge
/// flick's overshooting proposal is left alone so UIKit's native spring
/// owns the rubber-band (clamping those to the boundary once made the
/// edges read as a hard wall). The detents were briefly retired on a
/// jitter suspicion; the stripped-baseline experiment exonerated them —
/// the jitter was the gesture arena all along (see # Feed arbitration).
///
/// # Resting window
/// At rest exactly `restingIconCount` bubbles show, docked at the rail's
/// BOTTOM (on the subtitle zone's horizon), with the rest dissolved through
/// the edge-fade band below. This is pure contentInset arithmetic: the
/// rail's frame spans the full ticker→nav-bar band (so the whole strip is
/// grabbable and revealed icons have somewhere to go), `contentInset.top`
/// pads the scroll range down to the resting window (one fade band above
/// the bottom edge), and the rest offset is `-contentInset.top`. Swiping up
/// walks the hidden icons in through the fade; the top clamp bottom-aligns
/// the whole column, filling the rail toward the nav bar. Both invisible
/// clip edges are soft (`edgeFade` mask), so an icon leaving the window
/// slides out through a dissolve — never a hard cut on a mid-screen line.
/// Geometry rebuilds (size ticks) preserve the reveal progress; only a
/// fresh payload parks the wheel back at rest.
///
/// # Feed arbitration
/// A vertical touch that lands on the rail belongs to the rail, completely
/// — and the GESTURE GRAPH STAYS NATIVE. Two failed campaigns are law here:
/// shadowing UIScrollView's private gesture-delegate methods choked system
/// machinery (the scroll-edge flex driver) and wedged the arena, and
/// `require(toFail:)` edges into the pager's recognizers (its pan, its
/// paging-swipe, the system gates) formed a requirement cycle that froze
/// the entire subtree. Neither returns. Isolation is two local moves:
/// 1. REACTIVE LOCK — the instant the wheel's own pan begins
///    (`scrollViewWillBeginDragging`), every ancestor scroll view is
///    suspended (`isScrollEnabled = false`) until the gesture fully
///    settles. One lock kills both leaks: the pager cannot recognize the
///    touch, and UIKit's recognizer-less boundary chaining finds no
///    scrollable ancestor to hand overshoot to — the rubber-band absorbs
///    it. Touches off the rail never engage the lock.
/// 2. AXIS — `gestureRecognizerShouldBegin` mirrors the ticker's test the
///    other way: only vertically dominant drags begin, so a rightward
///    slide-to-pop that starts on the rail stays with navigation.
/// Taps are the cell's arbitration seam: the chrome declares this rail an
/// `interactionRoot`, so touches here never toggle playback.
///
/// # Flight replica
/// Populated from `configure` (static content, like the caption), so the
/// transition's inert replica shows the same rail. The payload is therefore
/// seeded per post id — "randomized" across posts, but deterministic within
/// a launch — so the live cell and its flight replica can never disagree.
/// (A user-scrolled wheel snaps back to rest in the replica; acceptable while
/// the payload is placeholder.)
final class SnapShortcutRailView: UIScrollView {
    /// The feed's bubble invariant (nav/toolbar circles are 36pt).
    static let iconDiameter: CGFloat = 36
    static let iconSpacing: CGFloat = Spacing.md
    /// How many bubbles the resting window shows.
    static let restingIconCount = 3
    /// One detent: a bubble plus its gap.
    static var step: CGFloat { iconDiameter + iconSpacing }
    /// The resting window's height: exactly `restingIconCount` bubbles.
    static var restingWindowHeight: CGFloat {
        CGFloat(restingIconCount) * iconDiameter + CGFloat(restingIconCount - 1) * iconSpacing
    }
    /// The soft clip band at both edges: icons dissolve through it instead
    /// of vanishing on the rail's invisible clip line mid-screen. The
    /// resting window docks this far above the rail's bottom (via
    /// `contentInset.bottom`), so resting bubbles sit clear of the fade.
    static let edgeFadeLength: CGFloat = Spacing.lg

    /// How small an emote gets at full top-exit (t == 0): scale interpolates
    /// linearly from this floor back to 1 across one detent of travel.
    static let exitScaleFloor: CGFloat = 0.6

    /// The bottom strip reserved for FIXED chrome (the compose "+" square
    /// riding the ticker overlap): the resting window and the top clamp
    /// both dock ABOVE it, so no emote ever settles obscured behind the
    /// button — bubbles only dip through during rubber-band overshoot.
    /// Owned by the chrome (it knows the square's font-derived height).
    var bottomReservedInset: CGFloat = 0 {
        didSet {
            guard bottomReservedInset != oldValue else { return }
            needsContentRebuild = true
            setNeedsLayout()
        }
    }

    private var icons: [UIButton] = []
    private var lastLaidOutSize: CGSize = .zero
    private var needsContentRebuild = false
    /// Fresh payloads park at rest; mere size churn must NOT — geometry
    /// rebuilds preserve the user's reveal progress instead.
    private var needsRestReset = false
    /// Ancestor scroll views suspended for the duration of a rail gesture
    /// (weakly held: a mid-gesture teardown must not retain the feed).
    private let suspendedAncestors = NSHashTable<UIScrollView>.weakObjects()
    /// The mask doing the soft clip (`layer.mask`); repositioned every
    /// layout pass because a scroll view's layer bounds ride its offset.
    private let edgeFade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        // The cell sits under the transparent nav bar; ambient inset
        // adjustment would shove the wheel's scroll range around.
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        // The wheel always answers a swipe with the native rubber-band,
        // even when the payload is too small to reveal anything.
        alwaysBounceVertical = true
        clipsToBounds = true
        // Icon touches track instantly (the wheel's pan cancels them when a
        // drag wins) — same un-delayed pipeline as the feed collection view.
        // `touchesShouldCancel(in:)` below is this line's mandatory other
        // half: without it, a bubble's press state owns the touch and the
        // wheel can't scroll from a finger that landed on an icon.
        delaysContentTouches = false
        canCancelContentTouches = true
        scrollsToTop = false // the status-bar tap belongs to the feed
        isHidden = true
        accessibilityIdentifier = "shortcut-rail"
        // The delegate serves two seams: the feed lock (lifecycle
        // observation) and the in-range detent snap. It never clamps
        // out-of-range targets — the edge spring is UIKit's.
        delegate = self

        // White = shown, clear = dissolved; locations resolved per layout
        // pass (they depend on the rail's height). BOTTOM duty only (the
        // fade into the reserved "+" strip): the TOP exit is per-icon
        // fade+scale interpolation on the detent grid (see layoutSubviews),
        // which a flat gradient cannot express.
        edgeFade.colors = [
            UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor,
        ]
        layer.mask = edgeFade
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Torn down mid-gesture (cell recycled, feed dismissed): the
        // suspended pager must never stay locked behind us. Deliberately
        // NO require(toFail:) wiring here — inserting failure edges into
        // the pager's recognizer graph (its pan, its paging-swipe, the
        // system gates) once formed a requirement cycle that froze every
        // recognizer in the subtree. The graph stays native; isolation is
        // the reactive lock below.
        guard window != nil else {
            setAncestorScrollingSuspended(false)
            return
        }
        // The system's scroll-edge effects manage `layer.mask` themselves
        // and silently evict the custom edge-fade gradient (the feed's
        // collection view disables its own for the same reason). Hidden on
        // WINDOW ATTACH, not init: the edge effects are Liquid Glass
        // machinery, and even touching them materializes it — a ~60s
        // render-server broker timeout on headless CI simulators (the
        // count bubble/compose anchor doctrine; this access blocked the
        // whole Feed test process once). Window attach precedes first
        // render, so the mask never loses ownership on screen.
        topEdgeEffect.isHidden = true
        bottomEdgeEffect.isHidden = true
    }

    /// The dead-end sink for overscroll: gesture arbitration can only gate
    /// the pager's PAN, but UIKit's boundary chaining bypasses recognizers
    /// entirely — the inner scroll machinery walks the ancestor chain and
    /// writes the ancestor's offset directly when the rail hits its elastic
    /// limit (velocity hand-off on deceleration too). A suspended scroll
    /// view is skipped by that walk, so: pager frozen for exactly the span
    /// of a rail gesture (drag through deceleration), thawed the moment the
    /// wheel settles. Only ancestors that were enabled are suspended, and
    /// they're held weakly with teardown unlocks (`didMoveToWindow`,
    /// `reset`) so the feed can never be stranded unscrollable.
    private func setAncestorScrollingSuspended(_ suspended: Bool) {
        if suspended {
            var view = superview
            while let current = view {
                if let scroll = current as? UIScrollView, scroll.isScrollEnabled {
                    scroll.isScrollEnabled = false
                    suspendedAncestors.add(scroll)
                }
                view = current.superview
            }
        } else {
            for scroll in suspendedAncestors.allObjects { scroll.isScrollEnabled = true }
            suspendedAncestors.removeAllObjects()
        }
    }

    /// The bubbles are scroll surface first, buttons second: UIScrollView's
    /// default answers `false` for `UIControl`s here, which — combined with
    /// un-delayed content touches — lets a bubble's press state OWN the
    /// touch and paralyze the wheel until the finger lifts. A swipe must
    /// win from anywhere, including directly on an icon; the press it
    /// cancels was a scroll, not a tap (taps never move enough to drag).
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UIControl { return true }
        return super.touchesShouldCancel(in: view)
    }

    /// Vertical intent only — the ticker's axis test, mirrored: horizontal
    /// drags starting on the rail stay with the timeline slide-to-pop.
    /// Translation, NOT velocity: UIKit consults this for the scroll view's
    /// own pan on early touch samples where velocity is still zero — a
    /// velocity test reads those as "not vertical" and freezes the wheel
    /// for the whole touch. (The ticker can test velocity because its pan
    /// is a standalone recognizer, only consulted after real movement.)
    /// A directionless sample stays with the wheel: the rail is a dead
    /// zone for other pans either way, and refusing here would kill the
    /// gesture outright.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let translation = panGestureRecognizer.translation(in: self)
        guard translation != .zero else { return true }
        return abs(translation.y) > abs(translation.x)
    }

    // MARK: - Content

    /// Replaces the wheel's shortcuts. Empty (text-only post, or a reset
    /// cell awaiting configure) hides the rail entirely — the same
    /// empty-hides-the-surface doctrine as the ticker and subtitle zone.
    /// Always returns the wheel to its resting window.
    func setSymbols(_ names: [String]) {
        for icon in icons { icon.removeFromSuperview() }
        icons = names.map(Self.makeIconBubble)
        for icon in icons { addSubview(icon) }
        isHidden = names.isEmpty
        needsContentRebuild = true
        needsRestReset = true
        setNeedsLayout()
    }

    /// Back to the resting window (cell reuse). Also releases any feed lock
    /// a mid-gesture recycle would otherwise strand.
    func reset() {
        setAncestorScrollingSuspended(false)
        setSymbols([])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Geometry FIRST: on the very first pass, `rebuildGeometry` is what
        // parks the wheel at its rest offset. The mask below frames itself
        // against `bounds` — masking before the rebuild framed it against
        // the pre-rest origin, so the first rendered frame mapped the
        // reserved "+" strip onto the wrong slice of content and the
        // overflow bubble sat opaque on the button until the first scroll
        // re-laid the mask.
        // (layoutSubviews fires on every scrolled frame — bounds.origin
        // moves; geometry only changes when the size or the payload does.)
        if needsContentRebuild || bounds.size != lastLaidOutSize {
            needsContentRebuild = false
            lastLaidOutSize = bounds.size
            rebuildGeometry()
        }

        // The mask lives in layer coordinates, which ride the scroll offset —
        // re-cover the visible window on every pass (cheap: one frame set,
        // no allocation; implicit actions off so it can't lag a fast flick).
        // The bottom fade ends ABOVE the reserved strip (the fixed "+"
        // square), and the strip itself is fully masked out: overflow
        // bubbles dissolve on approach and never render over the button —
        // not at rest (the 4th bubble hangs one gap below the window) and
        // not mid-bounce.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeFade.frame = bounds
        let height = max(bounds.height, 1)
        let reserved = min(bottomReservedInset / height, 0.4)
        let bottomFadeStart = min((bottomReservedInset + Self.edgeFadeLength) / height, 0.5)
        edgeFade.locations = [
            0, NSNumber(value: 1 - bottomFadeStart), NSNumber(value: 1 - reserved),
        ]
        CATransaction.commit()

        // Top exit on the DETENT GRID: an emote leaving through the top
        // fades and dezooms as a pure function of its window position —
        // t = viewTop / step, so one full step of travel spans full-size
        // to collapsed. Because the chrome grid-aligns the headroom
        // (`contentInset.top` is a whole number of steps), every settled
        // detent lands the exiting emote at exactly t == 0 (gone) or
        // t == 1 (at rest) — a half-faded straddler cannot exist at rest.
        for icon in icons {
            // Center, not frame: frame is the TRANSFORMED bounding box, and
            // reading it under last pass's scale feeds back into t.
            let viewTop = icon.center.y - Self.iconDiameter / 2 - bounds.origin.y
            let t = max(0, min(1, viewTop / Self.step))
            icon.alpha = t
            let scale = Self.exitScaleFloor + (1 - Self.exitScaleFloor) * t
            icon.transform = t >= 1 ? .identity : CGAffineTransform(scaleX: scale, y: scale)
        }
    }

    private func rebuildGeometry() {
        // A size tick mid-life (safe-area churn, rotation) must not stomp
        // the wheel: carry the reveal progress across the rebuild. Only a
        // fresh payload (`setSymbols`) parks back at rest.
        let previousProgress = contentOffset.y + contentInset.top

        let diameter = Self.iconDiameter
        let x = (bounds.width - diameter) / 2
        for (index, icon) in icons.enumerated() {
            // Frame under an active exit transform is undefined — reset
            // first; the interpolation pass right after reapplies it.
            icon.transform = .identity
            icon.frame = CGRect(x: x, y: CGFloat(index) * Self.step, width: diameter, height: diameter)
        }
        let contentHeight = icons.isEmpty
            ? 0
            : CGFloat(icons.count) * diameter + CGFloat(icons.count - 1) * Self.iconSpacing
        contentSize = CGSize(width: bounds.width, height: contentHeight)

        // The rest offset parks icon 0 at the top of the resting window,
        // docked one fade band above the reserved bottom strip (the fixed
        // "+" square) — everything past `restingIconCount` dissolves
        // through the fade below, and settles can never park an emote
        // behind the button.
        contentInset = UIEdgeInsets(
            top: max(0, bounds.height - Self.restingWindowHeight - Self.edgeFadeLength - bottomReservedInset),
            left: 0, bottom: bottomReservedInset + Self.edgeFadeLength, right: 0
        )
        let restOffset = -contentInset.top
        let maxOffset = max(contentSize.height - bounds.height + contentInset.bottom, restOffset)
        let progress = needsRestReset ? 0 : min(max(previousProgress, 0), maxOffset - restOffset)
        needsRestReset = false
        contentOffset = CGPoint(x: 0, y: restOffset + progress)
    }

    // MARK: - Detents

    /// Snaps a proposed deceleration target onto the step grid measured from
    /// the rest offset, clamped to the scrollable range. Callers must hand
    /// this IN-RANGE proposals only — out-of-range ones belong to UIKit's
    /// edge spring (see `scrollViewWillEndDragging`). Pure + static so the
    /// arithmetic is unit-testable.
    static func snappedTarget(
        proposed: CGFloat, restOffset: CGFloat, step: CGFloat, maxOffset: CGFloat
    ) -> CGFloat {
        let snapped = restOffset + (step > 0 ? (proposed - restOffset) / step : 0).rounded() * step
        return min(max(snapped, restOffset), max(maxOffset, restOffset))
    }

    // MARK: - Placeholder payload

    /// Temporary stand-ins for the react-GIF shortcuts. Seeded by post id
    /// (the ticker builder's RNG + hash, reused): randomized across posts,
    /// but the live cell and its flight replica always draw the same wheel.
    static func placeholderPayload(for id: PostID) -> [String] {
        var generator = SplitMix64(seed: CommentTickerBuilder.fnv1a(id.rawValue))
        return symbolPool.shuffled(using: &generator)
    }

    /// Reaction-shaped symbols only — the wheel reads as "react", not "menu".
    /// 19 deep so the wheel always has plenty to discover past the resting
    /// window.
    static let symbolPool = [
        "heart.fill", "flame.fill", "hands.clap.fill", "face.smiling.fill",
        "bolt.fill", "star.fill", "party.popper.fill", "hand.thumbsup.fill",
        "sparkles",
        "hand.wave.fill", "hand.raised.fill", "eyes", "crown.fill",
        "trophy.fill", "medal.fill", "balloon.fill", "birthday.cake.fill",
        "music.note", "moon.stars.fill",
    ]

    /// One shortcut bubble: the subtitle pill's flat translucent black (a
    /// direct composite — nine backdrop blurs on a scrolling surface would
    /// not survive device triage), the toolbar's symbol metrics. A `UIButton`
    /// so the cell's tap arbitration sees a `UIControl`; tap behavior itself
    /// arrives with the real GIF payload.
    private static func makeIconBubble(systemName: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        config.baseForegroundColor = .white
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.layer.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor
        button.layer.cornerRadius = iconDiameter / 2
        button.layer.cornerCurve = .continuous
        return button
    }

    // MARK: - Test seams

    /// Bubbles currently inside the visible window — the edge-fade bands
    /// and the reserved bottom strip excluded (a bubble dissolving in the
    /// fade or dipping through the "+" square is an affordance, not a
    /// shown shortcut; edge-touching does not count). Internal so tests
    /// can pin the resting window to exactly `restingIconCount`.
    var visibleIconCount: Int {
        var window = CGRect(origin: contentOffset, size: bounds.size)
        window.origin.y += Self.edgeFadeLength
        window.size.height -= 2 * Self.edgeFadeLength + bottomReservedInset
        return icons.count(where: { $0.frame.intersects(window) })
    }
}

/// The rail column's fixed BOOST affordance ("push this post up trending"),
/// filling the glass square at the rail's bottom — the slot the compose "+"
/// held until the boost economy took it (`WalletStore` is the balance it
/// spends from). A marker class: the feed pager's geometric veto
/// (`SnapFeedCollectionView`) treats it as rail territory, so a swipe born
/// on the button can never page the feed.
///
/// Two intents, one control: a TAP spends the default amount; a LONG-PRESS
/// opens the denomination menu (`showsMenuAsPrimaryAction` stays false so
/// the tap keeps firing `primaryActionTriggered`). Both land on `onBoost` —
/// the button knows amounts, never targets; the chrome's owner attaches the
/// post identity.
///
/// Configured PLAIN at init; the Liquid Glass configuration materializes
/// on first window attach — the subtitle count bubble's doctrine (#46):
/// creating a system material contacts the render server, a multi-second
/// main-thread stall on headless CI simulators, where unit-tested views
/// never join a window and must never pay it.
final class SnapRailBoostButton: UIButton {
    /// Fired with the point amount to spend — the tap default or a menu pick.
    var onBoost: ((Int) -> Void)?
    /// Fired by the menu's Undo entry — the host refunds the session spend
    /// (it owns the tally and the wallet; the button only shows the door).
    var onUndo: (() -> Void)?

    private var hasGlass = false
    /// The viewer's cumulative spend on the represented post — the button's
    /// SECOND face. Zero wears the star glyph (an invitation); anything
    /// above it wears the gold number itself (a receipt), because "what have
    /// I already put on this post" is the question the control's own state
    /// answers best. Owned by the host via `setSpentTotal` — the button
    /// never reads a wallet.
    private var spentTotal = 0
    /// The wallet context the host pushes (`setWalletContext`): what the
    /// balance can still afford, and how much of this post's spend is
    /// session-undoable. `Int.max` at rest so an unwired host keeps the
    /// historical always-enabled affordance.
    private var availableBalance = Int.max
    private var undoableAmount = 0

    init() {
        super.init(frame: .zero)
        applyFace()
        addAction(
            UIAction { [weak self] _ in self?.onBoost?(WalletStore.Policy.tapBoostAmount) },
            for: .primaryActionTriggered
        )
        // DEFERRED and uncached: the menu is built at present time from the
        // pushed wallet context, so denominations the balance can't cover
        // arrive disabled and the Undo entry exists exactly while there is
        // a session spend to take back. A static menu would freeze the
        // first launch's answer.
        menu = UIMenu(
            title: "Boost this post",
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.currentMenuActions() ?? [])
                },
            ]
        )
    }

    /// The affordability + undo state, pushed by the host on configure and
    /// on every wallet change. Disables the control only when it has
    /// NOTHING to offer — tap unaffordable (or the post full) AND nothing
    /// to undo — because a disabled `UIButton` delivers no long-press
    /// either, and the menu is the undo's only door.
    func setWalletContext(balance: Int, undoableAmount: Int) {
        availableBalance = balance
        self.undoableAmount = undoableAmount
        refreshEnabled()
    }

    private func refreshEnabled() {
        let remaining = max(0, WalletStore.Policy.perTargetBoostCap - spentTotal)
        // A tap near the cap costs only the remainder (the store clamps),
        // so affordability is judged against that, not the flat tap price.
        let tapCost = min(WalletStore.Policy.tapBoostAmount, remaining)
        isEnabled = undoableAmount > 0 || (remaining > 0 && availableBalance >= tapCost)
    }

    /// The menu, top to bottom: **Max** (what a fill-up would actually
    /// spend — the cap's remainder bounded by the balance), the fixed
    /// denomination(s), and Undo while the session holds something.
    ///
    /// Internal, not private: the menu is a deferred element resolved only
    /// at present time, which a unit test can't trigger — so the builder is
    /// the testable seam.
    func currentMenuActions() -> [UIMenuElement] {
        let remaining = max(0, WalletStore.Policy.perTargetBoostCap - spentTotal)
        let maxAmount = min(remaining, availableBalance)
        var actions: [UIMenuElement] = []

        // The label names the REAL spend when one is possible; disabled it
        // still names the door (the remainder, or the cap on a full post).
        let shownMax = maxAmount > 0
            ? maxAmount
            : (remaining > 0 ? remaining : WalletStore.Policy.perTargetBoostCap)
        let maxAction = UIAction(
            title: "Max (\(shownMax) points)",
            image: UIImage(systemName: "star.fill")
        ) { [weak self] _ in self?.onBoost?(maxAmount) }
        if maxAmount <= 0 { maxAction.attributes = .disabled }
        actions.append(maxAction)

        for amount in WalletStore.Policy.boostDenominations.reversed() {
            let action = UIAction(
                title: "\(amount) points",
                image: UIImage(systemName: "star.fill")
            ) { [weak self] _ in self?.onBoost?(amount) }
            if amount > availableBalance || amount > remaining { action.attributes = .disabled }
            actions.append(action)
        }
        if undoableAmount > 0 {
            actions.append(UIAction(
                title: "Undo boosts (\(undoableAmount))",
                image: UIImage(systemName: "arrow.uturn.backward"),
                attributes: .destructive
            ) { [weak self] _ in self?.onUndo?() })
        }
        return actions
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Renders the viewer's spend on this post. Idempotent; a recycled cell
    /// resets it to 0 through `SnapChromeView.reset`.
    func setSpentTotal(_ total: Int) {
        guard total != spentTotal else { return }
        spentTotal = total
        applyFace()
        // The spend moves the cap's remainder, and the remainder moves the
        // enable state (a full post refuses even the tap).
        refreshEnabled()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !hasGlass {
            hasGlass = true
            applyFace()
        }
    }

    /// One writer for the configuration: glass state and spend face both
    /// funnel here, so a glass materialization can never resurrect the
    /// wrong face (the configuration is rebuilt whole each time).
    private func applyFace() {
        configuration = Self.makeConfiguration(glass: hasGlass, spentTotal: spentTotal)
        accessibilityLabel = "Boost post"
        accessibilityValue = spentTotal > 0 ? "\(spentTotal) points spent" : nil
    }

    private static func makeConfiguration(glass: Bool, spentTotal: Int) -> UIButton.Configuration {
        var config: UIButton.Configuration = glass ? .glass() : .plain()
        if spentTotal > 0 {
            // The receipt face: the compact count in wallet gold, replacing
            // the glyph outright — the 36pt circle holds one or the other.
            var title = AttributedString(spentTotal.formattedCompact())
            title.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            title.foregroundColor = .systemYellow
            config.attributedTitle = title
        } else {
            config.image = UIImage(systemName: "star.fill")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        }
        config.baseForegroundColor = .white
        config.contentInsets = .zero
        config.cornerStyle = .capsule
        return config
    }
}

// MARK: - Feed lock (overscroll dead-end)

extension SnapShortcutRailView: UIScrollViewDelegate {
    // Lifecycle observation only — no offset retargeting, no physics.
    // The lock spans the entire gesture: drag begin → (deceleration →)
    // settle. A new drag catching a live deceleration re-locks before the
    // old gesture's end callback could thaw (UIKit orders willBeginDragging
    // first), so the pager stays frozen across catch-and-throw scrubbing.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        setAncestorScrollingSuspended(true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { setAncestorScrollingSuspended(false) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // A finger catching the deceleration can deliver this end callback
        // AFTER its willBeginDragging — never thaw under a live touch.
        guard !isTracking, !isDragging else { return }
        setAncestorScrollingSuspended(false)
    }

    // MARK: Detent snapping (in-range only)

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let restOffset = -contentInset.top
        let maxOffset = contentSize.height - bounds.height + contentInset.bottom
        let proposed = targetContentOffset.pointee.y
        // A proposal beyond the scrollable range is an edge flick: leave it
        // UNTOUCHED so UIKit's own spring overshoots and rubber-bands back.
        // Clamping it to the boundary hands deceleration a dead-stop target
        // and the edge reads as a hard wall.
        guard proposed > restOffset, proposed < maxOffset else { return }
        targetContentOffset.pointee.y = Self.snappedTarget(
            proposed: proposed,
            restOffset: restOffset,
            step: Self.step,
            maxOffset: maxOffset
        )
    }
}
