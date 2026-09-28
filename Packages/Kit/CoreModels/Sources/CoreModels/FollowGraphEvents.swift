import Foundation

/// A follow or an unfollow the social graph ACCEPTED on the viewer's behalf.
public struct FollowChange: Equatable, Sendable {
    public let profileID: ProfileID
    public let isFollowing: Bool

    public init(profileID: ProfileID, isFollowing: Bool) {
        self.profileID = profileID
        self.isFollowing = isFollowing
    }
}

/// Where the viewer's follow edges are announced once they change, so every
/// surface holding an answer about one person can keep it.
///
/// ⚠️ WHY A CHANNEL AND NOT A RE-READ ON APPEARANCE. The viewer's relationship
/// to one person is shown in many places at once — a profile's Follow button,
/// the rows of a followers list, a feed's author "+" — and written from as many
/// (`ProfileRepository`, `ProfileRelationshipsRepository`,
/// `SocialConnectionsRepository`). A re-read on appearance fixes only the
/// screen that happens to re-appear, costs a round trip every time, and misses
/// a change made while a screen stays visible (a sheet over it). And two of the
/// writers keep a SESSION cache of the viewer's follow set, which no screen's
/// appearance ever refreshes. The writes are the facts; so the WRITERS publish,
/// once the graph has accepted, and whoever holds an answer folds the change in.
///
/// One instance per app, built by the composition root and handed to every
/// writer and reader — the `ComposedPostChannel` shape: features share it
/// through CoreModels without importing each other, and a test builds its own,
/// so parallel tests never hear each other's follows.
public final class FollowGraphEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (FollowChange) -> Void] = [:]

    public init() {}

    /// Announces an ACCEPTED change. Call it after the graph said yes, never
    /// optimistically: an optimistic surface already shows its own guess, and
    /// every other one must only ever hear the truth.
    public func publish(_ change: FollowChange) {
        let current = lock.withLock { Array(handlers.values) }
        for handler in current { handler(change) }
    }

    /// Hears every change, on the PUBLISHER's executor — for an actor that
    /// hops on its own. Held by the returned subscription: release it and the
    /// handler is gone.
    public func subscribe(_ handler: @escaping @Sendable (FollowChange) -> Void) -> FollowGraphSubscription {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return FollowGraphSubscription { [weak self] in
            guard let self else { return }
            _ = self.lock.withLock { self.handlers.removeValue(forKey: id) }
        }
    }

    /// Hears every change on the MAIN actor, in publication order — for a view
    /// model or a screen.
    public func subscribeOnMain(
        _ handler: @escaping @MainActor @Sendable (FollowChange) -> Void
    ) -> FollowGraphSubscription {
        subscribe { change in
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(change) } }
        }
    }
}

/// Keeps a `FollowGraphEvents` handler registered for as long as it lives.
public final class FollowGraphSubscription: Sendable {
    private let cancel: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) {
        self.cancel = cancel
    }

    deinit { cancel() }
}
