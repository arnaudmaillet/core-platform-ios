import CoreContracts
import CoreModels
import Foundation

/// The follow requests the viewer is known to have pending, for as long as
/// the app runs — what `GetRelationStatus` cannot say on its own.
///
/// ⚠️ THE GRAPH HIDES A REQUEST TO SOMEONE WHO FOLLOWS THE VIEWER (#1670,
/// backend #972). Its status folds a pending request in only when neither
/// follows the other: a private person who already follows the viewer reads
/// `FOLLOWED_BY` with the request pending, and nothing else in the view says
/// so. Read as it comes, a request sent from a feed's "+" turned back into
/// "Follow" on the card opened next, and a second tap hit SGR-1005.
///
/// So the requests asked or heard of this session are kept here, per viewer:
/// `FOLLOWED_BY` with one of them known reads `REQUESTED`. Every other
/// status is the graph's answer about the request too — following (it was
/// approved), none (declined or withdrawn), a block (dropped) — and forgets
/// it; `REQUESTED` itself is learned. What this cannot know: a request from
/// an earlier session to someone who follows the viewer, or one declined
/// while they follow — the first reads "Follow" (a tap answers SGR-1005,
/// which is "Requested"), the second "Requested" until withdrawn.
final class PendingFollowRequests: @unchecked Sendable {
    private struct Key: Hashable {
        let viewer: ProfileID
        let target: ProfileID
    }

    private let lock = NSLock()
    private var pending: Set<Key> = []

    /// A request asked (`isPending`) or withdrawn, as the follow channel
    /// announces it. A change made as nobody in particular is not kept.
    func record(_ change: FollowRequestChange) {
        guard let viewer = change.viewerID else { return }
        record(change.isPending, viewer: viewer, target: change.profileID)
    }

    func record(_ isPending: Bool, viewer: ProfileID, target: ProfileID) {
        let key = Key(viewer: viewer, target: target)
        lock.withLock {
            if isPending { pending.insert(key) } else { pending.remove(key) }
        }
    }

    /// `status`, as read for `viewer` about `target`, with a request this
    /// session knows of put back in.
    func resolve(
        _ status: SocialGraph_V1_RelationStatus, viewer: ProfileID, target: ProfileID
    ) -> SocialGraph_V1_RelationStatus {
        let key = Key(viewer: viewer, target: target)
        return lock.withLock {
            switch status {
            case .followedBy:
                return pending.contains(key) ? .requested : status
            case .requested:
                pending.insert(key)
                return status
            default:
                pending.remove(key)
                return status
            }
        }
    }
}
