import CoreModels
import CoreNavigation
import CoreStorage
import Foundation
import Testing
@testable import Search

private actor StubSearchProvider: SearchProviding {
    private let results: [ProfileSearchResult]
    private(set) var lastQuery: String?

    init(results: [ProfileSearchResult]) {
        self.results = results
    }

    func searchProfiles(matching query: String, limit: Int32) async throws -> [ProfileSearchResult] {
        lastQuery = query
        return results
    }

    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
}

@MainActor
private final class SpyRouter: Router {
    private(set) var routes: [AppRoute] = []
    func route(to route: AppRoute) { routes.append(route) }
}

@MainActor
private final class PhaseBox {
    private(set) var phases: [SearchViewModel.Phase] = []
    func append(_ phase: SearchViewModel.Phase) { phases.append(phase) }
}

@MainActor
struct SearchViewModelTests {
    private func result(_ id: String, _ handle: String) -> ProfileSearchResult {
        ProfileSearchResult(id: ProfileID(id), handle: handle, displayName: handle.capitalized, isVerified: false)
    }

    private func makeViewModel(
        _ results: [ProfileSearchResult],
        router: SpyRouter? = nil,
        store: RecentSearchStore? = nil
    ) -> (SearchViewModel, () -> [SearchViewModel.Phase]) {
        let viewModel = SearchViewModel(
            repository: StubSearchProvider(results: results),
            router: router,
            recentSearches: store ?? RecentSearchStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 }
            )
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { box.append($0) }
        return (viewModel, { box.phases })
    }

    /// Waits (bounded) for the async search pipeline to emit a terminal
    /// phase. A fixed 50ms sleep raced the actor hop and flaked repeatedly
    /// on loaded CI runners — the last phase was still `.loading`.
    private func settledPhase(
        _ phases: () -> [SearchViewModel.Phase]
    ) async -> SearchViewModel.Phase? {
        for _ in 0..<500 { // ≤ 5s; terminal phases arrive in ms when healthy
            if let last = phases().last, last != .loading { return last }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return phases().last
    }

    // MARK: - Submitting

    @Test func submittingProducesResults() async {
        let (viewModel, phases) = makeViewModel([result("prof-1", "alice")])

        viewModel.submitQuery("alice")

        guard case .results(let models) = await settledPhase(phases) else {
            Issue.record("expected results, got \(String(describing: phases().last))")
            return
        }
        #expect(models.map(\.id) == [ProfileID("prof-1")])
    }

    @Test func aSubmittedQueryThatMatchesNothingProducesEmpty() async {
        let (viewModel, phases) = makeViewModel([])

        viewModel.submitQuery("zzz")

        #expect(await settledPhase(phases) == .empty(query: "zzz"))
    }

    @Test func submittingBlankTextDoesNothing() async {
        let (viewModel, phases) = makeViewModel([result("prof-1", "alice")])

        viewModel.submitQuery("   ")

        try? await Task.sleep(for: .milliseconds(50))
        #expect(phases().isEmpty)
    }

    // MARK: - Typing does not search

    /// The core of the submit-driven flow: keystrokes narrow the history and
    /// never reach the network.
    @Test func typingNarrowsInsteadOfSearching() async {
        let (viewModel, phases) = makeViewModel([result("prof-1", "alice")])

        viewModel.queryChanged("ali")

        try? await Task.sleep(for: .milliseconds(50))
        guard case .suggesting(let query, _) = phases().last else {
            Issue.record("expected suggesting, got \(String(describing: phases().last))")
            return
        }
        #expect(query == "ali")
        #expect(!phases().contains { if case .results = $0 { return true } else { return false } })
    }

    @Test func typingSurfacesMatchingRecentsOnly() {
        let store = RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 })
        store.recordQuery("alice")
        store.recordQuery("bob")
        let (viewModel, phases) = makeViewModel([], store: store)

        viewModel.queryChanged("ali")

        guard case .suggesting(_, let matches) = phases().last else {
            Issue.record("expected suggesting, got \(String(describing: phases().last))")
            return
        }
        #expect(matches.map(\.text) == ["alice"])
    }

    @Test func clearingTheFieldReturnsToExplore() async {
        let (viewModel, phases) = makeViewModel([result("prof-1", "alice")])

        viewModel.submitQuery("alice")
        _ = await settledPhase(phases)
        viewModel.queryChanged("")

        guard case .explore = phases().last else {
            Issue.record("expected explore, got \(String(describing: phases().last))")
            return
        }
    }

    // MARK: - Routing

    @Test func selectingResultRoutesToProfile() {
        let router = SpyRouter()
        let (viewModel, _) = makeViewModel([], router: router)

        // No results loaded → the route carries no identity stub.
        viewModel.didSelectResult(ProfileID("prof-7"))

        #expect(router.routes == [.profile(ProfileID("prof-7"), stub: nil)])
    }

    @Test func selectingAResultCarriesTheIdentityStub() async {
        let router = SpyRouter()
        let (viewModel, phases) = makeViewModel([result("prof-1", "alice")], router: router)

        viewModel.submitQuery("alice")
        _ = await settledPhase(phases)
        viewModel.didSelectResult(ProfileID("prof-1"))

        // The sigil belongs to the row, never to the stub.
        #expect(router.routes == [
            .profile(ProfileID("prof-1"), stub: ProfileIdentityStub(handle: "alice", displayName: "Alice"))
        ])
    }
}
