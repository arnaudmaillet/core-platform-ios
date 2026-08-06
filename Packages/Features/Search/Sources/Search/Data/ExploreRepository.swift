import CoreModels
import DesignSystem
import Foundation

/// One item of the corpus the trending list is ranked from: a post, reduced to
/// the only things this screen asks of it — who made it and how well it did.
///
/// **Not `GalleryPost`.** That type is the shared currency of surfaces that
/// render posts as tiles, and carrying it here meant depending on `PostGrid`
/// (and through it `MediaPlayback`) for media, aspect ratios and video URLs
/// that a list of people never looks at. The composition root projects onto
/// this instead, and Search's dependency graph is the smaller for it.
public struct ExplorePost: Equatable, Sendable {
    public let id: String
    public let authorID: ProfileID
    public let authorName: String
    public let authorHandle: String
    public let authorAvatarURL: URL?
    /// counter.v1 projection; nil when the read-model had no value, which
    /// ranks as zero rather than as a guess.
    public let reactionCount: Int64?
    public let publishedAtMS: Int64

    public init(
        id: String,
        authorID: ProfileID,
        authorName: String,
        authorHandle: String,
        authorAvatarURL: URL? = nil,
        reactionCount: Int64? = nil,
        publishedAtMS: Int64 = 0
    ) {
        self.id = id
        self.authorID = authorID
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.authorAvatarURL = authorAvatarURL
        self.reactionCount = reactionCount
        self.publishedAtMS = publishedAtMS
    }
}

/// The corpus the Search screen's trending list is ranked from.
///
/// ⚠️ **There is no discovery or trending endpoint in the contracts** — see
/// `dev/BACKEND_GAPS.md` §14. `timeline.v1` exposes `GetFollowingFeed` and
/// `GetAudioFeed`, neither of which is a ranked or curated corpus, so what
/// this vends today is the viewer's own following timeline and "trending" is
/// an ORDERING of it applied on the client. `DiscoverySource.trending` already
/// stands on exactly this footing for the For You tab, and this is the same
/// compromise made twice rather than a second, different one.
///
/// The protocol asks for a corpus and not for "creators", deliberately: the
/// ranking is this feature's, testable on its own in `ExploreRanking`, and the
/// implementation is a pass-through the composition root supplies. When a real
/// discovery endpoint lands, this is the seam that changes and the ranking
/// falls away.
public protocol ExploreProviding: Sendable {
    /// A page of the corpus, in whatever order the source gave it.
    func corpus(limit: Int) async throws -> [ExplorePost]
}

/// One person in the trending list.
public struct ExploreCreator: Equatable, Sendable, Identifiable {
    public let id: ProfileID
    public let displayName: String
    /// Bare, no sigil — the shared person row renders it under the name, the
    /// same way every other person list in the app does.
    public let handle: String
    public let monogram: String
    public let avatarURL: URL?
    /// Social context, resolved per person like every other list's.
    ///
    /// ⚠️ **It was briefly assumed instead — "the corpus is the following
    /// timeline, so everyone in it is followed" — and that is NOT true.** The
    /// mock's timeline returns posts from every author regardless of the
    /// follow graph, and nothing in `timeline.v1` promises otherwise; a search
    /// for one of these people came back "3 followers" while their Suggestions
    /// row claimed "Following". Cheap and wrong beat expensive and right for
    /// exactly one build. It is asked for now.
    public var context: ProfileRowContext = .none

    public init(id: ProfileID, displayName: String, handle: String, monogram: String, avatarURL: URL?) {
        self.id = id
        self.displayName = displayName
        self.handle = handle
        self.monogram = monogram
        self.avatarURL = avatarURL
    }
}

/// How the explore surface orders and slices its corpus. Pure, so the rules
/// are testable without a network or a view.
enum ExploreRanking {
    /// Most-reacted first.
    ///
    /// ⚠️ **Ranked over what was LOADED, not globally.** One page of the
    /// following timeline is the whole population this sees, so this is really
    /// "most-reacted among the posts we fetched" and will disagree with any
    /// server-side notion of trending. Stated here because the section's title
    /// cannot say it.
    ///
    /// Ties break on publication then id: `sorted(by:)` is not guaranteed
    /// stable, and without a total order a re-fetch could reshuffle rows the
    /// viewer is already looking at.
    static func ranked(_ posts: [ExplorePost]) -> [ExplorePost] {
        posts.sorted {
            ($0.reactionCount ?? 0, $0.publishedAtMS, $0.id)
                > ($1.reactionCount ?? 0, $1.publishedAtMS, $1.id)
        }
    }

    /// The distinct authors of `ranked`, in the order their best post appears.
    ///
    /// ⚠️ **The corpus is nominally the viewer's following timeline**, so this
    /// list leans towards people they already follow — but do not treat that
    /// as a guarantee. `timeline.v1` does not promise it and the mock does not
    /// honour it, which is why each row asks about its own relationship rather
    /// than inheriting one from where the data came from. What the list
    /// honestly is: who has been most active in what the viewer reads.
    static func creators(from ranked: [ExplorePost], limit: Int) -> [ExploreCreator] {
        var seen: Set<ProfileID> = []
        var creators: [ExploreCreator] = []
        for post in ranked {
            guard creators.count < limit else { break }
            guard !seen.contains(post.authorID) else { continue }
            let name = post.authorName.trimmingCharacters(in: .whitespaces)
            let displayName = name.isEmpty ? post.authorHandle : name
            // Nothing to render and nothing to route to.
            guard !displayName.isEmpty else { continue }
            seen.insert(post.authorID)
            creators.append(ExploreCreator(
                id: post.authorID,
                displayName: displayName,
                handle: post.authorHandle,
                monogram: SearchResultDisplayModel.monogram(
                    displayName: displayName, handle: post.authorHandle
                ),
                avatarURL: post.authorAvatarURL
            ))
        }
        return creators
    }
}
