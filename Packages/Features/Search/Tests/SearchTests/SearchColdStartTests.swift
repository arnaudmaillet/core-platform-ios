import CacheKit
import CoreModels
import CoreStorage
import DesignSystem
import Foundation
import LocalStore
import Synchronization
import Testing
@testable import Search

// Search's resting screen opens on its last trending people at a cold start,
// offline included, and skips the fetch inside their freshness window (#893).

private final class StoreFolder: Sendable {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "SearchColdStartTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit { try? FileManager.default.removeItem(at: url) }
}

private final class ViewerBox: Sendable {
    private let current = Mutex<LocalStoreViewer?>(.member(account: "acct-1", profile: "me"))

    var viewer: LocalStoreViewer? {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}

private actor SilentSearch: SearchProviding {
    func searchProfiles(matching query: String, sort: SearchSortOrder, limit: Int32) async throws -> [ProfileSearchResult] { [] }
    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
}

/// The corpus, or a failure while offline; counts fetches.
private final class Corpus: ExploreProviding, @unchecked Sendable {
    struct Offline: Error {}

    private let lock = NSLock()
    private var _posts: [ExplorePost]
    private var _offline = false
    private var _fetches = 0

    init(_ posts: [ExplorePost]) { _posts = posts }

    var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }
    var posts: [ExplorePost] {
        get { lock.withLock { _posts } }
        set { lock.withLock { _posts = newValue } }
    }
    var fetches: Int { lock.withLock { _fetches } }

    func corpus(limit: Int) async throws -> [ExplorePost] {
        let (posts, offline) = lock.withLock { () -> ([ExplorePost], Bool) in
            _fetches += 1
            return (_posts, _offline)
        }
        if offline { throw Offline() }
        return posts
    }
}

private actor People: ProfileMetadataProviding {
    private let followed: Set<String>
    private let followers: [String: Int]
    private let offline: Bool

    init(followed: Set<String> = [], followers: [String: Int] = [:], offline: Bool = false) {
        self.followed = followed
        self.followers = followers
        self.offline = offline
    }

    /// Offline, every read fails and answers "nothing known", as
    /// `ProfileMetadataRepository` does.
    private(set) var asked = 0

    func metadata(for ids: [ProfileID]) async -> [ProfileID: ProfileRowMetadata] {
        asked += 1
        var found: [ProfileID: ProfileRowMetadata] = [:]
        guard !offline else {
            for id in ids { found[id] = ProfileRowMetadata(avatarURL: nil, isFollowed: false, followerCount: nil) }
            return found
        }
        for id in ids {
            found[id] = ProfileRowMetadata(
                avatarURL: URL(string: "https://cdn.example/\(id.rawValue).jpg"),
                isFollowed: followed.contains(id.rawValue),
                followerCount: followers[id.rawValue]
            )
        }
        return found
    }
}

private func post(_ id: String, reactions: Int64, author: String) -> ExplorePost {
    ExplorePost(
        id: id, authorID: ProfileID(author), authorName: author.capitalized, authorHandle: author,
        authorAvatarURL: URL(string: "https://cdn.example/\(author).jpg"), reactionCount: reactions
    )
}

@MainActor
final class SearchColdStartTests {
    private let folder = StoreFolder()
    private let viewer = ViewerBox()
    /// ONE clock for the store and the screens. The store stamps a list's
    /// `fetchedAt` with its clock and the screen judges freshness with its
    /// own: when the store ran on the real clock and the screens on dates
    /// derived from the suite's start, a runner starved for over 30 s before
    /// the first write made the stored list "from the future", so not fresh
    /// (CI, #1042). Frozen at `start`, every age below is exact.
    private let clock = ManualCacheClock()
    private var start: Date { clock.now }

    /// One launch's cache, over a new store on the same file.
    private func launchCache() throws -> SearchLocalCache {
        let box = viewer
        return SearchLocalCache(store: try LocalStore(directory: folder.url, viewer: { box.viewer }, clock: clock))
    }

