import QuartzCore
import UIKit

/// The curve the editing band's contents arrive and leave on: each element
/// scales and fades in, one after another, so a row of nine filters reads as a
/// ripple rather than a slab switched on.
///
/// Pure values, so the timing is assertable without a screen — `MapAnnotationPop`
/// states the same reason for the map's pins, and this is that idea at the foot
/// of the editor.
///
/// ⚠️ **THE STAGGER IS CAPPED, AND THE CAP IS THE POINT.** Unbounded, a
/// twelve-pill effects row would still be arriving a full half-second after the
/// author's finger left the icon — and the last pills would land after they had
/// already started reaching for one. The cap turns the tail into a dense ripple
/// instead of a queue.
enum BandPop {
    /// ⚠️ **SHORTER THAN THE MAP'S 0.32.** A pin travels across a map the eye is
    /// already scanning; these elements appear under the finger that asked for
    /// them, where a long curve reads as lag rather than as motion.
    static let duration: TimeInterval = 0.28

    /// How long a departure takes.
    ///
    /// ⚠️ **QUICKER THAN THE ARRIVAL, AND ONE NUMBER FOR EVERYTHING THAT
    /// LEAVES.** Leaving is not an event the author is reading — they have
    /// already asked for something else — so it gets out of the way. It was
    /// written as `duration * 0.6` in two places, the band's tenants and the
    /// finalisation strip's cover badge, which is two numbers waiting to drift.
    static let departure: TimeInterval = duration * 0.6

    /// Just under-damped — a trace of settle, so an element feels placed rather
    /// than switched on. The map's pins use 0.75 for a transform of half size;
    /// these start closer to full size, so they want a touch more bounce to
    /// read at all.
    static let dampingRatio: CGFloat = 0.7

    /// Where an element starts, and returns to.
    ///
    /// ⚠️ **NOT THE MAP'S 0.5.** A filter card carries a picture and a caption;
    /// at half size the caption is unreadable for the whole curve and the card
    /// reads as a different, smaller control that then grows. Three quarters is
    /// enough travel to be seen as arriving and little enough to stay itself.
    static let collapsedScale: CGFloat = 0.76

    /// Between one element and the next.
    ///
    /// ⚠️ **40ms, WHICH IS ALSO WHAT THE SOUND WAS CHOSEN AGAINST.** The pop
    /// each element makes is auditioned at exactly this spacing; a shorter step
    /// smears nine of them into one noise, and a longer one turns a ripple into
    /// a countdown.
    static let staggerStep: TimeInterval = 0.04

    /// ⚠️ **SEVEN ELEMENTS' WORTH.** Past that the ear stops counting and the
    /// eye stops following, so everything later arrives together.
    static let staggerCap: TimeInterval = 0.28

    /// The delay for the element at `index`.
    static func stagger(for index: Int) -> TimeInterval {
        min(Double(max(0, index)) * staggerStep, staggerCap)
    }

    /// How long the whole choreography takes for `count` elements — what a
    /// caller must wait before the band is settled.
    static func settled(after count: Int) -> TimeInterval {
        stagger(for: max(0, count - 1)) + duration
    }

    /// ⚠️ **HOW MANY ELEMENTS ARE WORTH POPPING AT ALL.** A row can hold more
    /// than the eye can follow; past this many the rest simply arrive with the
    /// last one, and — more importantly — no sound is owed for them. Twelve is
    /// the effects row, which is the longest tenant this screen has.
    static let audibleElements = 7

    /// How far along a graduation at `x` is, for a strip `width` wide that has
    /// revealed `reveal` of itself.
    ///
    /// ⚠️ **OUT FROM THE NEEDLE, WHICH IS THE MIDDLE.** The needle is where the
    /// author is reading; graduations arriving from one end would sweep past it
    /// rather than out of it.
    ///
    /// ⚠️ **AND THE ENDS START BEFORE THE MIDDLE HAS FINISHED.** Waiting would
    /// make the sweep take twice the curve it is given: the last tick begins at
    /// `lead`, so everything is travelling for most of the way and everything
    /// lands together.
    static func landed(_ x: CGFloat, reveal: CGFloat, width: CGFloat) -> CGFloat {
        guard reveal < 1 else { return 1 }
        guard reveal > 0 else { return 0 }
        let half = max(1, width / 2)
        let fromNeedle = min(1, abs(x - width / 2) / half)
        let lead: CGFloat = 0.45
        return min(1, max(0, (reveal - fromNeedle * lead) / (1 - lead)))
    }

