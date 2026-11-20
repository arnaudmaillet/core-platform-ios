import Foundation

/// Who is using the app changed: the app's one channel for it (#2376).
///
/// It replaces the raw names posted on `NotificationCenter.default`
/// (`.viewerDidChange`, `.activeProfileDidChange`): a surface hears the
/// instance the composition root built once and handed in, so parallel test
/// suites never hear each other, and the active profile is a typed payload
/// instead of a `userInfo` key.
///
/// - `publishViewerChange()`: a sign-out, a sign-in as someone else, an
///   account or a profile switch. `AppContainer.observeViewerTransitions`
///   publishes it once every `ViewerScoped` repository has dropped what it
///   held for the previous viewer, for the main-actor caches no repository
///   owns (`ProfileCache`, `UnavailablePosts`) and the screens that re-read.
/// - `publishActiveProfileChange(_:)`: the active profile switched, published
///   by the switcher as soon as the session holds it, BEFORE the viewer
///   transition above reaches the repositories. The id rides along so a
///   surface can render that profile from its cache on this very turn.
///
/// ⚠️ SYNCHRONOUS, ORDERED, ON THE MAIN ACTOR. Not an `AsyncStream`: a hop
/// between the cache wipe and the screens that re-read would let a screen read
/// the previous viewer's facts, or have the new viewer's first write wiped
/// after it. Handlers run before `publish…` returns, in this order:
/// 1. every `.caches` handler of `onViewerChange` (the cache coordinator's
///    wipe of the viewer namespaces, `AppCacheSignals`), whenever it
///    subscribed;
/// 2. every `.observers` handler, in the order they subscribed.
/// That is the order `NotificationCenter.default` gave in practice: the cache
/// signal was registered at launch, before any screen, and every observer
/// was on `queue: .main`, run inline by a post from the main thread.
///
/// ⚠️ KEEP THE `ViewerEventSubscription`: it stops the handler when it goes.
/// Hold it for as long as the old token or selector registration lived: on
/// the object that observes, usually.
@MainActor
public final class ViewerEvents {
    /// When a viewer-change handler runs.
    public enum Phase: Sendable {
        /// Before every observer: a cache that must forget before anyone
        /// re-reads.
        case caches
        /// After the caches, in subscription order.
        case observers
    }

    private let cacheDrops = OrderedHandlers<Void>()
    private let viewerChanges = OrderedHandlers<Void>()
    private let activeProfileChanges = OrderedHandlers<ProfileID>()

    nonisolated public init() {}

    #if DEBUG
    /// How many subscriptions are live: what a test reads to see that an
    /// observer kept its subscription, and that it ended with the observer.
    public var debugObservationCount: Int {
        cacheDrops.debugObservationCount + viewerChanges.debugObservationCount
            + activeProfileChanges.debugObservationCount
    }
    #endif

    /// The viewer is someone else now. Call it once every per-viewer
    /// repository has dropped the previous viewer's answers.
    public func publishViewerChange() {
        cacheDrops.send(())
        viewerChanges.send(())
    }

    /// The active profile switched to `profile`.
    public func publishActiveProfileChange(_ profile: ProfileID) {
        activeProfileChanges.send(profile)
    }

    /// Runs `handler` on every later viewer change, in `phase`, until the
    /// subscription is cancelled or freed.
    public func onViewerChange(
        _ phase: Phase = .observers,
        _ handler: @escaping @MainActor () -> Void
    ) -> ViewerEventSubscription {
        switch phase {
        case .caches: return cacheDrops.subscribe { _ in handler() }
        case .observers: return viewerChanges.subscribe { _ in handler() }
        }
    }

    /// Runs `handler` with the profile switched to, on every later switch.
    public func onActiveProfileChange(
        _ handler: @escaping @MainActor (ProfileID) -> Void
    ) -> ViewerEventSubscription {
        activeProfileChanges.subscribe(handler)
    }
}

/// Handlers called on the main actor, synchronously, in the order they
/// subscribed: the transport of `ViewerEvents`, and of the other per-viewer
/// records' changes (`UnavailablePosts.onChange`).
///
/// A send delivers to the handlers subscribed when it starts: one that
/// subscribes during the delivery hears the next send, one cancelled during
/// it is not called if its turn has not come. A handler may send again; that
/// send is delivered in full before the outer one goes on.
@MainActor
public final class OrderedHandlers<Payload> {
    private let registry = HandlerRegistry<Payload>()

    nonisolated public init() {}

    #if DEBUG
    /// How many subscriptions are live.
    public var debugObservationCount: Int { registry.count }
    #endif

    /// Calls every subscribed handler with `payload`, in order.
    public func send(_ payload: Payload) {
        for id in registry.ids() {
            // Read at its turn: cancelled meanwhile, it is skipped.
            registry.handler(for: id)?(payload)
        }
    }

    /// Calls `handler` on every later send until the subscription is
    /// cancelled or freed.
    public func subscribe(_ handler: @escaping @MainActor (Payload) -> Void) -> ViewerEventSubscription {
        let id = registry.add(handler)
        return ViewerEventSubscription { [weak registry] in registry?.remove(id) }
    }
}

/// The handlers of one `OrderedHandlers`, keyed by an increasing id, so the
/// ids in order are the subscription order. Locked, so a subscription can be
/// cancelled from any thread — a nonisolated `deinit`, usually — while
/// delivery reads it on the main actor.
private final class HandlerRegistry<Payload>: @unchecked Sendable {
    typealias Handler = @MainActor (Payload) -> Void
    private let lock = NSLock()
    private var lastID = 0
    private var handlers: [Int: Handler] = [:]

    var count: Int { lock.withLock { handlers.count } }

    func add(_ handler: @escaping Handler) -> Int {
        lock.withLock {
            lastID += 1
            handlers[lastID] = handler
            return lastID
        }
    }

    func remove(_ id: Int) {
        // Released after the lock: what the handler captured may go with it,
        // and cancel another subscription of this registry as it goes.
        let removed = lock.withLock { handlers.removeValue(forKey: id) }
        withExtendedLifetime(removed) {}
    }

    func ids() -> [Int] {
        lock.withLock { handlers.keys.sorted() }
    }

    func handler(for id: Int) -> Handler? {
        lock.withLock { handlers[id] }
    }
}

/// What `ViewerEvents` and `OrderedHandlers` return: the handler is called as
/// long as this lives, or until `cancel()`.
public final class ViewerEventSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    fileprivate init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    /// Stops the handler. Safe to call more than once, from any thread.
    public func cancel() {
        let onCancel: (@Sendable () -> Void)? = lock.withLock {
            defer { self.onCancel = nil }
            return self.onCancel
        }
        onCancel?()
    }

    deinit {
        cancel()
    }
}
