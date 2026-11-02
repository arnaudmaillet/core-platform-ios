import CoreModels
import DesignSystem
import Foundation

/// THE "+"'s FOLLOW, one for every surface that offers it on a face (#2049):
/// the conversation's peer pill (#752) and the Messages inbox's rows. Moved
/// here from the thread rather than copied, so the two cannot drift.
///
/// The caller has already gone through the member gate (`MemberGates`) and
/// checked that its "+" was showing. Then:
/// 1. the relation flips to followed at once — `settingFollow(true)`, so a
///    follower followed back is a friend — with the follow haptic (#1886);
/// 2. the graph is asked;
/// 3. its answer lands: `.requested` for a private person (the clock,
///    #968), the relation before the tap on a failure, which the caller
///    says (`failureMessage`).
@MainActor
public enum PlusFollow {
    /// Follows `id` from `before`. `apply` draws each relation the follow
    /// passes through; `completion` is told once the graph has answered,
    /// with whether it failed.
    public static func commit(
        _ id: ProfileID,
        from before: FollowRelation,
        through writer: any SocialGraphWriting,
        apply: @escaping @MainActor (FollowRelation) -> Void,
        completion: @escaping @MainActor (_ failed: Bool) -> Void = { _ in }
    ) {
        apply(before.settingFollow(true))
        // On at the optimistic flip (#1886).
        Haptics.play(.toggleOn)
        Task { @MainActor in
            let outcome = try? await writer.follow(id)
            switch outcome {
            // A private person was asked, not followed: the followed mark
            // becomes the pending one.
            case .requested: apply(.requested)
            case .following: break
            case nil: apply(before)
            }
            completion(outcome == nil)
        }
    }

    /// What a failed "+" says (#802): a "+" that comes back without a word
    /// reads as a glitch. The handle when there is one, else the name.
    public static func failureMessage(handle: String?, name: String?) -> String {
        if let handle, !handle.isEmpty { return "Couldn't follow @" + handle }
        if let name, !name.isEmpty { return "Couldn't follow " + name }
        return "Couldn't follow"
    }
}
