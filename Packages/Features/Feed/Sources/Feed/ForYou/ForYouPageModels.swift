import CoreModels
import Foundation
import PostGrid

// What For You publishes, as values (#2379, stage A1): its page states, the
// stories row and the snapshot. Top-level, not nested in `ForYouViewModel`,
// so the post surfaces that draw them can leave Feed without taking the view
// model along. `ForYouViewModel` keeps its nested names as aliases.

public nonisolated enum ForYouPageState: Equatable, Sendable {
    case loading
    case content([GalleryPost])
    /// The combination has nothing to show, said in two parts so the page
    /// reads intentional rather than broken.
    case empty(ForYouEmptyState)
    case failed(message: String)
}

/// An empty page, in the two pieces the viewer needs separately.
///
/// The split is not cosmetic. The TITLE is the finding — "No activity yet"
/// — and is true regardless of how the viewer got here. The SUBTITLE is the
/// reason the page might be narrower than they expected, and it is the only
/// part that tells them there is something they can change. Running them
/// into one sentence made the actionable half look like punctuation.
public nonisolated struct ForYouEmptyState: Equatable, Sendable {
    public let title: String
    /// Absent when nothing is narrowing the page — an unfiltered surface
    /// with no content has no explanation to offer, and inventing one would
    /// be noise.
    public let subtitle: String?

    public init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }
}

/// One friend in the stories row.
public nonisolated struct ForYouFriendStory: Equatable, Sendable {
    public let authorID: ProfileID
    public let name: String
    public let handle: String
    public let avatarURL: URL?
    /// What a tap opens, newest first: the friend's UNSEEN posts when
    /// there are any — "only those of the selected friend" — and their
    /// recent ones otherwise, so a friend with nothing new still opens
    /// onto something.
    public let posts: [GalleryPost]
    /// Whether any of `posts` is new to the viewer — what the ring says.
    public let hasUnseen: Bool
}

/// The two rows that lead the list, and the counts on their headers.
public nonisolated struct ForYouRails: Equatable, Sendable {
    /// Every friend with something loaded, those with unseen posts first.
    public var friends: [ForYouFriendStory] = []
    /// The people the viewer follows who are NOT friends: their posts,
    /// unseen first, as cards.
    public var following: [GalleryPost] = []
    /// The pushed Following list holds more than the rows show: a row cut
    /// at its limit, or a timeline page not loaded yet — the rows then
    /// end on "View all" (the shelf contract, #1671).
    public var followingHasMore = false
    /// The Friends header's count: friends' posts the viewer has not seen.
    public var friendsBadge = 0
    /// The Following header's count: arrivals since the session baseline —
    /// the number the Following TAB's badge used to be.
    public var followingBadge = 0

    public init() {}
}

public nonisolated struct ForYouSnapshot: Equatable, Sendable {
    /// Discover's list: the DISCOVERY corpus — every author, every kind,
    /// in ranked order — from which the list decides for itself which
    /// posts become mosaic tiles (`MosaicChunkPlanner`).
    public var discover: ForYouPageState = .loading
    /// Discover narrowed to media: the pushed "View all" mosaic.
    public var media: ForYouPageState = .loading
    /// The pushed FOLLOWING list: the people the viewer follows who are
    /// not friends — one plain run of posts, no sections.
    public var following: ForYouPageState = .loading
    /// The pushed FRIENDS list: mutual follows, one plain run too.
    public var friends: ForYouPageState = .loading
    /// Which of Following's posts arrived since the session baseline —
    /// what orders the row's cards (unseen first) and what its badge
    /// counts, so the two cannot disagree.
    public var followingNew: Set<PostID> = []
    /// Which of the friends' posts the viewer has not seen yet.
    public var friendsUnseen: Set<PostID> = []
    public var rails = ForYouRails()

    public init() {}
}
