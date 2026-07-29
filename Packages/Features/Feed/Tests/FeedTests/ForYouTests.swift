import CoreModels
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

    @Test func followingPreservesServerOrder() {
        #expect(DiscoverySource.following.ordering(posts).map(\.id.rawValue) == ["a", "b", "c"])
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

    /// The timeline read hydrates likes only. Comments and views must stay
    /// ABSENT rather than be asserted as zero — the cells hide a counter with
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
        #expect(post.viewCount == nil)
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

    @Test func eachFormatFiltersTheCorpusByKind() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: nil))
        let (viewModel, snapshots) = makeViewModel(provider)
        viewModel.viewDidLoad()
        await settle()

        let last = try! #require(snapshots().last)
        #expect(last.activity == .content(DiscoverySource.trending.ordering(mixed)))
        if case .content(let media) = last.media {
            #expect(media.map(\.id.rawValue) == ["m2", "m1"])
        } else {
            Issue.record("media page should have content, got \(last.media)")
        }
        if case .content(let short) = last.short {
            #expect(short.map(\.id.rawValue) == ["t1"])
        } else {
            Issue.record("short page should have content, got \(last.short)")
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
        #expect(snapshots().last?.activity == .content(DiscoverySource.recent.ordering(mixed)))
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
        let before = viewModel.posts(for: .activity).map(\.id.rawValue)

        viewModel.loadNextPageIfNeeded()
        await settle()

        let after = viewModel.posts(for: .activity).map(\.id.rawValue)
        // m3 has the highest reaction count of anything loaded, and STILL goes
        // last: the first page's order is preserved exactly.
        #expect(Array(after.prefix(before.count)) == before)
        #expect(after == before + ["m3"])

        // The corpus is exhausted; further requests must not hit the network.
        viewModel.loadNextPageIfNeeded()
        await settle()
        #expect(provider.pagedLoads == 1)
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
        viewModel.loadNextPageIfNeeded()
        await settle()

        viewModel.setSource(.recent)
        await settle()

        // Across BOTH pages, newest first. m3 was appended LAST under
        // `.trending`; it is the newest of the four, so switching to `.recent`
        // lifts it to the front — the reorder a source change is allowed to do.
        #expect(viewModel.posts(for: .activity).map(\.id.rawValue) == ["m3", "m1", "m2", "t1"])
    }

    @Test func pagingIsIgnoredBeforeTheFirstPageLands() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: "p2"))
        let (viewModel, _) = makeViewModel(provider)
        viewModel.loadNextPageIfNeeded() // nothing loaded yet
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

    @Test func aFailedLoadReportsOnEveryPage() async {
        let provider = StubForYouProvider(first: ForYouPage(posts: [], nextPageToken: nil))
        provider.failFirstPage = true
        let (viewModel, snapshots) = makeViewModel(provider)
        viewModel.viewDidLoad()
        await settle()

        let last = try! #require(snapshots().last)
        #expect(last.activity == .failed(message: "Couldn't load. Pull to retry."))
        #expect(last.media == last.activity)
        #expect(last.short == last.activity)
    }

    /// An empty combination has to name itself, and the sentence has to read
    /// correctly in all nine — the source phrase sits in a different slot for
    /// `.following` than for the two adjectives.
    @Test func emptyMessagesNameTheCombination() {
        #expect(ForYouViewModel.emptyMessage(format: .media, source: .trending) == "No trending media yet.")
        #expect(ForYouViewModel.emptyMessage(format: .short, source: .recent) == "No recent short posts yet.")
        #expect(
            ForYouViewModel.emptyMessage(format: .activity, source: .following)
                == "No activity from people you follow yet."
        )
    }

    @Test func theFormatChoicePersistsAcrossViewModels() async {
        let suiteName = "foryou-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GalleryPreferences(defaults: defaults, keyPrefix: "foryou.gallery")

        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: nil))
        let first = ForYouViewModel(repository: provider, preferences: preferences)
        first.setFormat(.short)

        let second = ForYouViewModel(repository: provider, preferences: preferences)
        #expect(second.format == .short)
        // The source is deliberately NOT persisted — one screen, session state.
        #expect(second.source == .trending)
    }

    /// The profile gallery persists the same format axis. The two stores must
    /// not see each other, or each surface yanks the other's landing tab.
    @Test func theFormatStoreDoesNotCollideWithTheProfileGallery() async {
        let suiteName = "foryou-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = GalleryPreferences(defaults: defaults)
        profile.filter = GalleryFilter(format: .media, source: .reposts)

        let discovery = GalleryPreferences(defaults: defaults, keyPrefix: "foryou.gallery")
        let viewModel = ForYouViewModel(
            repository: StubForYouProvider(first: ForYouPage(posts: [], nextPageToken: nil)),
            preferences: discovery
        )
        #expect(viewModel.format == .activity) // not the profile's .media
        viewModel.setFormat(.short)
        #expect(profile.filter == GalleryFilter(format: .media, source: .reposts))
    }
}
