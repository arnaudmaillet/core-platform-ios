import UIKit

/// THE app's loading timing (#1756, #1768): one set of numbers every loading
/// state reads — a picture's bone (`LoadingLadder`), a screen's skeleton
/// (`SkeletonGate`) and a loader (`LoaderGate`).
///
/// - `skeletonDelay`: nothing for this long, then the bones — a load that
///   lands at once never shows one.
/// - `loaderGrace`: a spinner waits longer than a bone. It is motion that
///   means "waiting", so it disturbs more than a still grey shape, and the
///   consensus (TikTok, Instagram, the web's 200–300 ms) is that anything
///   faster than a quarter of a second must not announce itself.
/// - `minimum`: once shown, a skeleton or a loader stays this long — a load
///   landing just after the delay never flashes it for a frame.
/// - `takingLonger`: still loading after this long, the screen says so and
///   offers a way out (Try Again) rather than an endless shimmer.
public enum LoadingTiming {
    public static let skeletonDelay: TimeInterval = 0.15
    public static let loaderGrace: TimeInterval = 0.25
    public static let minimum: TimeInterval = 0.3
    public static let takingLonger: TimeInterval = 10
}

/// Time, injectable: a test steps it. The one clock of every loading state —
/// `SkeletonGate.Clock` and `LoadingLadder.Clock` are this type.
public struct LoadingClock {
    public var now: @MainActor () -> TimeInterval
    public var after: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    public init(
        now: @escaping @MainActor () -> TimeInterval,
        after: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    ) {
        self.now = now
        self.after = after
    }

    public static var system: LoadingClock {
        LoadingClock(now: { CACurrentMediaTime() }, after: { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
        })
    }
}

/// When a loader shows (#1768): nothing for `grace`, then the loader, held at
/// least `minimum` once up — the screen-level `SkeletonGate`'s rule for a
/// spinner, so no host writes its own timer around `startAnimating`.
///
/// `begin` arms the grace; `end` takes the loader down (after its minimum).
/// A host whose answer can change during the grace passes `stillWaiting`,
/// asked AGAIN when the grace runs out: the whole point of waiting is that
/// the answer may have changed.
@MainActor
public final class LoaderGate {
    public let grace: TimeInterval
    public let minimum: TimeInterval
    private let clock: LoadingClock
    private let show: (Bool) -> Void
    private var generation = 0
    private var shownAt: TimeInterval?

    /// Whether the grace is running.
    public private(set) var isArmed = false
    /// Whether the loader is up — including the minimum's tail after `end`.
    public private(set) var isShowing = false

    /// `show(true)` puts the loader up, `show(false)` takes it down.
    public init(
        grace: TimeInterval = LoadingTiming.loaderGrace, minimum: TimeInterval = LoadingTiming.minimum,
        clock: LoadingClock = .system, show: @escaping (Bool) -> Void
    ) {
        self.grace = grace
        self.minimum = minimum
        self.clock = clock
        self.show = show
    }

    /// A gate driving `loader`'s animation (`hidesWhenStopped` hides it).
    public convenience init(
        loader: AppLoaderView,
        grace: TimeInterval = LoadingTiming.loaderGrace, minimum: TimeInterval = LoadingTiming.minimum,
        clock: LoadingClock = .system
    ) {
        self.init(grace: grace, minimum: minimum, clock: clock) { [weak loader] showing in
            showing ? loader?.startAnimating() : loader?.stopAnimating()
        }
    }

    /// A wait starts: the loader after the grace, if `stillWaiting` still
    /// says so then. Nothing when already armed or showing — and a loader
    /// on its minimum's tail stays up.
    public func begin(stillWaiting: @escaping @MainActor () -> Bool = { true }) {
        if isShowing, shownAt == nil {
            // `end` was holding it for its minimum: the wait is back, keep it.
            generation += 1
            shownAt = clock.now() - minimum
            return
        }
        guard !isArmed, !isShowing else { return }
        isArmed = true
        generation += 1
        let current = generation
        let reveal: @MainActor () -> Void = { [weak self] in
            guard let self, generation == current, isArmed else { return }
            isArmed = false
            pendingReveal = nil
            guard stillWaiting() else { return }
            shownAt = clock.now()
            setShowing(true)
        }
        pendingReveal = reveal
        clock.after(grace, reveal)
    }

    /// The grace's end, while it runs.
    private var pendingReveal: (@MainActor () -> Void)?

    #if DEBUG
    /// Runs the grace out now, so a spec need not wait for a delay whose
    /// length is not the claim under test.
    public func debugElapseGrace() {
        pendingReveal?()
    }
    #endif

    /// The wait is over: the loader goes now, or once it has had its minimum;
    /// `then` runs when it has (a second `end` while it is going adds none).
    public func end(_ then: @escaping @MainActor () -> Void = {}) {
        isArmed = false
        pendingReveal = nil
        guard isShowing else {
            generation += 1
            return then()
        }
        // Already on its way down (a second `end` in the minimum's tail):
        // the first one's hide stands.
        guard let shownAt else { return }
        generation += 1
        self.shownAt = nil
        let remaining = minimum - (clock.now() - shownAt)
        guard remaining > 0 else {
            setShowing(false)
            return then()
        }
        let current = generation
        clock.after(remaining) { [weak self] in
            guard let self, generation == current else { return }
            setShowing(false)
            then()
        }
    }

    /// Drops the wait at once, minimum or not — a recycled host.
    public func cancel() {
        isArmed = false
        pendingReveal = nil
        generation += 1
        shownAt = nil
        setShowing(false)
    }

    private func setShowing(_ showing: Bool) {
        let changed = showing != isShowing
        isShowing = showing
        if changed || !showing { show(showing) }
    }
}
