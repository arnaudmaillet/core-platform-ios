import UIKit

/// THE timing of every screen-level skeleton (#1756), the loading ladder's
/// (`LoadingLadder.Policy`) applied to a section or a screen: nothing for
/// `delay`, then the bones, held at least `minimum` once shown, and after
/// `takingLonger` the host is told, to offer a way out (Try Again) rather
/// than an endless shimmer.
///
/// The gate decides only WHEN the bones show; the host keeps the section's
/// room reserved from the start (its height does not wait for the delay),
/// so the delay never moves the layout.
@MainActor
public final class SkeletonGate {
    public struct Timing: Sendable {
        public var delay: TimeInterval
        public var minimum: TimeInterval
        public var takingLonger: TimeInterval

        public init(
            delay: TimeInterval = LoadingTiming.skeletonDelay, minimum: TimeInterval = LoadingTiming.minimum,
            takingLonger: TimeInterval = LoadingTiming.takingLonger
        ) {
            self.delay = delay
            self.minimum = minimum
            self.takingLonger = takingLonger
        }

        public static let standard = Timing()
    }

    /// A clock a test can step — the loading kit's one clock.
    public typealias Clock = LoadingClock

    public let timing: Timing
    private let clock: Clock
    private var generation = 0
    private var shownAt: TimeInterval?

    /// Whether the bones show now.
    public private(set) var showsSkeleton = false {
        didSet { if showsSkeleton != oldValue { onSkeletonChange?(showsSkeleton) } }
    }
    /// The bones come or go.
    public var onSkeletonChange: ((Bool) -> Void)?
    /// Still loading after `timing.takingLonger`.
    public var onTakingLonger: (() -> Void)?
    /// Whether a load is under way.
    public private(set) var isLoading = false

    public init(timing: Timing = .standard, clock: Clock = .system) {
        self.timing = timing
        self.clock = clock
    }

    /// A load starts: the bones after the delay, the warning after the long wait.
    public func begin() {
        guard !isLoading else { return }
        isLoading = true
        generation += 1
        // A reveal still waiting out the last bones' minimum belonged to the
        // load this one replaces.
        pendingReveal = nil
        let current = generation
        clock.after(timing.delay) { [weak self] in
            guard let self, generation == current, isLoading else { return }
            shownAt = clock.now()
            showsSkeleton = true
        }
        clock.after(timing.takingLonger) { [weak self] in
            guard let self, generation == current, isLoading else { return }
            onTakingLonger?()
        }
    }

    /// The content answered (or failed): `reveal` runs now, or once the bones
    /// have had their minimum.
    public func finish(_ reveal: @escaping @MainActor () -> Void = {}) {
        guard isLoading else {
            // ⚠️ A REVEAL STILL WAITING OUT THE BONES' MINIMUM IS REPLACED,
            // never run after this one (#1786): a newer answer landing first
            // and the older one landing over it a beat later was a stale page
            // and two reloads. The newest answer lands, once, when the bones go.
            if pendingReveal != nil {
                pendingReveal = reveal
                return
            }
            return reveal()
        }
        isLoading = false
        generation += 1
        let current = generation
        guard let shownAt else {
            showsSkeleton = false
            return reveal()
        }
        let remaining = timing.minimum - (clock.now() - shownAt)
        guard remaining > 0 else {
            self.shownAt = nil
            showsSkeleton = false
            return reveal()
        }
        pendingReveal = reveal
        clock.after(remaining) { [weak self] in
            guard let self, generation == current else { return }
            self.shownAt = nil
            showsSkeleton = false
            let reveal = pendingReveal
            pendingReveal = nil
            reveal?()
        }
    }

    /// The reveal waiting out the bones' minimum, the newest answer's.
    private var pendingReveal: (@MainActor () -> Void)?

    /// Whether an answer is waiting out the bones' minimum: the bones are
    /// still up for it, and a new `begin()` would drop it.
    public var isRevealing: Bool { pendingReveal != nil }
}
