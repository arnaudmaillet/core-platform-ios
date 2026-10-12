import Foundation

/// A follow or an unfollow the social graph ACCEPTED on the viewer's behalf.
public struct FollowChange: Equatable, Sendable {
    public let profileID: ProfileID
    public let isFollowing: Bool
    /// The profile that follows or unfollows: the viewer the request was made
    /// AS (its `actor_id`), captured before the network round trip (#978).
    /// Nil for a change a surface folds in locally, never published.
    public let viewerID: ProfileID?

    public init(profileID: ProfileID, isFollowing: Bool, viewerID: ProfileID? = nil) {
        self.profileID = profileID
        self.isFollowing = isFollowing
        self.viewerID = viewerID
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
///
/// ⚠️ A CHANGE IS ONE VIEWER'S (#978). A follow sent as profile A can be
/// accepted after the viewer switched to B; folded in, it would put A's edge
/// in B's follow set. Every published change carries the viewer it was made
/// as, and the channel delivers it only while that viewer is still the one
/// using the app (`currentViewer`), checked again on the main actor for
/// `subscribeOnMain`. A change with no viewer, or a channel told of none,
/// goes through.
public final class FollowGraphEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (FollowChange) -> Void] = [:]
    private let currentViewer: (@Sendable () -> ProfileID?)?

    /// - Parameter currentViewer: the active profile, asked on every delivery
    ///   from any thread (the app maps `StorageScope.shared.owner`). Must be
    ///   cheap. Nil (tests): every change is delivered.
    public init(currentViewer: (@Sendable () -> ProfileID?)? = nil) {
        self.currentViewer = currentViewer
    }

    /// Announces an ACCEPTED change. Call it after the graph said yes, never
    /// optimistically: an optimistic surface already shows its own guess, and
    /// every other one must only ever hear the truth. A change made as a
    /// viewer who has since left reaches nobody.
    public func publish(_ change: FollowChange) {
        guard isForCurrentViewer(change) else { return }
        let current = lock.withLock { Array(handlers.values) }
        for handler in current { handler(change) }
    }

    /// Whether `change` belongs to the viewer using the app now: made as them,
    /// or made as nobody in particular, or no viewer is known.
    public func isForCurrentViewer(_ change: FollowChange) -> Bool {
        guard let author = change.viewerID, let current = currentViewer?() else { return true }
        return author == current
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
        subscribe { [weak self] change in
            DispatchQueue.main.async {
                // The hop is a turn later: a switch may have landed in between.
                guard self?.isForCurrentViewer(change) ?? true else { return }
                MainActor.assumeIsolated { handler(change) }
            }
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
