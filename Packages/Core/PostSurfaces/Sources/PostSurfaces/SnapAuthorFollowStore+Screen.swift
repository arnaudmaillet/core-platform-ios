import CoreModels
import CoreNavigation
import DesignSystem
import UIKit

/// The shared follow as a SCREEN does it (#2419, #2409): the member gate
/// first (a guest's sign-in prompt), the store's optimistic change, the
/// haptic, and a refusal put back and said from the screen `source` is on.
/// One implementation for a list row's Follow (`PostAuthorMarks`) and the
/// full-screen page's (`SnapAuthorBar`).
extension SnapAuthorFollowStore {
    /// Follow, or Follow back.
    public func follow(_ author: ProfileID, handle: String?, name: String?, from source: UIResponder) {
        MemberGates.perform(.follow(handle: handle), from: source) { [weak self, weak source] in
            guard let self else { return }
            let followed = follow(author) { [weak source] in
                Self.say(PlusFollow.failureMessage(handle: handle, name: name), from: source)
            }
            // Turned on at the optimistic flip (#1885).
            if followed { Haptics.play(.toggleOn) }
        }
    }

    /// Requested's "Cancel Request": the pending request withdrawn.
    public func cancelRequest(to author: ProfileID, handle: String?, from source: UIResponder) {
        cancelRequest(to: author) { [weak source] in
            let who = handle.map { $0.isEmpty ? "" : " to @" + $0 } ?? ""
            Self.say("Couldn't cancel your request" + who, from: source)
        }
    }

    /// The share sheet's Unfollow (#2409). Silent, as every toggle turning
    /// off is (`Haptics.toggleOn`).
    public func unfollow(_ author: ProfileID, handle: String?, from source: UIResponder) {
        unfollow(author) { [weak source] in
            let who = handle.map { $0.isEmpty ? "" : " @" + $0 } ?? ""
            Self.say("Couldn't unfollow" + who, from: source)
        }
    }

    private static func say(_ failure: String, from source: UIResponder?) {
        guard let screen = source?.firstController(as: UIViewController.self) else { return }
        Feedback.failure(failure, from: screen)
    }
}
