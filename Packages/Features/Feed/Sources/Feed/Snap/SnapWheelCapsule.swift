import UIKit

/// THE WHEEL'S GLASS CAPSULE (#1872, part 2): a capsule of interactive glass
/// as wide as the like, around the visible emotes only, laid in the action
/// column's glass (`SnapGlassColumn.insertAccessory`) so it FUSES with the
/// like. Ported from the liquidglass lab's `EmoteRailView` (branch
/// `disparition-native`, d3afda2), where every number below was filmed.
///
/// - **Touches.** The wheel lets every touch through; its pan lives on this
///   glass, which is interactive, so it swells under the finger like every
///   bubble. The glass materializes from `hitTest` at touch-down
///   (`SnapWheelGlassView`): the interactive reaction is decided on the
///   effect present at that instant (finding 3).
/// - **Lifetime.** It exists only while the wheel is ACTIVE — finger down,
///   drag, glide, bounce, the return scroll — and leaves `linger` seconds
///   after the wheel stops, wherever it is. It appears on UIKit's default
///   spring (0.5 s, no bounce) in a started animator, so it can be finished
///   at once past `settleTravel` (a materializing glass is drawn outside
///   the union, finding 1), and leaves through `UIView.animate(springDuration:)`
///   with no effect reassignment.
/// - **The bridge.** The first next emote leaves the like in its own glass
///   drop, as wide as the like; the drop never detaches: the capsule's
///   bottom comes down to the like's bottom and the like's glass retracts
///   inside it (`onLikeCover`, finding 5) — one straight capsule. Leaving,
///   the like re-inflates first, hidden under the capsule.
/// - **The return.** While the first next emote is whole and the capsule is
///   there, the like's heart becomes `chevron.down` (`onReturnShown`), and a
///   tap on it scrolls the wheel back to rest.
///
/// What the app changes: the like is a PILL, taller than wide — the bridge
/// reaches the pill's bottom (`likeHeight`), not the square under the
/// wheel.
@MainActor
final class SnapWheelCapsule: NSObject {
    /// The capsule's padding around the visible emotes.
    static let pad: CGFloat = 4
    /// Travel past which an appearance still running is finished at once:
    /// 30 % of a step, the next drop still inside the like.
    static let settleTravel: CGFloat = 12
    /// A drop's hidden diameter: more than the union's spacing from the
    /// contour around it, so it changes nothing.
    static let dropHidden: CGFloat = 8
    /// The drop takes the like's width once sin(πu) passes this.
    static let dropPlateau: CGFloat = 0.7
    /// The part of the bridge where the capsule's bottom reaches the like's;
    /// past it, the like's glass retracts inside.
    static let bridgeReach: CGFloat = 0.75
    /// How long the capsule stays after the wheel stops.
    static let linger: Double = 3
    /// UIKit's default spring (0.5 s, no bounce): k = (2π / 0.5)².
    static let systemSpringK: Double = pow(2 * .pi / 0.5, 2)

    private weak var rail: SnapShortcutRailView?
    let glass = SnapWheelGlassView(effect: nil)
    private var drop: UIVisualEffectView?

    /// Lays the capsule (and its drops) in the like's glass container.
    var host: ((UIView) -> Void)? {
        didSet { install() }
    }

    /// The like pill's height below the wheel's bottom strip's top.
    var likeHeight: CGFloat = 0
    /// The like's glass retracting into the capsule (0 … 1), when it changes.
    var onLikeCover: ((CGFloat) -> Void)?
    /// The return chevron shown or not, when it changes.
    var onReturnShown: ((Bool) -> Void)?
    private(set) var returnShown = false
    private var lastCover: CGFloat = 0