    private func open(
        cache: SearchLocalCache, corpus: Corpus, people: People = People(), at now: Date
    ) -> (SearchViewModel, () -> [SearchViewModel.Phase]) {
        let viewModel = SearchViewModel(
            repository: SilentSearch(),
            recentSearches: RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 }),
            explore: corpus,
            metadata: people,
            localCache: cache,
            now: { now }
        )
        var phases: [SearchViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.showExplore()
        return (viewModel, { phases })
    }

    private func trending(_ phases: () -> [SearchViewModel.Phase]) -> TrendingState? {
        for phase in phases().reversed() {
            if case .explore(let model) = phase { return model.trending }
        }
        return nil
    }

    /// A look budget, 6,000 × 10 ms like the other suites' (#1031): a smaller
    /// one ran out on a loaded CI runner before a revalidation's fetch landed.
    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<6_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func corpus() -> Corpus {
        Corpus([post("a", reactions: 1, author: "ada"), post("b", reactions: 99, author: "grace")])
    }

    /// The previous session: Search opened online, its trending people and
    /// their contexts landed and were written.
    private func previousSession() async throws {
        let cache = try launchCache()
        let (viewModel, phases) = open(
            cache: cache, corpus: corpus(), people: People(followed: ["grace"], followers: ["ada": 12]), at: start
        )
        #expect(await settle {
            trending(phases)?.creators.map(\.context) == [.following, .followerCount(12)]
        })
        try #require(trending(phases)?.creators.map(\.context) == [.following, .followerCount(12)])
        cache.waitForPendingWrites()
        withExtendedLifetime(viewModel) {}
    }

    @Test func theTrendingPeopleOpenOnTheirLastListOfflineAfterAColdStart() async throws {
        try await previousSession()

        let offline = corpus()
        offline.offline = true
        // Past the window: the screen asks again, and the network fails.
        let later = start.addingTimeInterval(LocalStorePolicy.trendingRevalidation + 1)
        let people = People(offline: true)
        let (viewModel, phases) = open(cache: try launchCache(), corpus: offline, people: people, at: later)

        // On the first phase, before any await: the people and their contexts.
        guard case .loaded(let creators)? = trending(phases) else {
            Issue.record("the cold start opened on \(String(describing: trending(phases)))")
            return
        }
        #expect(creators.map(\.handle) == ["grace", "ada"])
        #expect(creators.map(\.context) == [.following, .followerCount(12)])
        #expect(creators.first?.avatarURL == URL(string: "https://cdn.example/grace.jpg"))

        #expect(await settle { offline.fetches == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(offline.fetches == 1, "past its window the list revalidates")
        #expect(trending(phases)?.creators.map(\.handle) == ["grace", "ada"], "a failed revalidation took the list away")
        // The rows' failed metadata reads say nothing: the stored contexts stay.
        var looks = 0
        while await people.asked == 0, looks < 6_000 {
            looks += 1
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await people.asked >= 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(trending(phases)?.creators.map(\.context) == [.following, .followerCount(12)], "a failed read blanked the rows")
        withExtendedLifetime(viewModel) {}
    }

    @Test func insideItsWindowTheListIsNotFetchedAgain() async throws {
        try await previousSession()

        let fresh = corpus()
        let soon = start.addingTimeInterval(30)
        let (viewModel, phases) = open(cache: try launchCache(), corpus: fresh, at: soon)
        #expect(trending(phases)?.creators.map(\.handle) == ["grace", "ada"])
        // A "nothing more happens" grace: the skip is decided synchronously
        // in `showExplore`, so a fetch, had one been started, would have
        // reached the corpus by now. It bounds nothing the assertion needs.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fresh.fetches == 0, "a list fetched 30 s ago was fetched again")
        withExtendedLifetime(viewModel) {}
    }

    @Test func pastItsWindowAnAnswerReplacesTheStoredList() async throws {
        try await previousSession()

        let changed = Corpus([post("c", reactions: 500, author: "linus"), post("b", reactions: 99, author: "grace")])
        let later = start.addingTimeInterval(LocalStorePolicy.trendingRevalidation + 1)
        let cache = try launchCache()
        let (viewModel, phases) = open(cache: cache, corpus: changed, at: later)
        #expect(await settle { trending(phases)?.creators.first?.handle == "linus" })
        #expect(trending(phases)?.creators.map(\.handle) == ["linus", "grace"])
        #expect(changed.fetches == 1)

        #expect(await settle { cache.trending()?.creators.first?.handle == "linus" })
        cache.waitForPendingWrites()
        #expect(try launchCache().trending()?.creators.map(\.handle) == ["linus", "grace"])
        withExtendedLifetime(viewModel) {}
    }

    @Test func aFirstLaunchStillShimmersThenStoresTheList() async throws {
        let cache = try launchCache()
        let (viewModel, phases) = open(cache: cache, corpus: corpus(), at: start)
        #expect(phases().first.flatMap { phase -> TrendingState? in
            if case .explore(let model) = phase { return model.trending }
            return nil
        } == .loading)
        #expect(await settle { trending(phases)?.creators.count == 2 })
        cache.waitForPendingWrites()
        #expect(try launchCache().trending()?.creators.map(\.handle) == ["grace", "ada"])
        withExtendedLifetime(viewModel) {}
    }

    @Test func aRecordRoundTripsEveryContext() {
        var creator = ExploreCreator(
            id: ProfileID("p"), displayName: "Pat", handle: "pat", monogram: "P",
            avatarURL: URL(string: "https://cdn.example/p.jpg")
        )
        for context: ProfileRowContext in [.none, .following, .followerCount(7)] {
            creator.context = context
            #expect(SearchLocalCache.Record(creator).creator == creator)
        }
    }

    @Test func anotherViewerOpensOnTheShimmer() async throws {
        try await previousSession()

        viewer.viewer = .member(account: "acct-2", profile: "prof-9")
        let cache = try launchCache()
        #expect(cache.trending() == nil)
        let (viewModel, phases) = open(cache: cache, corpus: corpus(), at: start.addingTimeInterval(5))
        #expect(phases().first.flatMap { phase -> TrendingState? in
            if case .explore(let model) = phase { return model.trending }
            return nil
        } == .loading)
        withExtendedLifetime(viewModel) {}
    }
}
