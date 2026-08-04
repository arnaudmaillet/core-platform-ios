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
        let before = viewModel.posts(for: .activity).map(\.id.rawValue)

        viewModel.loadNextPageIfNeeded()
        await settle()

        let after = viewModel.posts(for: .activity).map(\.id.rawValue)
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
            viewModel?.loadNextPageIfNeeded()
        }
        viewModel.loadNextPageIfNeeded()
        await settle()

        #expect(reentered)
        #expect(provider.pagedLoads == 1)
        let ids = viewModel.posts(for: .activity).map(\.id.rawValue)
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
    /// correctly in every one of them.
    @Test func emptyMessagesNameTheCombination() {
        #expect(ForYouViewModel.emptyState(format: .media, source: .trending).title == "No trending media yet.")
        #expect(ForYouViewModel.emptyState(format: .activity, source: .recent).title == "No recent activity yet.")
        // Sweeps the whole grid rather than sampling it: the sentence is built
        // from two enums, and a case added to either is a sentence nobody has
        // read. Every one must name both halves and end in a full stop.
        for format in GalleryFilter.Format.allCases {
            for source in DiscoverySource.allCases {
                let empty = ForYouViewModel.emptyState(format: format, source: source)
                #expect(empty.title.hasPrefix("No "))
                #expect(empty.title.hasSuffix(" yet."))
                // Nothing is narrowing an unfiltered page, so there is no
                // reason to offer — and inventing one would be noise.
                #expect(empty.subtitle == nil)
            }
        }
    }

    @Test func theFormatChoicePersistsAcrossViewModels() async {
        let suiteName = "foryou-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GalleryPreferences(defaults: defaults, keyPrefix: "foryou.gallery")

        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: nil))
        let first = ForYouViewModel(repository: provider, preferences: preferences)
        first.setFormat(.activity)

        let second = ForYouViewModel(repository: provider, preferences: preferences)
        #expect(second.format == .activity)
        // The source is deliberately NOT persisted — one screen, session state.
        #expect(second.source == .trending)
    }

    /// A fresh install opens on Discover — the case that `GalleryPreferences`'
    /// own `.activity` default silently hid, because an unwritten preference
    /// reads exactly like a viewer who chose Following.
    @Test func anUntouchedPreferenceOpensOnDiscover() async {
        let suiteName = "foryou-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GalleryPreferences(defaults: defaults, keyPrefix: "foryou.gallery")
        #expect(preferences.hasStoredFormat == false)

        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: nil))
        let model = ForYouViewModel(repository: provider, preferences: preferences)
        #expect(model.format == .media)
    }

    /// An install that last sat on a tab this screen no longer has must land on
    /// Discover, not on a page the pager cannot show — which would leave the
    /// capsule pointing at nothing.
    @Test func aRetiredTabInTheStoreFallsBackToDiscover() async {
        let suiteName = "foryou-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GalleryPreferences(defaults: defaults, keyPrefix: "foryou.gallery")
        // Written by a build that still had a Short tab.
        preferences.format = .short

        let provider = StubForYouProvider(first: ForYouPage(posts: mixed, nextPageToken: nil))
        let model = ForYouViewModel(repository: provider, preferences: preferences)
        #expect(model.format == .media)
    }

    /// The profile gallery persists the same format axis. The two stores must
    /// not see each other, or each surface yanks the other's landing tab.
    @Test func theFormatStoreDoesNotCollideWithTheProfileGallery() async {
        let suiteName = "foryou-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // `.short` on purpose: a value For You has no tab for, so adopting it
        // would be unmistakable. (`.media` would prove nothing now that it is
        // also For You's own landing tab.)
        let profile = GalleryPreferences(defaults: defaults)
        profile.filter = GalleryFilter(format: .short, source: .reposts)

        let discovery = GalleryPreferences(defaults: defaults, keyPrefix: "foryou.gallery")
        // Reading does not cross over: For You's own key is untouched, so it
        // lands on Discover rather than inheriting the profile's choice.
        #expect(discovery.hasStoredFormat == false)
        let viewModel = ForYouViewModel(
            repository: StubForYouProvider(first: ForYouPage(posts: [], nextPageToken: nil)),
            preferences: discovery
        )
        #expect(viewModel.format == .media)
        // And writing does not cross over either.
        viewModel.setFormat(.activity)
        #expect(profile.filter == GalleryFilter(format: .short, source: .reposts))
    }
}
