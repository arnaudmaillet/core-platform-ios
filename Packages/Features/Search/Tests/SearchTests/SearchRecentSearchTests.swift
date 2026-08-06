import CoreModels
import CoreStorage
import Foundation
import Testing
@testable import Search

private actor SilentSearchProvider: SearchProviding {
    func searchProfiles(matching query: String, limit: Int32) async throws -> [ProfileSearchResult] { [] }
    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
}

/// What the view model does with the search history — when it writes to it,
/// what the Recent section shows, and what the row actions do. The store's own
/// rules (de-dupe, caps, the window arithmetic) are pinned in
/// `RecentSearchStoreTests`.
@MainActor
struct SearchRecentSearchTests {
    private func makeViewModel(
        seeded: [String] = []
    ) -> (SearchViewModel, RecentSearchStore, () -> [SearchViewModel.Phase]) {
        let store = RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 })
        for query in seeded { store.recordQuery(query) }
        let viewModel = SearchViewModel(repository: SilentSearchProvider(), recentSearches: store)
        var phases: [SearchViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        return (viewModel, store, { phases })
    }

    private func exploreModel(_ phases: () -> [SearchViewModel.Phase]) -> ExploreDisplayModel? {
        for phase in phases().reversed() {
            if case .explore(let model) = phase { return model }
        }
        return nil
    }

    // MARK: - Recording

    @Test func submittingRecordsTheQuery() {
        let (viewModel, store, _) = makeViewModel()

        viewModel.submitQuery("ada")

        #expect(store.recents.map(\.text) == ["ada"])
    }

    /// The reason `submitQuery` exists at all: typing must leave nothing
    /// behind, or every prefix of every search becomes a row in the history.
    @Test func typingRecordsNothing() async throws {
        let (viewModel, store, _) = makeViewModel()

        for prefix in ["g", "gr", "gra", "grac", "grace"] {
            viewModel.queryChanged(prefix)
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.recents.isEmpty)
    }

    @Test func submittingABlankQueryRecordsNothing() {
        let (viewModel, store, _) = makeViewModel()

        viewModel.submitQuery("   ")

        #expect(store.recents.isEmpty)
    }

    @Test func aViewModelWithNoStoreDoesNotTrapOnSubmit() {
        let viewModel = SearchViewModel(repository: SilentSearchProvider())

        viewModel.submitQuery("ada")
    }

    // MARK: - The Recent section

    @Test func exploreShowsTheHistoryNewestFirst() {
        let (viewModel, _, phases) = makeViewModel(seeded: ["one", "two"])

        viewModel.showExplore()

        #expect(exploreModel(phases)?.recents.map(\.text) == ["two", "one"])
    }

    @Test func aLongHistoryCollapsesAndOffersMore() {
        let seeded = (0..<14).map { "q\($0)" }
        let (viewModel, _, phases) = makeViewModel(seeded: seeded)

        viewModel.showExplore()

        let model = exploreModel(phases)
        #expect(model?.recents.count == RecentSearchStore.collapsedLimit)
        #expect(model?.hiddenRecentCount == 14 - RecentSearchStore.collapsedLimit)
        #expect(model?.showsMoreRecentsRow == true)
    }

    @Test func askingForMoreShowsTheWholeHistory() {
        let (viewModel, _, phases) = makeViewModel(seeded: (0..<14).map { "q\($0)" })
        viewModel.showExplore()

        viewModel.didRequestMoreRecents()

        let model = exploreModel(phases)
        #expect(model?.recents.count == 14)
        #expect(model?.showsMoreRecentsRow == false)
    }

    /// Expansion is sticky: a viewer who asked for the long list should not
    /// have it collapse again behind their back.
    @Test func expansionSurvivesALaterRefresh() {
        let (viewModel, _, phases) = makeViewModel(seeded: (0..<14).map { "q\($0)" })
        viewModel.showExplore()
        viewModel.didRequestMoreRecents()

        viewModel.showExplore()

        #expect(exploreModel(phases)?.recents.count == 14)
    }

    // MARK: - Row actions

    @Test func deletingARowDropsItAndRerendersExplore() {
        let (viewModel, store, phases) = makeViewModel(seeded: ["one", "two"])
        viewModel.showExplore()

        viewModel.didDeleteRecent("two")

        #expect(store.recents.map(\.text) == ["one"])
        #expect(exploreModel(phases)?.recents.map(\.text) == ["one"])
    }

    @Test func clearingEmptiesTheSectionAndCollapsesItAgain() {
        let (viewModel, store, phases) = makeViewModel(seeded: (0..<14).map { "q\($0)" })
        viewModel.showExplore()
        viewModel.didRequestMoreRecents()

        viewModel.didClearRecents()

        #expect(store.recents.isEmpty)
        #expect(exploreModel(phases)?.isEmpty == true)

        // The expansion went with it: a fresh long history collapses again
        // rather than inheriting the cleared list's expanded state.
        for index in 0..<14 { store.recordQuery("r\(index)") }
        viewModel.showExplore()
        #expect(exploreModel(phases)?.recents.count == RecentSearchStore.collapsedLimit)
    }

    @Test func tappingARecentRunsItAndSyncsTheField() async {
        let (viewModel, store, phases) = makeViewModel(seeded: ["ada"])
        var fieldText: String?
        viewModel.onQueryTextChange = { fieldText = $0 }
        viewModel.showExplore()

        viewModel.didSelectRow("ada")

        #expect(fieldText == "ada")
        // It searched: the phase left explore for the search pipeline.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(phases().contains { $0 == .loading || $0 == .empty(query: "ada") })
        // And it stayed in the history rather than being duplicated.
        #expect(store.recents.map(\.text) == ["ada"])
    }

    /// ⚠️ Deleting from the suggestions list on the way to a search must not
    /// throw the viewer back to the resting screen.
    @Test func deletingWhileResultsAreShowingDoesNotReturnToExplore() async {
        let (viewModel, _, phases) = makeViewModel(seeded: ["ada", "grace"])
        viewModel.submitQuery("ada")
        try? await Task.sleep(for: .milliseconds(50))

        viewModel.didDeleteRecent("grace")

        guard case .explore = phases().last else { return }
        Issue.record("deleting a recent row dropped the search results")
    }
}
