import CoreModels
import CoreNetworking
import Foundation
import PostGrid
import Testing
@testable import Feed

// MARK: - Fixtures

private func tile(
    _ id: String,
    kind: GalleryPost.Kind = .photo,
    publishedAtMS: Int64 = 0,
    reactions: Int64? = nil
) -> GalleryPost {
    GalleryPost(
        id: PostID(id),
        kind: kind,
        isRepost: false,
        thumbnailURL: nil,
        caption: "caption \(id)",
        publishedAtMS: publishedAtMS,
        reactionCount: reactions
    )
}

private func entry(
    _ id: String,
    mimeType: String? = "image/jpeg",
    thumbnail: String? = "https://cdn.example/\(UUID().uuidString)-thumb.jpg",
    url: String? = "https://cdn.example/full.jpg",
    caption: String = "hello",
    publishedAt: Date = Date(timeIntervalSince1970: 0),
    likeCount: Int64 = 0
) -> FeedEntry {
    FeedEntry(
        post: Post(
            id: PostID(id),
            authorID: ProfileID("author"),
            caption: caption,
            attachments: mimeType.map {
                [MediaAttachment(
                    url: url.flatMap(URL.init(string:)),
                    thumbnailURL: thumbnail.flatMap(URL.init(string:)),
                    mimeType: $0,
                    pixelWidth: 100,
                    pixelHeight: 100
                )]
            } ?? [],
            publishedAt: publishedAt
        ),
        author: AuthorSummary(id: ProfileID("author"), handle: "a", displayName: "A", avatarURL: nil),
        likeCount: likeCount
    )
}

private final class StubForYouProvider: ForYouProviding, @unchecked Sendable {
    private let lock = NSLock()
    var pages: [String?: ForYouPage] = [:]
    var failFirstPage = false
    private(set) var firstPageLoads = 0
    private(set) var pagedLoads = 0

    init(first: ForYouPage) { pages[nil] = first }

    func firstPage() async throws -> ForYouPage {
        try lock.withLock {
            firstPageLoads += 1
            if failFirstPage { throw FeedError.transport(message: "nope") }
            return pages[nil] ?? ForYouPage(posts: [], nextPageToken: nil)
        }
    }

    func page(after token: String) async throws -> ForYouPage {
        lock.withLock {
            pagedLoads += 1
            return pages[token] ?? ForYouPage(posts: [], nextPageToken: nil)
        }
    }
}

/// Serves a fixed set through the real `FeedProviding` seam, so
/// `ForYouRepository`'s projection is exercised end to end.
private struct StubFeed: FeedProviding {
    var first: FeedPage
    var next: FeedPage?

    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { first }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        next ?? FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry { entry(id.rawValue) }
}

@MainActor
private func settle() async {
    for _ in 0..<12 { await Task.yield() }
}

// MARK: - Ordering

struct DiscoverySourceTests {
    private let posts = [
        tile("a", publishedAtMS: 10, reactions: 5),
        tile("b", publishedAtMS: 30, reactions: 1),
        tile("c", publishedAtMS: 20, reactions: 9)
    ]

    /// The menu offers exactly the orderings the enum has, and every one of
    /// them reorders something. The removed `.following` case did not — it
    /// returned the corpus untouched — which is part of why it went.
    @Test func everySourceIsAnOrdering() {
        #expect(DiscoverySource.allCases == [.trending, .recent])
        for source in DiscoverySource.allCases {
            #expect(source.ordering(posts).map(\.id.rawValue) != ["a", "b", "c"])
        }
    }

    @Test func recentSortsByPublication() {
        #expect(DiscoverySource.recent.ordering(posts).map(\.id.rawValue) == ["b", "c", "a"])
    }

    @Test func trendingSortsByReactions() {
        #expect(DiscoverySource.trending.ordering(posts).map(\.id.rawValue) == ["c", "a", "b"])
    }

