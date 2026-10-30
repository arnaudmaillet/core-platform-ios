import QuartzCore
import UIKit

/// A hold that ARMS an action on any view (#1929): the tab bar "+"'s gesture,
/// for the composer's slot — after a moment a glass disc rises over the view
/// carrying what the hold will do, a ring fills while the finger stays down,
/// and the moment it is full the action fires. Lifted or slid off before:
/// nothing.
///
/// ```
///   touch ─ 0.22s ─▶ disc rises (held tick) ─ 0.6s fill ─▶ fires (armed tick)
/// ```
///
/// ONE PRESENTER FOR EVERY HOLD, the tab bar's "+" included
/// (`CreateHoldShortcut`): the timing, the ticks, the disc and its clock live
/// here once, so the holds cannot drift apart. A host with a placement of its
/// own (the "+" is one bubble of a bar) says where the disc goes
/// (`discFrame`, `host`) and hears the press come and go (`onPressBegan`,
/// `onPressFinished`). A SHORTCUT, never the only road: the host keeps the
/// action as an accessibility custom action, or a menu row.
@MainActor
public final class HoldToArmPresenter: NSObject {
    /// What the disc carries.
    public enum Face: Equatable {
        case symbol(String)
        case picture(UIImage?)
    }

    public enum Metrics {
        /// The "+"'s: longer than a tap, shorter than a hesitation.
        public static let recognitionDelay: TimeInterval = 0.22
        public static let preRecognitionSlop: CGFloat = 10
        /// Between the disc and the top of the view it floats over.
        public static let gap: CGFloat = 12
        /// The disc never comes closer than this to the screen's edge.
        public static let edgeMargin: CGFloat = 8
    }

    /// What the disc shows when it rises.
    public var face: @MainActor () -> Face
    /// What the disc says once the action fired, before it retreats — the new
    /// state the view itself cannot show. Nil keeps `face`.
    public var firedFace: (@MainActor () -> Face)?
    /// The action, at the ring's fill.
    public var onFire: (@MainActor () -> Void)?
    /// The view the disc is added to. Nil: the window's root view.
    public var host: (@MainActor () -> UIView?)?
    /// Where the disc goes, in `host`'s space — for a hold whose view is not
    /// the thing it floats over (the "+" hangs on the whole bar). Nil:
    /// centred over the view, `Metrics.gap` above it, clear of the edges.
    public var discFrame: (@MainActor (_ host: UIView) -> CGRect?)?
    /// A press was recognised, before anything shows.
    public var onPressBegan: (@MainActor () -> Void)?
    /// The press ended — lifted, slid off or cancelled — whatever it did.
    public var onPressFinished: (@MainActor () -> Void)?

    private weak var target: UIView?
    private let recognizer = UILongPressGestureRecognizer()
    private var hold = HoldToArm(firesWhenFull: true)
    private var disc: HoldRingDiscView?
    private var displayLink: CADisplayLink?

    /// Hangs the hold on `view`.
    public init(view: UIView, face: @escaping @MainActor () -> Face) {
        self.target = view
        self.face = face
        super.init()
        recognizer.addTarget(self, action: #selector(handle(_:)))
        recognizer.minimumPressDuration = Metrics.recognitionDelay
        recognizer.allowableMovement = Metrics.preRecognitionSlop
        recognizer.name = "HoldToArmPresenter"
        view.addGestureRecognizer(recognizer)
    }

    /// Whether a hold arms anything now.
    public var isEnabled: Bool {
        get { recognizer.isEnabled }
        set {
            recognizer.isEnabled = newValue
            if !newValue, hold.isEngaged, let transition = hold.cancel() { apply(transition) }
        }
    }

    /// Whether a hold is under way: a press recognised and not yet over.
    public var isHolding: Bool { hold.isEngaged }

    /// The recogniser, for a host that must let other gestures wait on it.
    public var gestureRecognizer: UILongPressGestureRecognizer { recognizer }

    @objc private func handle(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: recognizer.view)
        switch recognizer.state {
        case .began: pressBegan(at: location)
        case .changed: pressMoved(to: location)
        case .ended: pressEnded()
        case .cancelled, .failed: pressCancelled()
        default: break
        }
    }

    private func pressBegan(at location: CGPoint) {
        onPressBegan?()
        guard let transition = hold.begin(at: CACurrentMediaTime(), location: location) else { return }
        apply(transition)
    }