    private var run: UIViewPropertyAnimator?
    private var hiding = false
    private var hideToken = 0
    private var touched = false
    private let press = UILongPressGestureRecognizer()
    private let pressDelegate = SimultaneousGestures()
    private let returnTap = UITapGestureRecognizer()
    private let returnFilter = ReturnTapFilter()
    /// The return scroll is running (a tap on the chevron).
    private(set) var autoScrolling = false
    private var lingerItem: DispatchWorkItem?
    private var wasActive = false
    /// Wanted: the wheel active, or within the linger after it stopped.
    private(set) var isWanted = false
    /// The capsule folded away for good (the comments took the page).
    private(set) var isDismissed = false
    private var presence = Spring(0)
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    init(rail: SnapShortcutRailView) {
        self.rail = rail
        super.init()
        glass.cornerConfiguration = .capsule()
        glass.onTouchDown = { [weak self] in self?.touchDown() }
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.cancelsTouchesInView = false
        press.delegate = pressDelegate
        press.addTarget(self, action: #selector(pressChanged))
        glass.addGestureRecognizer(press)
        returnTap.addTarget(self, action: #selector(returnTapped))
        returnFilter.capsule = self
        returnTap.delegate = returnFilter
        glass.addGestureRecognizer(returnTap)
    }

    var isInstalled: Bool { host != nil }

    private func install() {
        glass.removeFromSuperview()
        drop?.removeFromSuperview()
        drop = nil
        guard let host, let rail else { return }
        host(glass)
        // The wheel's pan lives on the capsule: the glass takes the touch.
        if rail.panGestureRecognizer.view !== glass { glass.addGestureRecognizer(rail.panGestureRecognizer) }
        update()
    }

    private static func makeGlass() -> UIGlassEffect {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        return glass
    }

    // MARK: - Geometry, in the wheel's bounds

    /// Travel from rest (> 0: next emotes out of the like).
    private var travel: CGFloat {
        guard let rail else { return 0 }
        return rail.bounds.origin.y + rail.contentInset.top
    }

    /// The first next emote's way, from hidden in the like (0) to whole in
    /// the window (1): one step of travel.
    var bridgeProgress: CGFloat { max(0, min(1, travel / SnapShortcutRailView.step)) }

    /// The bridge (0 … 1): the second half of the first step, smoothed.
    var bridge: CGFloat {
        let t = max(0, min(1, (bridgeProgress - 0.5) / 0.5))
        return t * t * (3 - 2 * t)
    }

    /// The like retracting into the capsule: the last quarter of the bridge.
    var likeCover: CGFloat {
        guard !isDismissed else { return 0 }
        let t = max(0, min(1, (bridge - Self.bridgeReach) / (1 - Self.bridgeReach)))
        return t * t * (3 - 2 * t)
    }

    /// The capsule's frame in the wheel's bounds: the like's width, from the
    /// top visible emote to the lowest. Its top follows the first emote and
    /// stops at the wheel's top; its bottom stops over the fade above the
    /// like, or follows the last emote if it rises. Bridged, its bottom comes
    /// down to the like PILL's bottom. Shorter than wide, it becomes a circle
    /// that shrinks to nothing, sliding into the like's heart.
    var frameInRail: CGRect {
        guard let rail else { return .zero }
        let bounds = rail.bounds
        let step = SnapShortcutRailView.step
        let likeTop = bounds.maxY - rail.bottomReservedInset
        let restTop = likeTop - SnapShortcutRailView.edgeFadeLength - SnapShortcutRailView.restingWindowHeight - Self.pad
        let top = max(restTop - travel, bounds.minY)
        let lastBottom = restTop - travel + CGFloat(rail.emotes.count) * step
            - SnapShortcutRailView.iconSpacing + 2 * Self.pad
        let restBottom = min(likeTop - SnapShortcutRailView.edgeFadeLength + Self.pad, lastBottom)
        let bridgedBottom = likeTop + max(likeHeight, rail.bottomReservedInset)
        let bottom = restBottom + (bridgedBottom - restBottom) * min(1, bridge / Self.bridgeReach)
        let width = bounds.width
        let height = bottom - top
        guard height < width else { return CGRect(x: 0, y: top, width: width, height: height) }
        let side = max(0, height)
        let heart = likeTop + rail.bottomReservedInset / 2
        var centreY = (top + bottom) / 2
        centreY += (heart - centreY) * (1 - side / width)
        return CGRect(x: (width - side) / 2, y: centreY - side / 2, width: side, height: side)
    }

    // MARK: - Layout

    /// Re-stands the capsule, its drop, the like's cover and the chevron.
    func layout() {
        guard let rail, let superview = glass.superview else { return }
        // ⚠️ Its touches are the wheel's: none while the wheel is not there
        // (care mode, the comments' fade, the comments' dismissal) — the
        // column's glass, which never fades, would keep them otherwise.
        let wheelShows = !rail.isHidden && (rail.superview?.alpha ?? 1) > 0.01
        glass.isUserInteractionEnabled = !isDismissed && wheelShows
        // By bounds and centre: the interactive reaction transforms the glass.
        let frame = rail.convert(frameInRail, to: superview)
        glass.bounds = CGRect(origin: .zero, size: frame.size)
        glass.center = CGPoint(x: frame.midX, y: frame.midY)
        layoutDrop(in: superview)
        let cover = likeCover * max(0, min(1, presence.x))
        if cover != lastCover {
            lastCover = cover
            onLikeCover?(cover)
        }
        let shown = isWanted && !isDismissed && travel >= SnapShortcutRailView.step - 0.5
        if shown != returnShown {
            returnShown = shown
            onReturnShown?(shown)
        }
    }

    /// The first next emote's drop, over the first step (u = `bridgeProgress`):
    /// born hidden in the like's heart, it rises with the emote taking the
    /// like's width, never detaching — on the second half the capsule comes
    /// down into the like and the drop melts into it.
    private func layoutDrop(in superview: UIView) {
        let u = bridgeProgress
        guard let rail, !isDismissed, isWanted, u > 0.001, u < 0.999 else {
            drop?.removeFromSuperview()
            drop = nil
            return
        }
        let view: UIVisualEffectView
        if let drop {
            view = drop
        } else {
            view = UIVisualEffectView(effect: rail.window == nil ? nil : UIGlassEffect(style: .regular))
            view.cornerConfiguration = .capsule()
            view.isUserInteractionEnabled = false
            host?(view)
            drop = view
        }
        let bounds = rail.bounds
        let likeTop = bounds.maxY - rail.bottomReservedInset
        let heart = likeTop + rail.bottomReservedInset / 2
        let start = likeTop - SnapShortcutRailView.edgeFadeLength + SnapShortcutRailView.iconSpacing
            + SnapShortcutRailView.iconDiameter / 2
        let full = bounds.width
        let side: CGFloat
        if u < 0.5 {
            let k = min(1, sin(.pi * u) / Self.dropPlateau)
            side = Self.dropHidden + (full - Self.dropHidden) * k * k * (3 - 2 * k)
        } else {
            side = full - (full - Self.dropHidden) * bridge
        }
        let emoteY = start - SnapShortcutRailView.step * u
        let centre = CGPoint(x: bounds.midX, y: emoteY + (heart - start) * (1 - u) * (1 - u))
        view.frame = rail.convert(
            CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side), to: superview
        )
    }

    // MARK: - Lifetime

    /// The wheel is active: finger down, drag, glide, bounce or the return
    /// scroll.
    private var isActive: Bool {
        guard let rail else { return false }
        return touched || rail.isTracking || rail.isDragging || rail.isDecelerating || autoScrolling
    }

    @objc private func pressChanged() {
        switch press.state {
        case .began: touched = true
        case .ended, .cancelled, .failed: touched = false
        default: return
        }
        update()
    }

    private func touchDown() {
        guard !isDismissed, rail?.isUserInteractionEnabled == true else { return }
        lingerItem?.cancel()
        lingerItem = nil
        isWanted = true
        setPresence(true)
        show(settle: false)
    }

    /// The wheel's state changed: shown while active, lingering after.
    func update() {
        let active = isActive
        if active || isDismissed {
            lingerItem?.cancel()
            lingerItem = nil
        } else if wasActive {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                lingerItem = nil
                update()
            }
            lingerItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: item)
        }
        wasActive = active
        let wanted = !isDismissed && (active || lingerItem != nil)
        isWanted = wanted
        setPresence(wanted)
        layout()
        if wanted {
            show(settle: travel >= Self.settleTravel)
        } else {
            hide(animated: glass.window != nil)
        }
    }

    /// The comments took the page (the column folds into the sound): the
    /// capsule goes at once. `false` lets it come back with the next touch.
    func setDismissed(_ dismissed: Bool) {
        guard dismissed != isDismissed else { return }
        isDismissed = dismissed
        touched = false
        if dismissed {
            presence = Spring(0)
            hide(animated: false)
        }
        update()
    }

    /// A tap on the chevron: the wheel scrolls back to rest.
    @objc private func returnTapped() { returnToRest() }

    /// The wheel scrolls back to rest, the capsule riding the scroll.
    func returnToRest() {
        guard let rail else { return }
        autoScrolling = true
        rail.scrollToRest()
        update()
    }

    /// The return scroll ended, or a drag took over.
    func endAutoScroll() {
        autoScrolling = false
    }

    /// Whether a touch at `point` (in the wheel's space) is a tap on the
    /// chevron: on the like, while it shows.
    fileprivate func acceptsReturnTouch(at point: CGPoint) -> Bool {
        guard returnShown, let rail else { return false }
        let likeTop = rail.bounds.maxY - rail.bottomReservedInset
        return point.y >= likeTop && point.y <= likeTop + max(likeHeight, rail.bottomReservedInset)
    }

    fileprivate func location(of touch: UITouch) -> CGPoint {
        rail.map { touch.location(in: $0) } ?? .zero
    }

    // MARK: - The native glass

    /// The like's presence under the capsule (0 … 1, UIKit's default
    /// spring): the like retracts as the capsule comes, and re-inflates —
    /// hidden under it — before it goes.
    private func setPresence(_ on: Bool) {
        let target: CGFloat = on ? 1 : 0
        guard presence.target != target else { return }
        presence.target = target
        startLink()
    }

    private func show(settle: Bool) {
        if let run {
            if settle {
                self.run = nil
                run.stopAnimation(false)
                run.finishAnimation(at: .end)
            }
            return
        }
        if hiding || glass.effect == nil { appear() }
    }

    /// As close to the system as it gets: the effect animated to nil by
    /// `UIView.animate(springDuration:)`, from the glass as it is.
    private func hide(animated: Bool) {
        if hiding { return }
        guard run != nil || glass.effect != nil else { return }
        // Bridged: the like re-inflates first, hidden under the capsule,
        // which only leaves once it has (`tick` asks again).
        if animated, likeCover * presence.x > 0.01 { return }
        if let run {
            run.stopAnimation(true)
            self.run = nil
        }
        guard animated else {
            UIView.performWithoutAnimation { glass.effect = nil }
            return
        }
        hiding = true
        hideToken += 1
        let token = hideToken
        UIView.animate(springDuration: 0.5, animations: { [glass] in
            glass.effect = nil
        }, completion: { [weak self] _ in
            guard let self, hideToken == token else { return }
            hiding = false
            update()
        })
    }

    /// UIKit's default spring in a started animator: only it can be
    /// finished at once.
    private func appear() {
        guard glass.window != nil else { return }
        if hiding {
            hiding = false
            hideToken += 1
        }
        UIView.performWithoutAnimation { glass.effect = nil }
        let animator = UIViewPropertyAnimator(
            duration: 0, timingParameters: UISpringTimingParameters(duration: 0.5, bounce: 0)
        )
        animator.addAnimations { [glass] in glass.effect = Self.makeGlass() }
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self, let animator, run === animator else { return }
            run = nil
            update()
        }
        run = animator
        animator.startAnimation()
    }

    // MARK: - The presence spring

    private func startLink() {
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: CapsuleTick(self), selector: #selector(CapsuleTick.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = min(max(0, now - lastTick), 0.05)
        lastTick = now
        let steps = max(1, Int(ceil(dt / 0.004)))
        for _ in 0..<steps { presence.step(dt / Double(steps), k: Self.systemSpringK, zeta: 1) }
        if presence.settled {
            presence.x = presence.target
            presence.v = 0
        }
        layout()
        if presence.settled {
            link.invalidate()
            self.link = nil
            // The like re-inflated: the capsule may leave now.
            if !isWanted { update() }
        }
    }

    // MARK: - Tests

    #if DEBUG
    /// Runs the linger out now.
    func debugExpireLinger() {
        lingerItem?.cancel()
        lingerItem = nil
        update()
    }

    /// The finger lands on the capsule, then lifts.
    func debugTouch(down: Bool) {
        if down { touchDown() }
        touched = down
        update()
    }

    var debugIsLingering: Bool { lingerItem != nil }
    #endif

    private struct Spring {
        var x: CGFloat
        var v: CGFloat = 0
        var target: CGFloat
        init(_ x: CGFloat) {
            self.x = x
            target = x
        }

        mutating func step(_ h: Double, k: Double, zeta: Double) {
            let a = CGFloat(k) * (target - x) - CGFloat(2 * zeta * sqrt(k)) * v
            v += a * CGFloat(h)
            x += v * CGFloat(h)
        }

        var settled: Bool { abs(target - x) < 0.01 && abs(v) < 0.05 }
    }
}

