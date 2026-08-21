import CoreModels
import Foundation

/// The viewer's followed AUTHORS, kept on the device.
///
/// ## Why the device and not the service
///
/// `social_graph.v1` has the write this wants, and the profile screen already
/// calls it. This grid cannot: `FeedFeatureBuilder` is constructed with a feed
/// repository, an engagement provider, comments, realtime and a wallet, and no
/// social graph — so following from a row would mean threading a new dependency
/// from the composition root through the builder, the tab, the pager and the
/// page before the button could do anything at all.
///
/// The app already has this exact shape once, for the same reason:
/// `MapPlaceFollowStore` keeps followed PLACES on the device because no
/// contract carries them. This is that store for authors, deliberately built to
/// the same pattern so the two can be replaced by one service call together
/// rather than each being discovered separately.
///
/// ⚠️ So a follow made here is REAL to this device and invisible to everyone
/// else. That is a smaller lie than a button that does nothing, and a much
/// smaller one than a button that pretends to reach the network.
public final class AuthorFollowStore: @unchecked Sendable {
    private static let key = "feed.followedAuthorIDs"

    /// Posted whenever the set changes, so surfaces showing the same author in
    /// two places do not disagree about it.
    public static let didChangeNotification = Notification.Name("feed.authorFollowsDidChange")

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // `-feed-reset-followed-authors`: deterministic QA — every scripted
        // launch starts unfollowed.
        if ProcessInfo.processInfo.arguments.contains("-feed-reset-followed-authors") {
            defaults.removeObject(forKey: Self.key)
        }
        // `-feed-follow-author <profileID>`: start with one author followed, so
        // a capture can land on the followed face without driving the button.
        let arguments = ProcessInfo.processInfo.arguments
        if let position = arguments.firstIndex(of: "-feed-follow-author"),
           position + 1 < arguments.count {
            var ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
            ids.insert(arguments[position + 1])
            defaults.set(Array(ids), forKey: Self.key)
        }
        #endif
    }

    public func isFollowing(_ id: ProfileID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Set(defaults.stringArray(forKey: Self.key) ?? []).contains(id.rawValue)
    }

    /// Flips the author's state and reports what it became, so a caller can
    /// render the answer without asking again.
    @discardableResult
    public func toggle(_ id: ProfileID) -> Bool {
        lock.lock()
        var ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
        let following = ids.contains(id.rawValue)
        if following {
            ids.remove(id.rawValue)
        } else {
            ids.insert(id.rawValue)
        }
        defaults.set(Array(ids), forKey: Self.key)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        return !following
    }
}
