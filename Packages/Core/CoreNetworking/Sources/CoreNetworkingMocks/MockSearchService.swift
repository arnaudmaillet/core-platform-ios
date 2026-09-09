import Connect
import CoreContracts
import Foundation

/// Fake of search.v1.SearchService over the shared dataset. People search is a
/// case-insensitive substring match on handle and display name (friendlier than
/// the real backend's token match, so offline typeahead feels responsive); post
/// search matches captions the same way — the profile gallery's "Tagged"
/// category rides it with `@handle` queries against the seeded mentions.
///
/// `Suggest` is prefix-matched instead — see the method. `MultiSearch` is still
/// unrouted: nothing calls it, and a fake for an RPC with no caller would be a
/// guess about a shape no screen has had to agree with yet.
public final class MockSearchService: @unchecked Sendable {
    private let dataset: MockSocialDataset
    /// Read for POPULARITY only. Optional so a test can build this fake alone;
    /// without it, popularity falls back to how many posts an author has.
    private let counters: MockCounterStore?

    public init(dataset: MockSocialDataset, counters: MockCounterStore? = nil) {
        self.dataset = dataset
        self.counters = counters
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/search.v1.SearchService/Search") { [self] (request: Search_V1_SearchRequest) in
            search(request)
        }
        bff.register(path: "/search.v1.SearchService/Suggest") { [self] (request: Search_V1_SuggestRequest) in
            suggest(request)
        }
    }

    /// Typeahead completions.
    ///
    /// **Prefix, not substring — unlike `Search` above.** The contract's field
    /// is literally `prefix`, and the difference is what makes the two RPCs
    /// worth having separately: half a word should complete to the handles it
    /// starts, not to every handle that contains it. Display names are matched
    /// per WORD, so "whit" finds "Sam Whitfield" without "itfield" doing so.
    ///
    /// Completions are handles rather than display names: the handle is what
    /// the index stores and what a viewer finishing a search means to type.
    private func suggest(_ request: Search_V1_SuggestRequest) -> Result<Search_V1_SuggestResponse, ConnectError> {
        var response = Search_V1_SuggestResponse()

        let prefix = request.prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !prefix.isEmpty else { return .success(response) }

        let wantsProfiles = request.entityTypes.isEmpty || request.entityTypes.contains(.profile)
        guard wantsProfiles else { return .success(response) }

        let matches = dataset.authors.filter { author in
            author.handle.lowercased().hasPrefix(prefix)
                || author.displayName.lowercased()
                    .split(separator: " ")
                    .contains { $0.hasPrefix(prefix) }
        }
        let limit = request.limit > 0 ? Int(request.limit) : matches.count
        response.suggestions = matches.prefix(limit).map { author in
            var suggestion = Search_V1_Suggestion()
            suggestion.entityType = .profile
            suggestion.text = author.handle
            suggestion.id = author.profileID
            return suggestion
        }
        return .success(response)
    }

    private func search(_ request: Search_V1_SearchRequest) -> Result<Search_V1_SearchResponse, ConnectError> {
        var response = Search_V1_SearchResponse()

        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return .success(response) }

        let wantsProfiles = request.entityTypes.isEmpty || request.entityTypes.contains(.profile)
        let wantsPosts = request.entityTypes.isEmpty || request.entityTypes.contains(.post)

        if wantsProfiles {
            let matches = sorted(
                dataset.authors.filter {
                    $0.handle.lowercased().contains(query) || $0.displayName.lowercased().contains(query)
                },
                by: request.sort
            )
            response.hits += matches.map { author in
                var hit = Search_V1_SearchHit()
                hit.entityType = .profile
                hit.id = author.profileID
                var profile = Search_V1_ProfileHit()
                profile.handle = author.handle
                profile.displayName = author.displayName
                hit.profile = profile
                return hit
            }
        }

        if wantsPosts {
            let matches = dataset.posts.filter { $0.caption.lowercased().contains(query) }
            response.hits += matches.map { record in
                var hit = Search_V1_SearchHit()
                hit.entityType = .post
                hit.id = record.postID
                var post = Search_V1_PostHit()
                post.authorID = record.authorProfileID
                post.authorHandle = handle(forAuthor: record.authorProfileID)
                // ⚠️ THESE TWO WERE LEFT AT THEIR DEFAULTS, which made every
                // post hit dateless and pictureless — `hasCreatedAt == false`
                // and an empty key. Nothing read post hits at the time, so
                // nothing noticed; a screen that renders them would have shown
                // a row with no thumbnail and no date and looked like a broken
                // projection rather than an unfilled fake.
                //
                // `thumbnailKey` is the media URL rather than an object-store
                // key, and that is the same shape `geo_discovery.v1` hands the
                // map: this fake serves URLs its own catalog can resolve, and a
                // reader that expects a key would have nothing to resolve it
                // against offline anyway. Text-only posts keep it empty, which
                // is the same "this post has no picture" signal the map reads.
                post.thumbnailKey = record.media?.url ?? ""
                post.createdAt = .init(
                    seconds: record.publishedAtMS / 1000,
                    nanos: Int32((record.publishedAtMS % 1000) * 1_000_000)
                )
                hit.post = post
                return hit
            }
        }

        response.estimatedTotal = Int64(response.hits.count)
        return .success(response)
    }

    /// The author's handle, INCLUDING the viewer's own.
    ///
    /// ⚠️ `dataset.author(for:)` searches `authors`, and the viewer is not in
    /// it — `prof-demo-viewer` is a profile the dataset owns separately. So the
    /// viewer's own posts came back with an EMPTY handle, which nothing noticed
    /// while nothing rendered post hits. Measured, on the query "harbour":
    ///
    ///     id=post-new-04 author=sofia.reyes ...
    ///     id=post-me-06  author=            ...   ← the viewer's own post
    ///
    /// "you" is the handle every other mock answers with for that profile (see
    /// `MockSocialServices`' account-profiles route), so this agrees with them
    /// rather than inventing a second name for the same person.
    private func handle(forAuthor profileID: String) -> String {
        if profileID == MockSocialDataset.viewerProfileID { return "you" }
        return dataset.author(for: profileID)?.handle ?? ""
    }

    /// Orders people the way `request.sort` asks for.
    ///
    /// ⚠️ THIS EXISTED AS A NO-OP AND THAT WAS WORSE THAN MISSING. The mock
    /// accepted `sort` and ignored it, so the search screen's filter tray —
    /// which puts the order on the wire correctly — changed nothing at all in
    /// the mode the app is developed and demoed in. A control that does nothing
    /// offline is indistinguishable from a control that is broken.
    ///
    /// ⚠️ WHAT THE STAND-INS ARE, so nobody reads them as the fleet's ranking:
    ///
    ///   - `relevance` (and unspecified): dataset order, which is what this
    ///     fake has always answered with. The real engine scores text; there is
    ///     no scorer here and inventing one would fake a signal.
    ///   - `recency`: the author's most recent post, newest first. `Author`
    ///     carries no date of its own, so the freshest thing they published is
    ///     the honest stand-in for how fresh THEY are.
    ///
    ///     ⚠️ THIS LOOKS LIKE A NO-OP ON THE SEEDED DATASET AND IS NOT. The
    ///     fixture publishes authors in descending time order, so "newest
    ///     first" and "dataset order" are the same list — measured, keys
    ///     descending: ava.moreau 1788941307181 > kenji.dev 1788941247181 >
    ///     lena_klein 1788941187181. Relevance and recency agreeing here is a
    ///     property of the fixture, not a sort that failed to run.
    ///   - `popularity`: the author's total received likes, from
    ///     `MockCounterStore.totalLikes(forAuthor:)` — the same figure
    ///     `counter.v1` projects for a profile, so the fake and the screens
    ///     that read counters agree. Falling back to post COUNT when no store
    ///     is injected.
    ///
    /// ⚠️ THE FALLBACK IS NOT ENOUGH ON ITS OWN, and that is why the store is
    /// wired in. Post count was the first stand-in, and it ranked every author
    /// identically: the seeded dataset gives all of them exactly four posts, so
    /// the sort ran, honoured the request, and returned the input order. A
    /// filter that provably works and visibly does nothing is the thing this
    /// whole change exists to avoid.
    ///
    /// Ties keep dataset order — `sorted(by:)` is not stable, so the key
    /// includes the author's index to make the answer reproducible run to run.
    private func sorted(
        _ authors: [MockSocialDataset.Author], by sort: Search_V1_SearchSort
    ) -> [MockSocialDataset.Author] {
        switch sort {
        case .recency:
            rank(authors) { posts in posts.map(\.publishedAtMS).max() ?? .min }
        case .popularity:
            if let counters {
                rank(authors) { posts in
                    posts.reduce(0) { $0 + counters.likeCount(for: $1.postID) }
                }
            } else {
                rank(authors) { posts in Int64(posts.count) }
            }
        case .relevance, .unspecified, .UNRECOGNIZED:
            authors
        }
    }

    /// Orders by a key derived from each author's posts, descending, with the
    /// author's original position breaking ties.
    private func rank(
        _ authors: [MockSocialDataset.Author],
        by key: ([MockSocialDataset.PostRecord]) -> Int64
    ) -> [MockSocialDataset.Author] {
        let postsByAuthor = Dictionary(grouping: dataset.posts, by: \.authorProfileID)
        let keyed = authors.enumerated().map { index, author in
            (author: author, key: key(postsByAuthor[author.profileID] ?? []), index: index)
        }
        return keyed
            .sorted { ($0.key, -$0.index) > ($1.key, -$1.index) }
            .map(\.author)
    }
}
