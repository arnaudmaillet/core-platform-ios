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
    /// Shared list→thread warm-start context (the builder is a long-lived
    /// singleton in the container, so this is one directory app-wide).
    private let directory = ConversationDirectory()

    public init(repository: any ChatProviding, router: (any Router)? = nil) {
        self.repository = repository
        self.router = router
    }

    public func makeConversationListViewController() -> UIViewController {
        let controller = ConversationListViewController(
            viewModel: ConversationListViewModel(
                repository: repository, router: router, directory: directory
            )
        )
        // Context-menu previews show the real thread screen in `.preview`
        // mode: same transcript construction as the router's `.conversation`
        // push, minus the compose bar (typing is impossible in a peek).
        controller.threadPreviewProvider = { id in
            ConversationViewController(
                viewModel: ConversationViewModel(
                    conversationID: id,
                    repository: repository,
                    directory: directory,
                    router: router
                ),
                mode: .preview
            )
        }
        return controller
    }

    public func makeConversationViewController(for conversationID: ConversationID) -> UIViewController {
        ConversationViewController(
            viewModel: ConversationViewModel(
                conversationID: conversationID,
                repository: repository,
                directory: directory,
                router: router
            )
        )
    }

    public func makeDirectMessageViewController(with profileID: ProfileID) async -> UIViewController? {
        guard let conversationID = try? await repository.directConversation(with: profileID) else { return nil }
        return makeConversationViewController(for: conversationID)
    }
}
