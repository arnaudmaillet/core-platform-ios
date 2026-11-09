import Foundation

/// What a TEXT post refers to and shows as a live card (#2211, #2216): a
/// closed union, one case per referenced entity — `channel` now; a group, a
/// place, a quoted post later, each added as a case here and a case in the
/// card (Bluesky's `embed` union; Telegram's link preview with an action).
///
/// - **A property of a text post, not a kind** (the owner's decision in
///   #2211, as a voice is in #2204): the post stays a text post on every
///   surface; only the caption's place becomes the embed card.
/// - ⚠️ **Never in `attachments`:** every `attachments.isEmpty` test would
///   read the post as media.
/// - ⚠️ **Never `audio_ref`:** that is the reusable sound.
/// - **Hydrated with the post** (core-platform-backend#995): the feed, map
///   and search responses carry the referenced entity already read for the
///   viewer, so a surface makes no request per card.
public enum PostEmbed: Sendable, Equatable, Hashable, Codable {
    /// A channel's showcase (#2216): the card shows the channel and the
    /// viewer's action — Join, Request to join, Requested, Open.
    case channel(ChannelEmbed)

    /// The channel this embed shows, if it is one.
    public var channel: ChannelEmbed? {
        switch self {
        case .channel(let channel): channel
        }
    }
}

/// A channel as a showcase post's card shows it (#2216): the conversation
/// it references, read live for the viewer — its identity, its count, who
/// may join and where the viewer stands.
///
/// It mirrors what chat.v1 / `ProposedChat` say about a conversation, in the
/// few words a card needs; Feed, Maps and PostGrid read it without knowing
/// Chat.
public struct ChannelEmbed: Sendable, Equatable, Hashable, Codable {
    /// Who may join (`ProposedChat.Visibility`, less `private`, which a card
    /// shows as an availability — a private channel can't be probed).
    public enum Visibility: String, Sendable, Codable, CaseIterable {
        /// Anyone joins at once.
        case `public`
        /// Shown on its showcases; joining waits for an admin (#995's
        /// "listed on request").
        case onRequest
    }

    /// Where the viewer stands. An owner and an admin are members: the card
    /// offers them what it offers a member — Open.
    public enum ViewerState: String, Sendable, Codable, CaseIterable {
        case member
        case subscriber
        case requested
        case none
        case banned
    }

    /// Whether the channel can be shown (Bluesky's `viewNotFound` /
    /// `viewBlocked`): each unavailable state has its own drawing and no
    /// action.
    public enum Availability: String, Sendable, Codable, CaseIterable {
        case available
        /// It no longer exists: "This channel no longer exists".
        case deleted
        /// Turned private, or never listed: "This channel is private".
        case `private`
        /// A block either way stands between the viewer and the channel.
        case blocked
    }

    /// What the card's button does, from the viewer's state (#2216's table).
    public enum Action: String, Sendable, Equatable, CaseIterable {
        /// A public channel the viewer is not in: subscribes at once.
        case join
        /// A channel on request the viewer is not in: sends the request.
        case requestToJoin
        /// A request waits: a tap offers to cancel it.
        case requested
        /// The viewer is in: opens the channel in Messages.
        case open
    }

    public let conversationID: ConversationID
    public var name: String
    public var photoURL: URL?
    public var description: String
    public var subscriberCount: Int
    public var visibility: Visibility
    public var viewerState: ViewerState
    public var availability: Availability
    /// The first line of the channel's last message, when the backend gives
    /// it (#995): the full card's last line.
    public var lastMessagePreview: String?

    public init(
        conversationID: ConversationID, name: String = "", photoURL: URL? = nil, description: String = "",
        subscriberCount: Int = 0, visibility: Visibility = .public, viewerState: ViewerState = .none,
        availability: Availability = .available, lastMessagePreview: String? = nil
    ) {
        self.conversationID = conversationID
        self.name = name
        self.photoURL = photoURL
        self.description = description
        self.subscriberCount = subscriberCount
        self.visibility = visibility
        self.viewerState = viewerState
        self.availability = availability
        self.lastMessagePreview = lastMessagePreview.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The button the card shows — the ONE place the table of #2216 is
    /// written. Nil: no button (banned, or the channel can't be shown).
    public var action: Action? {
        guard availability == .available else { return nil }
        switch viewerState {
        case .member, .subscriber: return .open
        case .requested: return .requested
        case .banned: return nil
        case .none: return visibility == .public ? .join : .requestToJoin
        }
    }

    /// The same channel with the viewer standing at `state` — what a tap's
    /// answer puts on the card until the next read hydrates it again. A join
    /// counts the viewer in; leaving a channel counts them out.
    public func with(viewerState state: ViewerState) -> ChannelEmbed {
        var copy = self
        let wasIn = viewerState == .member || viewerState == .subscriber
        let isIn = state == .member || state == .subscriber
        if isIn, !wasIn { copy.subscriberCount += 1 }
        if wasIn, !isIn { copy.subscriberCount = max(0, copy.subscriberCount - 1) }
        copy.viewerState = state
        return copy
    }

    /// The name a card shows: its own, or "Channel" when the server sent
    /// none (a deleted channel's).
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Channel" : trimmed
    }
}

/// What a showcase card's button does (#2216), behind a seam: Feed, Maps and
/// PostGrid draw the card and cannot depend on Chat, which owns the
/// conversations. Chat implements it over its repository; the app registers
/// it once (`ChannelEmbedView.actions`).
///
/// Each write answers the viewer's new standing, which the card shows at
/// once.
@MainActor
public protocol ChannelEmbedActing: AnyObject {
    /// Subscribes to a public channel: `.subscriber` (or `.member`).
    func join(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState
    /// Asks to join a channel on request: `.requested` — or `.subscriber`
    /// when it turned public meanwhile.
    func requestToJoin(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState
    /// Takes a waiting request back: `.none`.
    func cancelJoinRequest(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState
    /// Opens the channel's conversation (`AppRoute.conversation`).
    func open(_ id: ConversationID)
}
