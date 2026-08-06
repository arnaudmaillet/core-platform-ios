import CoreModels
import CoreNavigation
import CoreStorage
import Foundation
import Testing
@testable import Search

private actor StubProvider: SearchProviding {
    private let completions: [SearchSuggestion]

    init(completions: [SearchSuggestion] = []) {
        self.completions = completions
    }

    func searchProfiles(matching query: String, limit: Int32) async throws -> [ProfileSearchResult] { [] }
    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { completions }
}

private struct StubExplore: ExploreProviding {
    let posts: [ExplorePost]
    func corpus(limit: Int) async throws -> [ExplorePost] { posts }
}

@MainActor
private final class SpyRouter: Router {
    private(set) var routes: [AppRoute] = []
    func route(to route: AppRoute) { routes.append(route) }
}

/// Tapping a person opens that person — from the Suggestions list, from a
/// completion, and from the history row the first two leave behind.
@MainActor
struct SearchProfileTapTests {
    private func make(
        completions: [SearchSuggestion] = [],
        creators: [ExplorePost] = []
    ) -> (SearchViewModel, RecentSearchStore, SpyRouter, () -> [SearchViewModel.Phase]) {
        let store = RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 })
        let router = SpyRouter()
        let viewModel = SearchViewModel(
            repository: StubProvider(completions: completions),
            router: router,
            recentSearches: store,
            explore: creators.isEmpty ? nil : StubExplore(posts: creators),
            suggestDebounce: .zero
        )
        var phases: [SearchViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        return (viewModel, store, router, { phases })
    }

    /// Waits (bounded) for a condition instead of sleeping a fixed span.
    ///
    /// ⚠️ A 60ms sleep passed alone and failed in the full parallel run: the
    /// completion had not landed yet on a loaded machine. Any test that syncs
    /// on a duration rather than on the thing it is waiting for has this bug —
    /// see the same lesson in `ChatTests`.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func rows(_ phases: () -> [SearchViewModel.Phase]) -> [SearchRowDisplayModel] {
        if case .suggesting(_, let rows) = phases().last { return rows }
        return []
    }

    private func creators(_ phases: () -> [SearchViewModel.Phase]) -> [ExploreCreator] {
        for phase in phases().reversed() {
            if case .explore(let model) = phase { return model.trending.creators }
        }
        return []
    }

    // MARK: - Suggestions list

    @Test func tappingASuggestedPersonOpensThemAndRemembersIt() async {
        let (viewModel, store, router, phases) = make(creators: [
            ExplorePost(
                id: "p1", authorID: ProfileID("prof-1"),
                authorName: "Ada Lovelace", authorHandle: "ada", reactionCount: 5
            )
        ])
        viewModel.showExplore()
        await settle(until: { !creators(phases).isEmpty })

        viewModel.didSelectCreator(ProfileID("prof-1"))

        #expect(router.routes == [
            .profile(ProfileID("prof-1"), stub: ProfileIdentityStub(handle: "ada", displayName: "Ada Lovelace"))
        ])
        #expect(store.recents.map(\.profileID) == ["prof-1"])
        #expect(store.recents.map(\.text) == ["Ada Lovelace"])
    }

    /// ⚠️ The whole point of the change: no search runs, so the viewer never
    /// lands on a results list they then have to tap through.
    @Test func tappingASuggestedPersonRunsNoSearch() async {
        let (viewModel, _, _, phases) = make(creators: [
            ExplorePost(id: "p1", authorID: ProfileID("prof-1"), authorName: "Ada", authorHandle: "ada")
        ])
        viewModel.showExplore()
        await settle(until: { !creators(phases).isEmpty })

        viewModel.didSelectCreator(ProfileID("prof-1"))
        await settle(until: { phases().contains { $0 == .loading } })

        #expect(!phases().contains { $0 == .loading })
        #expect(!phases().contains { if case .results = $0 { return true } else { return false } })
    }

    // MARK: - Completions

    @Test func tappingAProfileCompletionOpensThemAndRemembersIt() async {
        let (viewModel, store, router, phases) = make(completions: [
            SearchSuggestion(text: "ada", kind: .profile, id: "prof-1")
        ])
        viewModel.queryChanged("ad")
        await settle(until: { !rows(phases).isEmpty })

        viewModel.didSelectRow("ada")

        // No display name exists for a completion, so no stub is invented.
        #expect(router.routes == [.profile(ProfileID("prof-1"), stub: nil)])
        #expect(store.recents.map(\.profileID) == ["prof-1"])
        #expect(store.recents.map(\.text) == ["ada"])
    }

    /// A hashtag completion carries no id by contract, so it stays a search.
    @Test func tappingANonProfileCompletionStillSearches() async {
        let (viewModel, store, router, phases) = make(completions: [
            SearchSuggestion(text: "swift", kind: .hashtag, id: "")
        ])
        viewModel.queryChanged("sw")
        await settle(until: { !rows(phases).isEmpty })

        viewModel.didSelectRow("swift")
        // On the PHASE, not on the store: recording is synchronous inside
        // `submitQuery`, so waiting for the entry would return before the
        // search it triggers has emitted anything.
        await settle(until: { phases().contains { $0 == .loading || $0 == .empty(query: "swift") } })

        #expect(router.routes.isEmpty)
        #expect(store.recents.map(\.text) == ["swift"])
        #expect(phases().contains { $0 == .loading || $0 == .empty(query: "swift") })
    }

    /// A profile completion the index answered without an id identifies
    /// nobody — searching is the only honest thing left to do.
    @Test func aProfileCompletionWithoutAnIdFallsBackToSearching() async {
        let (viewModel, _, router, phases) = make(completions: [
            SearchSuggestion(text: "ada", kind: .profile, id: "")
        ])
        viewModel.queryChanged("ad")
        await settle(until: { !rows(phases).isEmpty })

        viewModel.didSelectRow("ada")
        await settle(until: { !phases().isEmpty })

        #expect(router.routes.isEmpty)
    }

    // MARK: - The history row it leaves behind

    @Test func theRememberedPersonOpensDirectlyOnTheNextVisit() async {
        let (viewModel, store, router, phases) = make(creators: [
            ExplorePost(
                id: "p1", authorID: ProfileID("prof-1"),
                authorName: "Ada Lovelace", authorHandle: "ada"
            )
        ])
        viewModel.showExplore()
        await settle(until: { !creators(phases).isEmpty })
        viewModel.didSelectCreator(ProfileID("prof-1"))
        #expect(store.recents.count == 1)

        // Back on the resting screen, the row is now in Recent — and it is a
        // person, not a query.
        viewModel.showExplore()
        viewModel.didSelectRow("profile:prof-1")

        #expect(router.routes.count == 2)
        #expect(router.routes.last == .profile(
            ProfileID("prof-1"), stub: ProfileIdentityStub(handle: "ada", displayName: "Ada Lovelace")
        ))
    }

    @Test func aRememberedQueryStillSearches() async {
        let (viewModel, _, router, phases) = make()
        viewModel.submitQuery("ada")
        await settle(until: { phases().contains { $0 == .empty(query: "ada") } })
        viewModel.showExplore()

        viewModel.didSelectRow("ada")
        await settle(until: { phases().contains { $0 == .empty(query: "ada") } })

        #expect(router.routes.isEmpty)
        #expect(phases().contains { $0 == .loading || $0 == .empty(query: "ada") })
    }
}
