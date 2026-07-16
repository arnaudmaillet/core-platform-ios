import CoreModels
import CoreNavigation
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
        router: SpyRouter? = nil
    ) -> (SearchViewModel, () -> [SearchViewModel.Phase]) {
        let viewModel = SearchViewModel(
            repository: StubSearchProvider(results: results),
            router: router,
            debounce: .zero
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

    @Test func nonEmptyQueryProducesResults() async {
        let (viewModel, phases) = makeViewModel([result("prof-1", "alice")])

        viewModel.queryChanged("alice")

        guard case .results(let models) = await settledPhase(phases) else {
            Issue.record("expected results, got \(String(describing: phases().last))")
            return
        }
        #expect(models.map(\.id) == [ProfileID("prof-1")])
    }

    @Test func matchlessQueryProducesEmpty() async {
        let (viewModel, phases) = makeViewModel([])

        viewModel.queryChanged("zzz")

        #expect(await settledPhase(phases) == .empty(query: "zzz"))
    }

    @Test func clearingQueryReturnsToIdle() async {
        let (viewModel, phases) = makeViewModel([result("prof-1", "alice")])

        viewModel.queryChanged("alice")
        _ = await settledPhase(phases) // let the first query land first
        viewModel.queryChanged("")

        #expect(phases().last == .idle)
    }

    @Test func selectingResultRoutesToProfile() {
        let router = SpyRouter()
        let (viewModel, _) = makeViewModel([], router: router)

        // No results loaded → the route carries no identity stub.
        viewModel.didSelectResult(ProfileID("prof-7"))

        #expect(router.routes == [.profile(ProfileID("prof-7"), stub: nil)])
    }
}
