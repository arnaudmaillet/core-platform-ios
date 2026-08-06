import CoreModels
import CoreNavigation
import CoreStorage
import Foundation
import Testing
@testable import Search

private actor SilentSearchProvider: SearchProviding {
    func searchProfiles(matching query: String, limit: Int32) async throws -> [ProfileSearchResult] { [] }
    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
}

private struct StubExploreProvider: ExploreProviding {
    let posts: [ExplorePost]
    let error: (any Error)?

    init(posts: [ExplorePost] = [], error: (any Error)? = nil) {
        self.posts = posts
        self.error = error
    }

    func corpus(limit: Int) async throws -> [ExplorePost] {
        if let error { throw error }
        return Array(posts.prefix(limit))
    }
}

private struct StubError: Error {}

@MainActor
private final class SpyRouter: Router {
    private(set) var routes: [AppRoute] = []
    func route(to route: AppRoute) { routes.append(route) }
}

private func post(_ id: String, reactions: Int64, author: String) -> ExplorePost {
    ExplorePost(
        id: id,
        authorID: ProfileID(author),
        authorName: author.capitalized,
        authorHandle: author,
        reactionCount: reactions
    )
}

/// How the creators section reaches the screen — the loading lifecycle and the
/// route a row tap emits. The ordering itself is pinned in
/// `ExploreRankingTests`.
@MainActor
struct SearchTrendingTests {
    private func makeViewModel(
        explore: (any ExploreProviding)?,
        router: SpyRouter? = nil
    ) -> (SearchViewModel, () -> [SearchViewModel.Phase]) {
        let viewModel = SearchViewModel(
            repository: SilentSearchProvider(),
            router: router,
            recentSearches: RecentSearchStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 }
            ),
            explore: explore
        )
        var phases: [SearchViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        return (viewModel, { phases })
    }

    private func trending(
        _ phases: () -> [SearchViewModel.Phase]
    ) -> TrendingState? {
        for phase in phases().reversed() {
            if case .explore(let model) = phase { return model.trending }
        }
        return nil
    }

    private func settledTrending(
        _ phases: () -> [SearchViewModel.Phase]
    ) async -> TrendingState? {
        for _ in 0..<500 {
            if let state = trending(phases), state != .loading { return state }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return trending(phases)
    }

    // MARK: - Lifecycle

    @Test func withNoProviderTheSectionIsUnavailableRatherThanEmpty() {
        let (viewModel, phases) = makeViewModel(explore: nil)

        viewModel.showExplore()

        #expect(trending(phases) == .unavailable)
    }

    @Test func theSectionShimmersBeforeItLands() {
        let (viewModel, phases) = makeViewModel(explore: StubExploreProvider())

        viewModel.showExplore()

        // Synchronously, before the fetch can have returned.
        #expect(trending(phases) == .loading)
    }

    @Test func aLoadedCorpusBecomesRankedCreators() async {
        let (viewModel, phases) = makeViewModel(explore: StubExploreProvider(posts: [
            post("a", reactions: 1, author: "ada"),
            post("b", reactions: 99, author: "grace")
        ]))

        viewModel.showExplore()

        guard case .loaded(let creators) = await settledTrending(phases) else {
            Issue.record("expected loaded, got \(String(describing: trending(phases)))")
            return
        }
        #expect(creators.map(\.handle) == ["grace", "ada"])
    }

    /// A failed rail is not worth an error message on a screen whose search
    /// still works — the section simply does not appear.
    @Test func aFailedFetchLeavesTheRestOfTheScreenAlone() async {
        let (viewModel, phases) = makeViewModel(explore: StubExploreProvider(error: StubError()))

        viewModel.showExplore()

        #expect(await settledTrending(phases) == .failed)
        guard case .explore = phases().last else {
            Issue.record("a failed trending fetch should leave the explore phase showing")
            return
        }
    }

    /// Re-fetching on every return to explore would flash the skeleton back
    /// over tiles the viewer was already looking at.
    @Test func theCorpusIsFetchedOncePerScreen() async {
        let (viewModel, phases) = makeViewModel(explore: StubExploreProvider(posts: [
            post("a", reactions: 1, author: "ada")
        ]))
        viewModel.showExplore()
        _ = await settledTrending(phases)

        viewModel.queryChanged("x")
        viewModel.showExplore()

        // Still loaded, never back to loading.
        #expect(trending(phases) != .loading)
        guard case .loaded = trending(phases) else {
            Issue.record("expected the loaded corpus to survive a return to explore")
            return
        }
    }

    // MARK: - Taps

    @Test func tappingACreatorOpensTheProfileWithItsIdentity() async {
        let router = SpyRouter()
        let (viewModel, phases) = makeViewModel(
            explore: StubExploreProvider(posts: [post("a", reactions: 1, author: "ada")]),
            router: router
        )
        viewModel.showExplore()
        _ = await settledTrending(phases)

        viewModel.didSelectCreator(ProfileID("ada"))

        #expect(router.routes == [
            .profile(ProfileID("ada"), stub: ProfileIdentityStub(handle: "ada", displayName: "Ada"))
        ])
    }

    @Test func tappingAnUnknownCreatorStillRoutesWithoutAStub() {
        let router = SpyRouter()
        let (viewModel, _) = makeViewModel(explore: StubExploreProvider(), router: router)

        viewModel.didSelectCreator(ProfileID("nobody"))

        #expect(router.routes == [.profile(ProfileID("nobody"), stub: nil)])
    }
}
