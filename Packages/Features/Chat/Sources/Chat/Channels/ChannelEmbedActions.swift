import CoreModels
import CoreNavigation
import Foundation

/// What a channel showcase's card does (#2216), over the conversations Chat
/// owns: the card is drawn by PostGrid in the feed, on the map and on
/// profiles, none of which may depend on Chat (`ChannelEmbedActing`).
///
/// - **Join** a public channel subscribes (`subscribe(to:)`); **Request to
///   join** one on request asks (`requestToJoin`), and a channel that turned
///   public meanwhile subscribes at once; **Requested** offers the cancel.
/// - **The viewer's new standing is read back** (`details(of:)`) where the
///   write says nothing, so the card shows what the server holds.
/// - **The Channels tab follows:** a standing that changes reloads the
///   inbox's catalog, so a channel joined from the feed is in Messages'
///   Channels tab when the viewer gets there.
/// - **Open** routes to the conversation (`AppRoute.conversation`), the
///   path every other channel row takes.
@MainActor
final class ChannelEmbedActions: ChannelEmbedActing {
    private let service: any ConversationManaging
    private weak var router: (any Router)?
    /// The inbox's catalog reload: the Channels tab's rows.
    private let membershipDidChange: @MainActor () -> Void

    init(service: any ConversationManaging, router: (any Router)?, membershipDidChange: @escaping @MainActor () -> Void) {
        self.service = service
        self.router = router
        self.membershipDidChange = membershipDidChange
    }

    func join(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState {
        try await service.subscribe(to: id)
        membershipDidChange()
        let identity = try? await service.details(of: id)
        return identity.map { Self.embedState($0.viewerState) } ?? .subscriber
    }

    func requestToJoin(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState {
        let state = Self.embedState(try await service.requestToJoin(id))
        // A channel that turned public meanwhile lets the viewer in at once.
        if state == .subscriber || state == .member { membershipDidChange() }
        return state
    }

    func cancelJoinRequest(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState {
        try await service.cancelJoinRequest(id)
        return .none
    }

    func open(_ id: ConversationID) {
        router?.route(to: .conversation(id))
    }

    /// The card's words for a standing: an owner and an admin are members
    /// (Open); an invitation is no standing yet.
    nonisolated static func embedState(_ state: ConversationViewerState) -> ChannelEmbed.ViewerState {
        switch state {
        case .owner, .admin, .member: .member
        case .subscriber: .subscriber
        case .requested: .requested
        case .banned: .banned
        case .invited, .none: .none
        }
    }
}
