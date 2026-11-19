import Foundation

/// One store instance's changes, observed on that instance (#2376).
///
/// It replaces the raw `Notification.Name`s the stores used to post on
/// `NotificationCenter.default` (`wallet.didChange`, `storageScope.didChange`,
/// …): an observer reaches the changes through the instance it was handed,
/// so it can only hear that instance, and the payload is typed.
///
/// ⚠️ THE TRANSPORT IS STILL A `NotificationCenter`, a private one per
/// instance, so delivery is exactly what it was on `.default`:
/// - `observe(on: nil)`: the handler runs on the thread that called `send`,
///   before `send` returns;
/// - `observe(on: .main)` and `observeOnMain`: the handler runs on the main
///   queue, and `send` waits for it, from any thread.
/// Handlers run in registration order, as `NotificationCenter`'s do.
///
/// ⚠️ KEEP THE `StoreObservation`: it stops observing when it goes. An
/// observer that drops it stops hearing at once, and nothing visibly fails.
/// Hold it for as long as the old token or selector registration lived: on
/// the object that observes, usually.
public final class StoreChanges<Payload: Sendable>: @unchecked Sendable {
    private let center = NotificationCenter()
    private let live = LiveObservations()

    public init() {}

    #if DEBUG
    /// How many observations are live: what a test reads to see that an
    /// observer kept its observation, and that it ended with the observer.
    public var debugObservationCount: Int { live.count }
    #endif

    /// Delivers `payload` to every observer, as described on the type.
    public func send(_ payload: Payload) {
        center.post(name: storeChangesName, object: nil, userInfo: [storeChangesPayloadKey: Box(payload)])
    }

    /// Observes every later `send` until the returned observation is
    /// cancelled or freed. `queue` nil: on the sender's thread.
    public func observe(
        on queue: OperationQueue? = nil,
        _ handler: @escaping @Sendable (Payload) -> Void
    ) -> StoreObservation {
        let token = center.addObserver(forName: storeChangesName, object: nil, queue: queue) { note in
            guard let box = note.userInfo?[storeChangesPayloadKey] as? Box else { return }
            handler(box.payload)
        }
        live.add(1)
        return StoreObservation(center: center, token: token) { [live] in live.add(-1) }
    }

    /// Observes on the main queue, the handler on the main actor: what
    /// `addObserver(…, queue: .main)` with `MainActor.assumeIsolated` did.
    public func observeOnMain(_ handler: @escaping @MainActor @Sendable (Payload) -> Void) -> StoreObservation {
        observe(on: .main) { payload in
            MainActor.assumeIsolated { handler(payload) }
        }
    }

    private final class Box: @unchecked Sendable {
        let payload: Payload
        init(_ payload: Payload) { self.payload = payload }
    }
}

public extension StoreChanges where Payload == Void {
    /// Delivers a change that carries nothing.
    func send() { send(()) }
}

private let storeChangesName = Notification.Name("StoreChanges.send")
private let storeChangesPayloadKey = "payload"

/// The live observations of one `StoreChanges`, counted.
private final class LiveObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add(_ delta: Int) { lock.withLock { value += delta } }
}

/// What `StoreChanges.observe` returns: the observation lasts as long as
/// this does, or until `cancel()`.
public final class StoreObservation: @unchecked Sendable {
    private typealias Registration = (
        center: NotificationCenter, token: any NSObjectProtocol, ended: @Sendable () -> Void
    )
    private let lock = NSLock()
    private var registration: Registration?

    fileprivate init(center: NotificationCenter, token: any NSObjectProtocol, ended: @escaping @Sendable () -> Void) {
        registration = (center, token, ended)
    }

    /// Stops observing. Safe to call more than once, from any thread.
    public func cancel() {
        let registration: Registration? = lock.withLock {
            defer { self.registration = nil }
            return self.registration
        }
        guard let registration else { return }
        registration.center.removeObserver(registration.token)
        registration.ended()
    }

    deinit {
        cancel()
    }
}
