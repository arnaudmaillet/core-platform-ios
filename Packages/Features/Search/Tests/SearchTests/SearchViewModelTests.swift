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

    @Test func nonEmptyQueryProducesResults() async {
        let (viewModel, phases) = makeViewModel([result("prof-1", "alice")])

        viewModel.queryChanged("alice")
        try? await Task.sleep(for: .milliseconds(50))

        guard case .results(let models) = phases().last else {
            Issue.record("expected results, got \(String(describing: phases().last))")
            return
        }
        #expect(models.map(\.id) == [ProfileID("prof-1")])
    }

    @Test func matchlessQueryProducesEmpty() async {
        let (viewModel, phases) = makeViewModel([])

        viewModel.queryChanged("zzz")
        try? await Task.sleep(for: .milliseconds(50))

        #expect(phases().last == .empty(query: "zzz"))
    }

    @Test func clearingQueryReturnsToIdle() async {
        let (viewModel, phases) = makeViewModel([result("prof-1", "alice")])

        viewModel.queryChanged("alice")
        try? await Task.sleep(for: .milliseconds(50))
        viewModel.queryChanged("")

        #expect(phases().last == .idle)
    }

    @Test func selectingResultRoutesToProfile() {
        let router = SpyRouter()
        let (viewModel, _) = makeViewModel([], router: router)

        viewModel.didSelectResult(ProfileID("prof-7"))

        #expect(router.routes == [.profile(ProfileID("prof-7"))])
    }
}
