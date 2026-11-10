import CoreModels
import Foundation

/// A channel a profile owns, as the repository reads it (#2232): its id
/// and its identity for the viewer.
public struct OwnedChannel: Equatable, Sendable {
    public let id: ConversationID
    public let identity: ConversationIdentity

    public init(id: ConversationID, identity: ConversationIdentity) {
        self.id = id
        self.identity = identity
    }
}

/// The read behind a profile's Channels tab (#2232), on the shape
/// core-platform-backend#995 describes (`ProposedChat.ownedChannels`) until
/// its contract lands.
public protocol ProfileChannelsReading: Sendable {
    /// The channels `owner` owns that the viewer may see: someone else's
    /// public and on-request ones, every one of the viewer's own.
    func ownedChannels(of owner: ProfileID) async throws -> [OwnedChannel]
}

/// A profile's channels for its Channels tab (#2232), over Chat's
/// repository: Profile lists them through `ProfileChannelsProviding` and
/// can't depend on Chat, which owns the conversations.
///
/// Each row is a showcase card's channel (`ChannelEmbed`) — the same words
/// for the viewer's standing, so the row's Join / Request / Requested / Open
/// is the card's (`ChannelEmbedActions`) — plus whether it is private, which
/// only the owner's own profile ever receives.
@MainActor
final class ProfileChannels: ProfileChannelsProviding {
    private let service: any ProfileChannelsReading

    init(service: any ProfileChannelsReading) {
        self.service = service
    }

    func channels(ownedBy owner: ProfileID) async throws -> [ProfileChannel] {
        try await service.ownedChannels(of: owner).map(Self.profileChannel)
    }

    /// A read channel as the profile's row shows it. Pure, for tests.
    nonisolated static func profileChannel(_ owned: OwnedChannel) -> ProfileChannel {
        let identity = owned.identity
        let visibility: ChannelEmbed.Visibility = identity.visibility == .public ? .public : .onRequest
        let channel = ChannelEmbed(
            conversationID: owned.id,
            name: identity.name,
            photoURL: identity.photoURL,
            description: identity.description,
            subscriberCount: identity.subscriberCount,
            visibility: visibility,
            viewerState: ChannelEmbedActions.embedState(identity.viewerState)
        )
        return ProfileChannel(channel: channel, isPrivate: identity.visibility == .private)
    }
}