    private func pressMoved(to location: CGPoint) {
        guard let transition = hold.move(to: location, at: CACurrentMediaTime()) else { return }
        apply(transition)
    }

    private func pressEnded() {
        let transition = hold.end(at: CACurrentMediaTime())
        onPressFinished?()
        if let transition { apply(transition) }
    }

    private func pressCancelled() {
        let transition = hold.cancel()
        onPressFinished?()
        if let transition { apply(transition) }
    }

    private func apply(_ transition: HoldToArm.Transition) {
        switch transition {
        case .revealed:
            showDisc()
            Haptics.play(.held)
            Haptics.prepare(.armed)
            startClock()
        case .armed:
            stopClock()
            disc?.setArmed(true)
            Haptics.play(.armed)
        case .fired:
            stopClock()
            Haptics.play(.armed)
            onFire?()
            if let firedFace { show(firedFace(), on: disc) }
            disc?.dismiss(.launch)
            disc = nil
        case .retracted, .abandoned:
            stopClock()
            disc?.dismiss(.retract)
            disc = nil
        }
    }

    private func show(_ face: Face, on disc: HoldRingDiscView?) {
        switch face {
        case .symbol(let name): disc?.setSymbol(name)
        case .picture(let image): disc?.setPicture(image)
        }
    }

    private func showDisc() {
        guard let target, let host = host?() ?? target.window?.rootViewController?.view ?? target.window
        else { return }
        // A host's placement may have none to give (its anchor not laid out):
        // then no disc, rather than one in the wrong place.
        let frame: CGRect
        if let discFrame {
            guard let placed = discFrame(host) else { return }
            frame = placed
        } else {
            frame = Self.frame(over: target.convert(target.bounds, to: host), in: host.bounds)
        }
        disc?.removeFromSuperview()
        let disc: HoldRingDiscView
        switch face() {
        case .symbol(let name):
            disc = HoldRingDiscView(symbolName: name)
        case .picture(let image):
            disc = HoldRingDiscView(symbolName: "music.note")
            disc.setPicture(image)
        }
        disc.frame = frame
        host.addSubview(disc)
        disc.appear()
        self.disc = disc
    }

    /// The disc's frame over `anchor`: centred on it, `Metrics.gap` above
    /// `ceiling` (its top by default), never nearer than `Metrics.edgeMargin`
    /// to `bounds`' sides. Pure, for hosts and tests.
    public static func frame(over anchor: CGRect, ceiling: CGFloat? = nil, in bounds: CGRect) -> CGRect {
        let side = HoldRingDiscView.Metrics.diameter
        let margin = Metrics.edgeMargin + side / 2
        let midX = min(max(anchor.midX, bounds.minX + margin), bounds.maxX - margin)
        return CGRect(x: midX - side / 2, y: (ceiling ?? anchor.minY) - Metrics.gap - side, width: side, height: side)
    }

    private func startClock() {
        stopClock()
        let link = CADisplayLink(target: ClockTarget(self), selector: #selector(ClockTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopClock() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        disc?.setProgress(hold.progress(at: now))
        if let transition = hold.tick(at: now) { apply(transition) }
    }

    @MainActor
    private final class ClockTarget: NSObject {
        weak var owner: HoldToArmPresenter?
        init(_ owner: HoldToArmPresenter) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { return link.invalidate() }
            owner.tick()
        }
    }

    #if DEBUG
    /// Where a hold stands, and the disc up — tests.
    public var debugPhase: HoldToArm.Phase { hold.phase }
    public var debugDisc: HoldRingDiscView? { disc }
    public var debugProgress: CGFloat { hold.progress(at: CACurrentMediaTime()) }
    /// A finger held on the view past the recognition delay (`.began`) — at
    /// its centre, or at `location` in its space.
    public func debugPress(at location: CGPoint? = nil) {
        pressBegan(at: location ?? CGPoint(x: target?.bounds.midX ?? 0, y: target?.bounds.midY ?? 0))
    }
    /// The finger sliding to `location`, in the view's space (`.changed`).
    public func debugMove(to location: CGPoint) { pressMoved(to: location) }
    /// The finger lifting (`.ended`).
    public func debugRelease() { pressEnded() }
    #endif
}