    /// A post with no counter must not outrank one with a real count, and ties
    /// must resolve deterministically — otherwise a page append reshuffles rows
    /// the viewer is already reading.
    @Test func tiesBreakDeterministically() {
        let tied = [
            tile("x", publishedAtMS: 5, reactions: nil),
            tile("y", publishedAtMS: 5, reactions: 0),
            tile("z", publishedAtMS: 5, reactions: 3)
        ]
        let once = DiscoverySource.trending.ordering(tied).map(\.id.rawValue)
        let twice = DiscoverySource.trending.ordering(tied.reversed()).map(\.id.rawValue)
        #expect(once == ["z", "y", "x"])
        #expect(once == twice)
    }
}

// MARK: - Projection

struct ForYouRepositoryTests {
    @Test func projectsKindFromMimeType() async throws {
        let repository = ForYouRepository(feed: StubFeed(first: FeedPage(
            entries: [
                entry("photo", mimeType: "image/jpeg"),
                entry("video", mimeType: "video/mp4"),
                entry("text", mimeType: nil)
            ],
            nextPageToken: nil, isCold: false
        )))
        let page = try await repository.firstPage()
        #expect(page.posts.map(\.kind) == [.photo, .video, .text])
    }

    @Test func fallsBackToTheFullURLWhenThereIsNoThumbnail() async throws {
        let repository = ForYouRepository(feed: StubFeed(first: FeedPage(
            entries: [entry("p", thumbnail: nil, url: "https://cdn.example/full.jpg")],
            nextPageToken: nil, isCold: false
        )))
        let page = try await repository.firstPage()
        #expect(page.posts.first?.thumbnailURL?.absoluteString == "https://cdn.example/full.jpg")
    }

    /// The timeline read hydrates likes only. Comments must stay ABSENT
    /// rather than be asserted as zero — the cells hide a counter with
    /// no value, and a rendered "0" would be a lie.
    @Test func carriesLikesAndLeavesUnhydratedCountersAbsent() async throws {
        let repository = ForYouRepository(feed: StubFeed(first: FeedPage(
            entries: [entry("p", likeCount: 42)],
            nextPageToken: "next", isCold: false
        )))
        let page = try await repository.firstPage()
        let post = try #require(page.posts.first)
        #expect(post.reactionCount == 42)
        #expect(post.commentCount == nil)
        #expect(page.nextPageToken == "next")
    }

    @Test func projectsPublicationDateToMilliseconds() async throws {
        let repository = ForYouRepository(feed: StubFeed(first: FeedPage(
            entries: [entry("p", publishedAt: Date(timeIntervalSince1970: 1_700_000))],
            nextPageToken: nil, isCold: false
        )))
        let page = try await repository.firstPage()
        #expect(page.posts.first?.publishedAtMS == 1_700_000_000)
    }
}

// MARK: - View model

@MainActor
struct ForYouViewModelTests {
    private func makeViewModel(
        _ provider: StubForYouProvider
    ) -> (ForYouViewModel, () -> [ForYouViewModel.Snapshot]) {
        let viewModel = ForYouViewModel(repository: provider)
        var snapshots: [ForYouViewModel.Snapshot] = []
        viewModel.onSnapshotChange = { snapshots.append($0) }
        return (viewModel, { snapshots })
    }

    private var mixed: [GalleryPost] {
        [
            tile("m1", kind: .photo, publishedAtMS: 40, reactions: 1),
            tile("m2", kind: .video, publishedAtMS: 30, reactions: 7),
            tile("t1", kind: .text, publishedAtMS: 20, reactions: 3)
        ]
    }

