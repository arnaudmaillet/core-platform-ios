import CoreModels
import CoreNavigation
import UIKit

/// Entry point contract for the Chat feature. The app shell depends on this
/// interface package — never on the Chat implementation.
@MainActor
public protocol ChatFeatureBuilding {
    /// The Messages inbox: the paged All / Requests / Suggestions container,
    /// opened on `initialCategory`. Selecting a conversation routes to it.
    func makeInboxViewController(initialCategory: MessagesCategory) -> UIViewController
    /// A single conversation thread — the destination the router pushes for a
    /// `.conversation` route.
    func makeConversationViewController(for conversationID: ConversationID) -> UIViewController

    /// Opens (find-or-create) a DM thread with `profileID`. Async because it may
    /// create the conversation; `nil` if that fails.
    func makeDirectMessageViewController(with profileID: ProfileID) async -> UIViewController?
}

extension ChatFeatureBuilding {
    /// The plain "open Messages" case.
    public func makeInboxViewController() -> UIViewController {
        makeInboxViewController(initialCategory: .all)
    }
}

/// The inbox's paging seam, exposed to the shell so a `.messages(...)` route
/// arriving at an inbox that is ALREADY on screen pages it to the requested
/// category instead of rebuilding the tab root under the user.
@MainActor
public protocol MessagesInboxCategorySelecting: UIViewController {
    func setCategory(_ category: MessagesCategory, animated: Bool)
}
