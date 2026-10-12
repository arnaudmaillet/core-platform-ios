import UIKit

/// The time a toast stays up (#954): it runs down, pauses for as long as
/// anything asks it to (a finger on the toast, VoiceOver on it, the scene in
/// the background) and calls `onExpire` once when it runs out.
///
/// Driven by a `ToastClock`, so tests advance time by hand instead of
/// sleeping — a toast's timing is the kind of thing a starved runner turns
/// into a flake.
@MainActor
final class ToastCountdown {
    /// Why the countdown is held. It runs only while there is none.
    enum Hold: Hashable {
        /// A finger is on the toast.
        case touch
        /// VoiceOver's focus is on the toast.
        case voiceOverFocus
        /// The scene is not active (backgrounded, app switcher, a call).
        case sceneInactive
    }

    /// What is left, in seconds.
    private(set) var remaining: TimeInterval
    private(set) var holds: Set<Hold> = []
    private(set) var hasExpired = false
    private let clock: ToastClock
    private let onExpire: @MainActor () -> Void
    /// When the current run started, while running.
    private var runStart: TimeInterval?
    private var pending: ToastClock.Token?

    init(seconds: TimeInterval, clock: ToastClock, onExpire: @escaping @MainActor () -> Void) {
        remaining = max(0, seconds)
        self.clock = clock
        self.onExpire = onExpire
    }

    var isRunning: Bool { runStart != nil }

    /// Starts it, unless something already holds it.
    func start() {
        guard !hasExpired, holds.isEmpty, runStart == nil else { return }
        runStart = clock.now()
        let left = remaining
        pending = clock.schedule(after: left) { [weak self] in self?.expire() }
    }

    func hold(_ reason: Hold) {
        guard !hasExpired else { return }
        let wasRunning = isRunning
        holds.insert(reason)
        if wasRunning { stopRun() }
    }

    func release(_ reason: Hold) {
        guard holds.remove(reason) != nil else { return }
        start()
    }

    /// Stops for good, without expiring (the toast left another way).
    func cancel() {
        hasExpired = true
        pending?.cancel()
        pending = nil
        runStart = nil
    }

    private func stopRun() {
        guard let started = runStart else { return }
        remaining = max(0, remaining - (clock.now() - started))
        runStart = nil
        pending?.cancel()
        pending = nil
    }

    private func expire() {
        guard !hasExpired else { return }
        hasExpired = true
        runStart = nil
        pending = nil
        remaining = 0
        onExpire()
    }
}

/// The clock a toast's countdown reads and schedules on: the real one in the
/// app, a hand-driven one in tests (`ToastClock.manual`).
@MainActor
final class ToastClock {
    /// A scheduled call, cancellable.
    @MainActor
    final class Token {
        fileprivate var cancelled = false
        fileprivate init() {}
        func cancel() { cancelled = true }
    }

    typealias Body = @MainActor () -> Void

    let now: () -> TimeInterval
    private let scheduler: (TimeInterval, Token, @escaping Body) -> Void

    init(
        now: @escaping () -> TimeInterval,
        scheduler: @escaping (TimeInterval, Token, @escaping Body) -> Void
    ) {
        self.now = now
        self.scheduler = scheduler
    }

    func schedule(after seconds: TimeInterval, _ body: @escaping Body) -> Token {
        let token = Token()
        scheduler(seconds, token) { [weak token] in
            guard let token, !token.cancelled else { return }
            body()
        }
        return token
    }

    /// The real clock: `CACurrentMediaTime` and the main queue.
    static let live = ToastClock(
        now: { CACurrentMediaTime() },
        scheduler: { seconds, token, body in
            // The token is kept alive by the closure until it fires.
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated {
                    _ = token
                    body()
                }
            }
        }
    )

    /// The clock every new toast uses. Tests swap it, synchronously, and put
    /// it back before returning.
    static var current: ToastClock = .live

    /// A clock that moves only when told to (`advance(by:)`).
    static func manual() -> (clock: ToastClock, advance: (TimeInterval) -> Void) {
        final class State {
            var time: TimeInterval = 0
            var queue: [(at: TimeInterval, token: Token, body: Body)] = []
        }
        let state = State()
        let clock = ToastClock(
            now: { state.time },
            scheduler: { seconds, token, body in state.queue.append((state.time + seconds, token, body)) }
        )
        let advance: (TimeInterval) -> Void = { seconds in
            let target = state.time + seconds
            while let next = state.queue.enumerated()
                .filter({ !$0.element.token.cancelled && $0.element.at <= target })
                .min(by: { $0.element.at < $1.element.at }) {
                state.queue.remove(at: next.offset)
                state.time = next.element.at
                next.element.body()
            }
            state.queue.removeAll { $0.token.cancelled }
            state.time = target
        }
        return (clock, advance)
    }
}
