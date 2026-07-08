import ChatInterface
import CoreModels
import CoreNavigation
import UIKit

/// The chat feature's entry point, resolved by the composition root and
/// consumed through `ChatFeatureBuilding` by the app shell.
@MainActor
public struct ChatFeatureBuilder: ChatFeatureBuilding {
    private let repository: any ChatProviding
    private let router: (any Router)?

    public init(repository: any ChatProviding, router: (any Router)? = nil) {
        self.repository = repository
        self.router = router
    }

    public func makeConversationListViewController() -> UIViewController {
        ConversationListViewController(
            viewModel: ConversationListViewModel(repository: repository, router: router)
        )
    }

    public func makeConversationViewController(for conversationID: ConversationID) -> UIViewController {
        ConversationViewController(
            viewModel: ConversationViewModel(conversationID: conversationID, repository: repository)
        )
    }

    public func makeDirectMessageViewController(with profileID: ProfileID) async -> UIViewController? {
        guard let conversationID = try? await repository.directConversation(with: profileID) else { return nil }
        return makeConversationViewController(for: conversationID)
    }
}