/// The capsule's glass: reports a touch's start from `hitTest`, before the
/// touch is handed to the gestures (and to the glass's interactive
/// reaction), so the reaction already sees glass on the first touch. A
/// marker too: the feed's pager treats it as the wheel's territory.
final class SnapWheelGlassView: UIVisualEffectView {
    var onTouchDown: (() -> Void)?
    private var lastEvent: TimeInterval = -1

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, let event, event.type == .touches, event.timestamp != lastEvent {
            lastEvent = event.timestamp
            onTouchDown?()
        }
        return hit
    }
}

/// The press on the capsule is recognized alongside the wheel's scroll.
private final class SimultaneousGestures: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

/// The return tap takes only touches on the like, chevron shown.
@MainActor
private final class ReturnTapFilter: NSObject, UIGestureRecognizerDelegate {
    weak var capsule: SnapWheelCapsule?

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let capsule else { return false }
        return capsule.acceptsReturnTouch(at: capsule.location(of: touch))
    }
}

/// Holds the capsule for its display link without keeping it alive.
@MainActor
private final class CapsuleTick: NSObject {
    weak var capsule: SnapWheelCapsule?
    init(_ capsule: SnapWheelCapsule) { self.capsule = capsule }

    @objc func tick(_ link: CADisplayLink) {
        guard let capsule else { return link.invalidate() }
        capsule.tick(link)
    }
}
