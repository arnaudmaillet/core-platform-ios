import CoreModels
import UIKit

/// Entry point contract for the Chat feature. The app shell depends on this
/// interface package — never on the Chat implementation.
@MainActor
public protocol ChatFeatureBuilding {
    /// The viewer's conversation list. Selecting a conversation routes to it.
    func makeConversationListViewController() -> UIViewController
    /// A single conversation thread — the destination the router pushes for a
    /// `.conversation` route.
    func makeConversationViewController(for conversationID: ConversationID) -> UIViewController
}
