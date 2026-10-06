import CoreModels
import Feed
// `GalleryPost` — the type being projected AWAY from. It is imported here, in
// the composition root, and nowhere in Search: that is the whole point of the
// projection below.
import PostGrid
import Search

/// Lets the Search screen's trending section read the same corpus the For You
/// tab does.
///
/// **A composition-root adapter rather than a dependency between the two
/// features.** Search declares what it needs (`ExploreProviding`, a page of
/// `GalleryPost`) and Feed already knows how to produce it; joining them here
/// is what keeps Search from importing Feed, which would make every edit to a
/// feed view model recompile the search screen.
///
/// It ranks nothing — that lives in `ExploreRanking`, inside Search, where it
/// is testable without a network. The only thing this type does is spell one
/// feature's vocabulary in the other's, which here means projecting a
/// `GalleryPost` (media, aspect ratios, video URLs — everything a tile needs)
/// down to the author and score a list of people actually reads.
///
/// The corpus is Discover's pool (`GetDiscoveryFeed`), everyone's, ranked by
/// the server; with no discovery wired it falls back to the viewer's
/// FOLLOWING timeline.
struct ForYouExploreAdapter: ExploreProviding {
    private let forYou: any ForYouProviding

    init(forYou: any ForYouProviding) {
        self.forYou = forYou
    }

    func corpus(limit: Int) async throws -> [ExplorePost] {
        // One page. The repository's page size is the feed's, which is already
        // more than a short list of people needs, and paging a section the
        // viewer cannot scroll past would be fetching for nobody.
        // Discover's pool when the backend serves one; the following
        // timeline otherwise.
        let discover = try await forYou.discoveryFirstPage()
        let page = if let discover { discover } else { try await forYou.firstPage() }
        return page.posts.prefix(limit).compactMap { post in
            // A post whose projection carried no author identifies nobody, so
            // there is no row it could become. `GalleryPost` carries the
            // author optionally because the profile gallery, already scoped to
            // one person, never needed it.
            guard let authorID = post.authorID else { return nil }
            return ExplorePost(
                id: post.id.rawValue,
                authorID: authorID,
                authorName: post.authorName ?? "",
                authorHandle: post.authorHandle ?? "",
                authorAvatarURL: post.authorAvatarURL,
                reactionCount: post.reactionCount,
                publishedAtMS: post.publishedAtMS
            )
        }
    }
}
