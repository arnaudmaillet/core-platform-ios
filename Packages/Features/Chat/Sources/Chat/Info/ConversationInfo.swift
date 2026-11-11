import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import Foundation
import HeroPage
import MediaCore

// A group's and a channel's info screens (#2237) read like a profile and a
// place: the hero header (`HeroHeaderView`), the lists behind its counters
// (`PersonListsViewController`), the bell and the "⋯" in the bar, the posts
// that showcase the conversation under it. What each screen shows is decided
// here, as plain values the view models fill from their rules and the tests
// read — the screens draw them.

/// A counter of the header, and the list it opens (#2237).
enum ConversationInfoList: String, CaseIterable, Sendable {
    case members
    case subscribers
    case admins
    case requests
    case followers

    /// The counters a kind's header holds, in order: a group's Members,
    /// Admins, Requests, Followers; a channel's Subscribers, Admins,
    /// Requests. A counter with no value is hidden, its cell left empty.
    static func counters(channel: Bool) -> [ConversationInfoList] {
        channel ? [.subscribers, .admins, .requests] : [.members, .admins, .requests, .followers]
    }

    /// The counter's caption.
    var caption: String {
        switch self {
        case .members: "Members"
        case .subscribers: "Subscribers"
        case .admins: "Admins"
        case .requests: "Requests"
        case .followers: "Followers"
        }
    }

    /// The pager's tab: its count and its name — "64 Subscribers".
    func tabTitle(count: Int) -> String {
        "\(CountFormatter.compactString(for: Int64(max(0, count)))) \(caption)"
    }

    /// What the tab says with nobody in it: never a header over nothing.
    func empty(channel: Bool) -> PersonListTab.Empty {
        switch self {
        case .members:
            PersonListTab.Empty(symbol: "person.2", title: "No members yet")
        case .subscribers:
            PersonListTab.Empty(symbol: "person.2", title: "No subscribers yet",
                                message: "Share the channel's link to bring people in.")
        case .admins:
            PersonListTab.Empty(symbol: "person.badge.shield.checkmark", title: "No admins",
                                message: channel ? "Admins post and answer join requests." : "Admins add and manage members.")
        case .requests:
            PersonListTab.Empty(symbol: "person.crop.circle.badge.questionmark", title: "No requests",
                                message: "When someone asks to join, they wait here.")
        case .followers:
            PersonListTab.Empty(symbol: "person.2", title: "No followers yet")
        }
    }

    /// The roles the list reads (`ListMembers`); nil for Requests, which
    /// are not members.
    var roles: Set<ConversationRole>? {
        switch self {
        case .members: [.owner, .admin, .member]
        case .subscribers, .followers: [.subscriber]
        case .admins: [.owner, .admin]
        case .requests: nil
        }
    }
}

/// A view of the header's action row (#2237).
enum ConversationInfoAction: Equatable, Sendable {
    /// Owner and admins: the editing sheet (photo, name, description).
    case edit
    /// A group's owner and admins.
    case addMembers
    /// A channel's owner and admins: its link, through the share sheet.
    case invite
    /// An outsider of a public group or channel; a group's follower.
    case join
    /// An outsider of a public group with room or not.
    case follow
    /// An outsider of a channel on request.
    case requestToJoin
    /// The viewer asked: a tap takes it back.
    case requested
    /// The bubble: the link, through the share sheet.
    case share

    var title: String {
        switch self {
        case .edit: "Edit"
        case .addMembers: "Add Members"
        case .invite: "Invite"
        case .join: "Join"
        case .follow: "Follow"
        case .requestToJoin: "Request to Join"
        case .requested: "Requested"
        case .share: "Share"
        }
    }

    /// The bubble's glyph.
    static let shareSymbol = "square.and.arrow.up"
}

/// What a group's or a channel's header shows (#2237), for the viewer it
/// is shown to — `HeroHeaderContent` and the header's counters and action
/// row, as values.
struct ConversationInfoHeader: Equatable, Sendable {
    var title: String
    /// A channel's megaphone after its name (#2230).
    var titleSymbol: String?
    var subtitle: String
    /// The subtitle names the owner ("by @owner"): a tap opens them.
    var subtitleOwner: ProfileID?
    var bio: String?
    var linkText: String?
    var linkURL: URL?
    var photoURL: URL?
    var monogram: String
    /// Each counter's figure; a counter missing here is hidden.
    var counters: [ConversationInfoList: Int]
    /// The counters a tap opens: the lists the viewer may read.
    var openable: Set<ConversationInfoList>
    /// The capsules, leading; they share what the bubbles leave.
    var capsules: [ConversationInfoAction]
    var bubbles: [ConversationInfoAction]
    /// A group's picture (#2233): its photo, else its members' faces, else
    /// its initials — drawn in the header's disc in place of the person's
    /// avatar. Nil for a channel.
    var groupAvatar: GroupAvatarContent? = nil

    /// The figures in `captions`' order, compact ("12.4K"), nil where hidden.
    func counterValues(_ captions: [ConversationInfoList]) -> [String?] {
        captions.map { list in counters[list].map { CountFormatter.compactString(for: Int64(max(0, $0))) } }
    }

    /// A channel's mark after its name: the megaphone its row wears
    /// (`ConversationRowView.channelBadgeSymbol`, #2230).
    static let channelSymbol = "megaphone.fill"

    /// The link's words: its host and path, no scheme.
    static func linkText(_ url: URL?) -> String? {
        guard let url, let host = url.host() else { return nil }
        return host + url.path()
    }
}

/// An entry of the bar's "⋯" (#2237): the rest of what the old grouped
/// list offered, Leave last in red (#2236's convention).
enum ConversationInfoMenuEntry: Equatable, Sendable {
    /// A channel's owner and admins (#2216).
    case shareAsPost
    /// Owner and admins: Public / Private, Public / On request.
    case visibility
    /// The owner: the lists, on the tab whose rows offer "Make Owner".
    case transferOwnership
    /// A group's follower (#2217).
    case unfollow
    /// Anyone in but the owner, who hands over first.
    case leave
}

/// The Posts page under the header (#2237): the text posts that showcase
/// the conversation (#2216's embed). Until those are served for a
/// conversation, the page's empty state — which, for owner and admins of a
/// channel, offers to make the first. A group has no showcase yet (#2216
/// embeds channels only): "No posts yet" for everyone.
enum ConversationInfoPosts {
    static func status(channel: Bool, manages: Bool, canShareAsPost: Bool) -> PostGridPageStatus {
        guard manages, channel else {
            return PostGridPageStatus(
                symbolName: "text.bubble", title: "No posts yet",
                subtitle: channel ? "Posts that show this channel appear here." : "Posts that show this group appear here."
            )
        }
        return PostGridPageStatus(
            symbolName: ChannelShowcase.shareSymbol, title: ChannelShowcase.shareTitle,
            subtitle: "Share the channel as a post: it shows here, and on the feed and the map.",
            actionTitle: canShareAsPost ? ChannelShowcase.shareTitle : nil
        )
    }
}

/// The page under the header: one, Posts (Media for a group, later).
enum ConversationInfoTab: Equatable, Sendable {
    case posts
}
