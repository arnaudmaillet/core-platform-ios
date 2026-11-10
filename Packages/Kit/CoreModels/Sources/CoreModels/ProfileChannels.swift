import Foundation

/// One channel a profile owns, as its Channels tab lists it (#2232).
///
/// A channel is its owner's broadcast, attached to their profile (#2211's
/// reframing, the owner 2026-11-10) — so the profile lists the ones it owns.
/// The row says what a showcase's card says (`ChannelEmbed`: the identity,
/// the count, who may join, where the viewer stands), and one thing a card
/// never has to: that a channel is private. A card can't show a private
/// channel to an outsider at all; the profile shows its owner their own,
/// with a lock.
public struct ProfileChannel: Sendable, Equatable, Hashable, Identifiable {
    public var channel: ChannelEmbed
    /// Members only (chat.v1's `private`): listed on the owner's own profile
    /// alone, with a lock — never on anyone else's, where it can't be probed.
    public var isPrivate: Bool

    public var id: ConversationID { channel.conversationID }

    public init(channel: ChannelEmbed, isPrivate: Bool = false) {
        self.channel = channel
        self.isPrivate = isPrivate
    }
}

/// The channels a profile owns, behind a seam (#2232): the profile lists
/// them and can't depend on Chat, which owns the conversations. Chat
/// implements it over its repository; the app hands it to Profile.
///
/// The row's Join / Request / cancel / Open are the showcase card's
/// (`ChannelEmbedActing`), so the two surfaces act alike.
@MainActor
public protocol ProfileChannelsProviding: AnyObject {
    /// The channels `owner` owns that the viewer may see (core-platform-
    /// backend#995): on someone else's profile, the public ones and those on
    /// request; on the viewer's own, every one, the private ones included.
    /// Only the ones `owner` OWNS — a channel they admin stays off their
    /// profile, and one handed over moves to its new owner's.
    func channels(ownedBy owner: ProfileID) async throws -> [ProfileChannel]
}