    /// The list and the pushed lists are every kind; the pushed MOSAIC is the
    /// media alone.
    @Test func theMosaicIsTheMediaAndTheListsAreEveryKind() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: nil))
        let (viewModel, snapshots) = makeViewModel(provider)
        viewModel.viewDidLoad()
        await settle()

        let last = try! #require(snapshots().last)
        #expect(last.discover == .content(DiscoverySource.trending.ordering(mixed)))
        // No graph wired: everyone is Following, nobody a friend.
        #expect(last.following == last.discover)
        #expect(last.friends == .empty(ForYouViewModel.emptyState(for: .friend)))
        if case .content(let media) = last.media {
            #expect(media.map(\.id.rawValue) == ["m2", "m1"])
        } else {
            Issue.record("media page should have content, got \(last.media)")
        }
    }

    /// Changing the ordering must be a local recompute, never a refetch.
    @Test func changingSourceRecomputesWithoutRefetching() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: nil))
        let (viewModel, snapshots) = makeViewModel(provider)
        viewModel.viewDidLoad()
        await settle()
        let landed = snapshots().count

        viewModel.setSource(.recent)
        await settle()

        #expect(provider.firstPageLoads == 1)
        #expect(snapshots().count == landed + 1)
        #expect(snapshots().last?.discover == .content(DiscoverySource.recent.ordering(mixed)))
    }

    @Test func repeatingTheActiveSourceIsANoOp() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: nil))
        let (viewModel, snapshots) = makeViewModel(provider)
        viewModel.viewDidLoad()
        await settle()
        let landed = snapshots().count

        viewModel.setSource(.trending) // already the default
        await settle()

        #expect(snapshots().count == landed)
    }

    /// A page APPENDS. It must never renumber what is already on screen, even
    /// when the new post outranks everything loaded — a grid that reshuffles
    /// under the viewer is worse than one whose ranking is per-page, and it
    /// broke the hero outright (the landing tile moved out from under the card).
    @Test func nextPageAppendsWithoutRenumberingWhatIsAlreadyShown() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: "p2"))
        provider.pages["p2"] = ForYouPage(
            posts: [tile("m3", kind: .photo, publishedAtMS: 50, reactions: 99)],
            nextPageToken: nil
        )
        let (viewModel, _) = makeViewModel(provider)
        viewModel.viewDidLoad()
        await settle()
        let before = viewModel.discoverPosts.map(\.id.rawValue)

        viewModel.loadNextPageIfNeeded(.discover)
        await settle()

        let after = viewModel.discoverPosts.map(\.id.rawValue)
        // m3 has the highest reaction count of anything loaded, and STILL goes
        // last: the first page's order is preserved exactly.
        #expect(Array(after.prefix(before.count)) == before)
        #expect(after == before + ["m3"])

        // The corpus is exhausted; further requests must not hit the network.
        viewModel.loadNextPageIfNeeded(.discover)
        await settle()
        #expect(provider.pagedLoads == 1)
    }

    /// A page that re-serves rows the corpus already holds must not duplicate
    /// them. Pages are not reliably disjoint — the mock's offset cursor
    /// shifts when the timeline grows underneath it, and a real cursor can
    /// re-serve a boundary row the same way — and a repeated id is fatal
    /// downstream: the snap feed seeds `Dictionary(uniqueKeysWithValues:)`
    /// from a tapped tile's slice, which traps on the duplicate. Found live:
    /// catch-and-reverse a hero present, let the next page land, tap any
    /// tile — crash on 'post-0033'.
    @Test func anOverlappingPageAppendsOnlyItsGenuinelyNewPosts() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: "p2"))
        provider.pages["p2"] = ForYouPage(
            posts: [
                tile("m2", kind: .video, publishedAtMS: 20, reactions: 3), // re-served
                tile("m3", kind: .photo, publishedAtMS: 50, reactions: 99)
            ],
            nextPageToken: nil
        )
        let (viewModel, _) = makeViewModel(provider)
        viewModel.viewDidLoad()
        await settle()
        let before = viewModel.discoverPosts.map(\.id.rawValue)

        viewModel.loadNextPageIfNeeded(.discover)
        await settle()

        let after = viewModel.discoverPosts.map(\.id.rawValue)
        #expect(after == before + ["m3"])
        #expect(Set(after).count == after.count)
    }

    /// `onPagingChange(true)` shows the paging footer, showing the footer
    /// runs a layout pass, and a layout pass can fire `onNearEnd` — so the
    /// announcement can RE-ENTER `loadNextPageIfNeeded` synchronously. When
    /// the announcement preceded the `pageLoad` assignment, the re-entrant
    /// call passed the in-flight guard and fetched the same token twice,
    /// appending the whole page again (found live via a hero flight's staging
    /// layout; the duplicate then trapped the snap feed's seed dictionary).
    @Test func aReentrantNearEndDuringTheAnnouncementDoesNotDoubleFetch() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: "p2"))
        provider.pages["p2"] = ForYouPage(
            posts: [tile("m3", kind: .photo, publishedAtMS: 50, reactions: 99)],
            nextPageToken: nil
        )
        let (viewModel, _) = makeViewModel(provider)
        viewModel.viewDidLoad()
        await settle()

        var reentered = false
        viewModel.onPagingChange = { [weak viewModel] starting in
            guard starting, !reentered else { return }
            reentered = true
            viewModel?.loadNextPageIfNeeded(.discover)
        }
        viewModel.loadNextPageIfNeeded(.discover)
        await settle()

        #expect(reentered)
        #expect(provider.pagedLoads == 1)
        let ids = viewModel.discoverPosts.map(\.id.rawValue)
        #expect(Set(ids).count == ids.count)
    }

    /// Changing the source is the one action that may reorder everything,
    /// because the viewer asked for it.
    @Test func changingSourceReordersTheWholeLoadedCorpus() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: "p2"))
        provider.pages["p2"] = ForYouPage(
            posts: [tile("m3", kind: .photo, publishedAtMS: 50, reactions: 99)],
            nextPageToken: nil
        )
        let (viewModel, _) = makeViewModel(provider)
        viewModel.viewDidLoad()
        await settle()
        viewModel.loadNextPageIfNeeded(.discover)
        await settle()

        viewModel.setSource(.recent)
        await settle()

        // Across BOTH pages, newest first. m3 was appended LAST under
        // `.trending`; it is the newest of the four, so switching to `.recent`
        // lifts it to the front — the reorder a source change is allowed to do.
        #expect(viewModel.discoverPosts.map(\.id.rawValue) == ["m3", "m1", "m2", "t1"])
    }

    @Test func pagingIsIgnoredBeforeTheFirstPageLands() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: "p2"))
        let (viewModel, _) = makeViewModel(provider)
        viewModel.loadNextPageIfNeeded(.discover) // nothing loaded yet
        await settle()
        #expect(provider.pagedLoads == 0)
    }

    @Test func refreshRefetchesFromScratch() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: nil))
        let (viewModel, _) = makeViewModel(provider)
        viewModel.viewDidLoad()
        await settle()

        viewModel.refresh()
        await settle()
        #expect(provider.firstPageLoads == 2)
    }

    /// #798: a refresh that fails over loaded content keeps that content —
    /// no loading frame, no failed page — and reports the failure instead.
    @Test func aFailedRefreshKeepsTheContentOnScreenAndSaysSo() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: nil))
        let (viewModel, snapshots) = makeViewModel(provider)
        var refreshFailures = 0
        var settled = 0
        viewModel.onRefreshFailed = { refreshFailures += 1 }
        viewModel.onLoadSettled = { settled += 1 }
        viewModel.viewDidLoad()
        await settle()
        let landed = try! #require(snapshots().last)
        let publishedBeforeRefresh = snapshots().count

        provider.failFirstPage = true
        viewModel.refresh()
        await settle()

        #expect(provider.firstPageLoads == 2)
        #expect(refreshFailures == 1)
        #expect(settled == 2, "the refresh control still ends")
        // Nothing republished: every page is still the content that landed.
        #expect(snapshots().count == publishedBeforeRefresh)
        #expect(snapshots().last == landed)
        #expect(landed.discover == .content(DiscoverySource.trending.ordering(mixed)))
        #expect(viewModel.post(for: PostID("m1")) != nil)
    }

    /// #798: a successful refresh replaces the corpus straight from content
    /// to content, announced as a re-derivation, never through `.loading`.
    @Test func aSuccessfulRefreshReplacesTheContentWithoutALoadingFrame() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: nil))
        let (viewModel, snapshots) = makeViewModel(provider)
        var resets = 0
        var refreshFailures = 0
        viewModel.onCorpusReset = { resets += 1 }
        viewModel.onRefreshFailed = { refreshFailures += 1 }
        viewModel.viewDidLoad()
        await settle()
        let publishedBeforeRefresh = snapshots().count

        let fresh = [tile("n1", publishedAtMS: 50)] + mixed
        provider.pages[nil] = ForYouPage(posts: fresh, nextPageToken: nil)
        viewModel.refresh()
        await settle()

        let afterRefresh = snapshots().dropFirst(publishedBeforeRefresh)
        #expect(!afterRefresh.contains { $0.discover == .loading })
        #expect(afterRefresh.last?.discover == .content(DiscoverySource.trending.ordering(fresh)))
        #expect(resets == 1)
        #expect(refreshFailures == 0)
    }

    /// #798: a pull while the INITIAL load is out leaves that load to answer —
    /// it used to cancel it and start nothing, and the page stayed loading
    /// for good with its refresh control turning.
    @Test func aPullDuringTheInitialLoadStillSettles() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: nil))
        let (viewModel, snapshots) = makeViewModel(provider)
        var settled = 0
        viewModel.onLoadSettled = { settled += 1 }
        viewModel.viewDidLoad()
        viewModel.refresh() // before the initial load has answered
        await settle()

        #expect(settled == 1, "the refresh control ends")
        #expect(provider.firstPageLoads == 1)
        #expect(snapshots().last?.discover == .content(DiscoverySource.trending.ordering(mixed)))
    }

    /// #798: with nothing loaded, a failed refresh is still the failed page
    /// (with its retry), not a toast over nothing.
    @Test func aFailedRefreshWithNothingLoadedStillShowsTheFailedPage() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: [], nextPageToken: nil))
        provider.failFirstPage = true
        let (viewModel, snapshots) = makeViewModel(provider)
        var refreshFailures = 0
        viewModel.onRefreshFailed = { refreshFailures += 1 }
        viewModel.viewDidLoad()
        await settle()

        viewModel.refresh()
        await settle()

        #expect(provider.firstPageLoads == 2)
        #expect(refreshFailures == 0)
        #expect(snapshots().last?.discover == .failed(message: "Couldn't load. Pull to retry."))
    }

    @Test func aFailedLoadReportsOnEveryPage() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: [], nextPageToken: nil))
        provider.failFirstPage = true
        let (viewModel, snapshots) = makeViewModel(provider)
        viewModel.viewDidLoad()
        await settle()

        let last = try! #require(snapshots().last)
        #expect(last.discover == .failed(message: "Couldn't load. Pull to retry."))
        #expect(last.media == last.discover)
        #expect(last.following == last.discover)
        #expect(last.friends == last.discover)
    }

    /// ⚠️ THE NETWORK COMES BACK, FOR YOU LOADS (#793): a corpus that failed
    /// while offline reloads on recovery, without a pull.
    ///
    /// ⚠️ ITS OWN MONITOR: the shared one is process-wide, and flipping it
    /// reloaded every store alive in the parallel suites.
    @Test func aFailedForYouReloadsWhenTheNetworkReturns() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: nil))
        provider.failFirstPage = true
        let monitor = ConnectivityMonitor(offlineGrace: 0)
        let (viewModel, snapshots) = makeViewModel(provider)
        viewModel.connectivity = monitor
        viewModel.viewDidLoad()
        for _ in 0..<200 where snapshots().last?.discover != .failed(message: "Couldn't load. Pull to retry.") {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(snapshots().last?.discover == .failed(message: "Couldn't load. Pull to retry."))

        provider.failFirstPage = false
        monitor.report(online: false)
        monitor.report(online: true)
        let landed = ForYouViewModel.PageState.content(DiscoverySource.trending.ordering(mixed))
        for _ in 0..<200 where snapshots().last?.discover != landed {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(provider.firstPageLoads == 2)
        #expect(snapshots().last?.discover == landed)
    }

    /// An empty list has to name itself — and an unfiltered one offers no
    /// reason, since inventing one would be noise.
    @Test func emptyMessagesNameTheList() {
        for source in DiscoverySource.allCases {
            let empty = ForYouViewModel.discoverEmptyState(source: source)
            #expect(empty.title.hasSuffix(" yet."))
            #expect(empty.subtitle == nil)
        }
        for circle in [ForYouViewModel.Circle.friend, .following] {
            let empty = ForYouViewModel.emptyState(for: circle)
            #expect(empty.title.hasPrefix("No "))
            #expect(empty.title.hasSuffix(" yet."))
            #expect(empty.subtitle == nil)
        }
    }
}
