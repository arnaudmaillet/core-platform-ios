import ChatInterface
import CoreModels
import CoreNavigation
import MediaCore
import UIKit

/// The chat feature's entry point, resolved by the composition root and
/// consumed through `ChatFeatureBuilding` by the app shell.
@MainActor
public struct ChatFeatureBuilder: ChatFeatureBuilding {
    private let repository: any ChatProviding
    private let connections: (any SuggestionsProviding & PeerRelationProviding)?
    /// The compose picker's search backing. Optional like `connections`: a
    /// composition without it still opens the picker, which then browses
    /// recents and suggestions and simply finds nothing when typed into.
    private let people: (any PeopleDirectoryProviding)?
    private let imagePipeline: ImagePipeline?
    private let router: (any Router)?
    /// Shared list→thread warm-start context (the builder is a long-lived
    /// singleton in the container, so this is one directory app-wide).
    private let directory: ConversationDirectory
    /// The inbox's store, owned here rather than per-inbox so that a thread
    /// pushed later — built by an entirely separate call — can report back
    /// into the same one. Without that, reading a thread has no way to reach
    /// the list it should disappear from.
    private let catalog: InboxCatalog

    public init(
        repository: any ChatProviding,
        connections: (any SuggestionsProviding & PeerRelationProviding)? = nil,
        people: (any PeopleDirectoryProviding)? = nil,
        imagePipeline: ImagePipeline? = nil,
        router: (any Router)? = nil
    ) {
        let directory = ConversationDirectory()
        self.directory = directory
        catalog = InboxCatalog(repository: repository, relations: connections, directory: directory)
        self.repository = repository
        self.connections = connections
        self.people = people
        self.imagePipeline = imagePipeline
        self.router = router
    }

    /// Assembles the inbox: one catalog shared by the two conversation-backed
    /// surfaces (so the inbox loads once, not once per tab), an independent
    /// suggestions surface, and the container that pages between them.
    public func makeInboxViewController(initialCategory: MessagesCategory) -> UIViewController {
        let conversations = ConversationListViewController(
            viewModel: ConversationListViewModel(catalog: catalog, router: router)
        )
        // Context-menu previews show the real thread screen in `.preview`
        // mode: same transcript construction as the router's `.conversation`
        // push, minus the compose bar (typing is impossible in a peek).
        conversations.threadPreviewProvider = { [repository, directory, router] id in
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

        let requests = MessageRequestsViewController(
            viewModel: MessageRequestsViewModel(catalog: catalog, router: router)
        )
        let suggestions = SuggestionsViewController(
            viewModel: SuggestionsViewModel(
                repository: connections ?? EmptySuggestionsRepository(),
                router: router
            ),
            imagePipeline: imagePipeline
        )

        let inbox = MessagesInboxViewController(
            surfaces: [conversations, requests, suggestions],
            initialCategory: initialCategory
        )
        inbox.onCompose = { [router] in router?.route(to: .newMessage) }
        return inbox
    }

    public func makeConversationViewController(for conversationID: ConversationID) -> UIViewController {
        makeConversationViewController(target: .existing(conversationID))
    }

    private func makeConversationViewController(target: ConversationTarget) -> UIViewController {
        let viewModel = ConversationViewModel(
            target: target,
            repository: repository,
            directory: directory,
            router: router
        )
        // Reading a thread is an inbox event, not just a thread event: the row
        // has to leave Unread. Applied immediately — before the server write —
        // so the list underneath is already correct during the back swipe,
        // with a rollback if the write turns out to fail.
        viewModel.onDidMarkRead = { [catalog] id in catalog.markRead(id) }
        viewModel.onMarkReadDidFail = { [catalog] id in catalog.markReadDidFail(id) }
        // Sending changes the row's preview, time and position — all of which
        // the list underneath has to show before the viewer swipes back to it.
        viewModel.onDidSendMessage = { [catalog] id, message in
            catalog.recordSentMessage(message, in: id)
        }
        // A draft that just became real: the inbox has never heard of it, so
        // the viewer would otherwise swipe back from a thread they started to
        // a list without it.
        viewModel.onDidResolveConversation = { [catalog] _ in catalog.refresh() }
        return ConversationViewController(viewModel: viewModel)
    }

    /// A thread with `profileID`, opened before anyone knows whether one
    /// exists. Synchronous by design — see `ConversationTarget.draft`.
    public func makeDraftConversationViewController(
        with profileID: ProfileID,
        displayName: String
    ) -> UIViewController {
        makeConversationViewController(target: .draft(peer: profileID, displayName: displayName))
    }

    /// Suggestions per page. `-new-message-page-size <n>` shrinks it in DEBUG:
    /// the mock social graph yields only a handful of candidates, so at the
    /// shipping page size the first page is also the last and the pagination
    /// path is unreachable in the simulator.
    private static var suggestionPageSize: Int {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-new-message-page-size"),
           index + 1 < arguments.count,
           let size = Int(arguments[index + 1]), size > 0 {
            return size
        }
        #endif
        return 20
    }

    /// The compose picker, pushed onto whatever stack it was opened from.
    public func makeNewMessageViewController() -> UIViewController {
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            suggestions: connections,
            people: people,
            suggestionPageSize: Self.suggestionPageSize
        )
        let picker = NewMessageViewController(viewModel: viewModel)
        // A target, not a conversation: the pick is resolved and the push
        // begins in the same runloop turn, and whether the thread has to be
        // created is the thread's own problem once it is on screen.
        viewModel.onOpenConversation = { [router] target in
            switch target {
            case .existing(let conversationID):
                router?.route(to: .conversation(conversationID))
            case .draft(let peer, let displayName):
                router?.route(to: .messageUser(peer, stub: ProfileIdentityStub(
                    handle: "", displayName: displayName
                )))
            }
        }
        return picker
    }
}

/// Stands in when the app is composed without a social-graph client: the
/// surface renders its empty state rather than the feature failing to build.
private struct EmptySuggestionsRepository: SuggestionsProviding {
    func suggestions(limit: Int) async throws -> [SuggestedAccount] { [] }
    func follow(_ profileID: ProfileID) async throws {}
    func unfollow(_ profileID: ProfileID) async throws {}
}
