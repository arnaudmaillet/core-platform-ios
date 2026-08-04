import CoreModels
import CoreNavigation
import UIKit

/// Entry point contract for the Chat feature. The app shell depends on this
/// interface package — never on the Chat implementation.
@MainActor
public protocol ChatFeatureBuilding {
    /// The Messages inbox: the paged All / Requests / Suggestions container,
    /// opened on `initialCategory`. Selecting a conversation routes to it.
    /// `onUnreadCountChange` reports every tab's badge added together, for the
    /// shell's own bar item. It fires whenever any of them changes — including
    /// while the inbox is off screen, which is the case the bar item is for.
    func makeInboxViewController(
        initialCategory: MessagesCategory,
        onUnreadCountChange: ((Int) -> Void)?
    ) -> UIViewController
    /// A single conversation thread — the destination the router pushes for a
    /// `.conversation` route.
    func makeConversationViewController(for conversationID: ConversationID) -> UIViewController

    /// A DM thread with `profileID`, opened *before* it is known whether a
    /// conversation exists — the thread finds or creates one underneath itself
    /// once on screen. Synchronous on purpose: finding out first costs a
    /// `ListSubscriptions` plus a `ListMembers` per conversation, which is far
    /// more than a tap can spend before something appears. `displayName` is
    /// whatever the origin already knew; empty is allowed, and the header then
    /// fills in once there is a conversation to read it from.
    /// `prefill` seeds the composer — the profile share sheet sends a link
    /// this way. Never auto-sent; the viewer still taps Send.
    func makeDraftConversationViewController(
        with profileID: ProfileID,
        displayName: String,
        prefill: String
    ) -> UIViewController

    /// The compose flow — pick someone, land in a thread with them. Pushed
    /// onto the caller's stack like any other destination; picking a row emits
    /// a route, so the caller arranges nothing.
    func makeNewMessageViewController() -> UIViewController
}

extension ChatFeatureBuilding {
    /// The ordinary case: a thread with an empty composer.
    public func makeDraftConversationViewController(
        with profileID: ProfileID,
        displayName: String
    ) -> UIViewController {
        makeDraftConversationViewController(with: profileID, displayName: displayName, prefill: "")
    }

    /// The plain "open Messages" case.
    public func makeInboxViewController() -> UIViewController {
        makeInboxViewController(initialCategory: .all, onUnreadCountChange: nil)
    }

    public func makeInboxViewController(initialCategory: MessagesCategory) -> UIViewController {
        makeInboxViewController(initialCategory: initialCategory, onUnreadCountChange: nil)
    }

    public func makeInboxViewController(onUnreadCountChange: @escaping (Int) -> Void) -> UIViewController {
        makeInboxViewController(initialCategory: .all, onUnreadCountChange: onUnreadCountChange)
    }
}

/// The inbox's paging seam, exposed to the shell so a `.messages(...)` route
/// arriving at an inbox that is ALREADY on screen pages it to the requested
/// category instead of rebuilding the tab root under the user.
@MainActor
public protocol MessagesInboxCategorySelecting: UIViewController {
    func setCategory(_ category: MessagesCategory, animated: Bool)
}