    static var collapsedTransform: CGAffineTransform {
        CGAffineTransform(scaleX: collapsedScale, y: collapsedScale)
    }
}

/// A band tenant that has elements worth popping in one at a time.
///
/// ⚠️ **THE TENANT NAMES THEM, BECAUSE ONLY IT KNOWS WHAT AN ELEMENT IS.**
/// Walking the view tree from the outside would pop a scroll view's own
/// container, a divider, and the glass behind everything — the choreography
/// wants the things the author reads as items, in the order they are read.
@MainActor
protocol PoppingTenant: UIView {
    var poppableElements: [UIView] { get }
    /// Surfaces that reveal rather than pop — see `RevealingSurface`.
    var revealingSurfaces: [RevealingSurface] { get }
}

extension PoppingTenant {
    /// Most tenants have none.
    var revealingSurfaces: [RevealingSurface] { [] }
}

/// A surface whose arrival is a REVEAL rather than a pop: a ruler's
/// graduations, which are drawn rather than laid out.
///
/// ⚠️ **A VALUE READ INSIDE `draw(_:)` IS NOT A VIEW PROPERTY, SO
/// `UIView.animate` CANNOT REACH IT.** Scaling the whole ruler instead would
/// squash the graduations toward each other, which is the one thing a ruler
/// must not do — the spacing IS the information. What travels is each tick's
/// own length, out from the needle.
@MainActor
protocol RevealingSurface: UIView {
    /// Draws the surface from nothing to whole, starting `delay` from now.
    func reveal(after delay: TimeInterval)
}

/// Drives a 0→1 scalar over `BandPop.duration`, for a curve UIKit cannot
/// animate on its own.
///
/// ⚠️ **ONE LINK, STOPPED THE MOMENT IT IS DONE.** A display link left running
/// is a callback at screen rate for the life of the screen — and this one drives
/// a `setNeedsDisplay`, so it would redraw a settled ruler sixty times a second
/// forever. `MediaEditorViewController`'s own follower states the same rule for
/// the timeline's playhead.
@MainActor
final class RevealDriver {
    private var link: CADisplayLink?
    private var startsAt: CFTimeInterval = 0
    private let step: (CGFloat) -> Void
    /// ⚠️ **THE LINK HOLDS ITS TARGET STRONGLY, AND THE RUN LOOP HOLDS THE
    /// LINK** — so a driver that were its own target could never be
    /// deallocated, and could therefore never invalidate the link from
    /// `deinit`. (Nor may a `deinit` touch a `CADisplayLink` at all under Swift
    /// 6: it is not `Sendable`, and a `deinit` is nonisolated.) The same reason,
    /// and the same shape, as `DisplayLinkProxy` in the editor.
    private let proxy = RevealLinkProxy()

    init(step: @escaping (CGFloat) -> Void) {
        self.step = step
        proxy.driver = self
    }

    /// Runs from nothing to whole, after `delay`.
    func run(after delay: TimeInterval) {
        stop()
        step(0)
        startsAt = CACurrentMediaTime() + delay
        let link = CADisplayLink(target: proxy, selector: #selector(RevealLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        proxy.link = link
        self.link = link
    }

    /// Puts the surface back at whole and stops — for Reduce Motion, and for a
    /// surface that is asked to settle before its curve is over.
    func stop() {
        link?.invalidate()
        link = nil
        step(1)
    }

    fileprivate func tick() {
        let elapsed = CACurrentMediaTime() - startsAt
        guard elapsed >= 0 else { return }
        guard elapsed < BandPop.duration else {
            stop()
            return
        }
        // ⚠️ **EASED OUT, NOT LINEAR.** The pops it arrives with are springs;
        // a linear ruler beside them reads as a progress bar.
        let fraction = elapsed / BandPop.duration
        step(CGFloat(1 - pow(1 - fraction, 3)))
    }
}

/// Holds the display link's target weakly — see `RevealDriver.proxy`.
@MainActor
private final class RevealLinkProxy: NSObject {
    weak var driver: RevealDriver?
    weak var link: CADisplayLink?

    @objc func tick() {
        guard let driver else {
            link?.invalidate()
            return
        }
        driver.tick()
    }
}
