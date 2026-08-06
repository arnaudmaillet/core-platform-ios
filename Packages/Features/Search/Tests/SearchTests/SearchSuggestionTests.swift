import CoreModels
import CoreStorage
import Foundation
import Testing
@testable import Search

private actor StubSuggestProvider: SearchProviding {
    /// Per-prefix answers, so a test that changes the query gets a different
    /// answer for it — a stub that returned the same list for everything made
    /// "the stale answer was dropped" indistinguishable from "the new answer
    /// happened to look the same".
    private let answers: [String: [SearchSuggestion]]
    private let fallback: [SearchSuggestion]
    private let delay: Duration
    private let error: (any Error)?

    init(
        _ fallback: [SearchSuggestion] = [],
        answers: [String: [SearchSuggestion]] = [:],
        delay: Duration = .zero,
        error: (any Error)? = nil
    ) {
        self.fallback = fallback
        self.answers = answers
        self.delay = delay
        self.error = error
    }

    func searchProfiles(matching query: String, limit: Int32) async throws -> [ProfileSearchResult] { [] }

    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] {
        if delay > .zero { try? await Task.sleep(for: delay) }
        if let error { throw error }
        return answers[prefix] ?? fallback
    }
}

private struct StubError: Error {}

private func suggestion(_ text: String, kind: SearchSuggestion.Kind = .profile) -> SearchSuggestion {
    SearchSuggestion(text: text, kind: kind, id: "id-" + text)
}

/// The typeahead: what reaches the list while the viewer is still typing, in
/// what order, and what happens when the remote half is unavailable.
@MainActor
struct SearchSuggestionTests {
    private func makeViewModel(
        _ provider: StubSuggestProvider,
        seeded: [String] = []
    ) -> (SearchViewModel, () -> [SearchViewModel.Phase]) {
        let store = RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 })
        for query in seeded { store.recordQuery(query) }
        let viewModel = SearchViewModel(
            repository: provider,
            recentSearches: store,
            suggestDebounce: .zero
        )
        var phases: [SearchViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        return (viewModel, { phases })
    }

    private func settledRows(
        _ phases: () -> [SearchViewModel.Phase],
        expecting count: Int
    ) async -> [SearchRowDisplayModel] {
        for _ in 0..<500 {
            if case .suggesting(_, let rows) = phases().last, rows.count == count { return rows }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if case .suggesting(_, let rows) = phases().last { return rows }
        return []
    }

    // MARK: - Merging

    @Test func historyLandsBeforeTheNetworkAnswers() {
        let (viewModel, phases) = makeViewModel(StubSuggestProvider([suggestion("sofia")]), seeded: ["sofa"])

        viewModel.queryChanged("sof")

        // Synchronously — the local half does not wait for the round trip.
        guard case .suggesting(_, let rows) = phases().last else {
            Issue.record("expected suggesting, got \(String(describing: phases().last))")
            return
        }
        #expect(rows.map(\.text) == ["sofa"])
        #expect(rows.map(\.source) == [.history])
    }

    @Test func completionsAreAppendedAfterTheHistory() async {
        let (viewModel, phases) = makeViewModel(
            StubSuggestProvider([suggestion("sofia"), suggestion("sofian")]), seeded: ["sofa"]
        )

        viewModel.queryChanged("sof")

        let rows = await settledRows(phases, expecting: 3)
        #expect(rows.map(\.text) == ["sofa", "sofia", "sofian"])
        #expect(rows.map(\.source) == [.history, .completion, .completion])
    }

    /// A completion the viewer has already searched for is one row, not two —
    /// and it keeps the history's identity, so it keeps its ✕.
    @Test func aCompletionThatDuplicatesHistoryIsDropped() async {
        let (viewModel, phases) = makeViewModel(
            StubSuggestProvider([suggestion("Sofia"), suggestion("sofian")]), seeded: ["sofia"]
        )

        viewModel.queryChanged("sof")

        let rows = await settledRows(phases, expecting: 2)
        #expect(rows.map(\.text) == ["sofia", "sofian"])
        #expect(rows.map(\.source) == [.history, .completion])
    }

    @Test func onlyHistoryRowsCanBeRemoved() async {
        let (viewModel, phases) = makeViewModel(StubSuggestProvider([suggestion("sofia")]), seeded: ["sofa"])

        viewModel.queryChanged("sof")

        let rows = await settledRows(phases, expecting: 2)
        #expect(rows.map(\.isRemovable) == [true, false])
    }

    // MARK: - Robustness

    /// `Suggest` may be unrouted on a given backend, and the viewer is
    /// mid-word — the screen must not complain.
    @Test func aFailedSuggestIsSilentAndLeavesTheHistoryShowing() async {
        let (viewModel, phases) = makeViewModel(
            StubSuggestProvider(error: StubError()), seeded: ["sofa"]
        )

        viewModel.queryChanged("sof")
        try? await Task.sleep(for: .milliseconds(60))

        guard case .suggesting(_, let rows) = phases().last else {
            Issue.record("expected suggesting, got \(String(describing: phases().last))")
            return
        }
        #expect(rows.map(\.text) == ["sofa"])
        #expect(!phases().contains { if case .failed = $0 { return true } else { return false } })
    }

    /// A fetch for a query the viewer has moved on from must not land on the
    /// newer one — the completions for "sof" would otherwise appear under
    /// "zzz", which matches none of them.
    @Test func completionsForASupersededQueryNeverAppear() async {
        let (viewModel, phases) = makeViewModel(StubSuggestProvider(
            answers: ["sof": [suggestion("sofia")], "zzz": []],
            delay: .milliseconds(30)
        ))

        viewModel.queryChanged("sof")
        viewModel.queryChanged("zzz")
        try? await Task.sleep(for: .milliseconds(150))

        guard case .suggesting(let query, let rows) = phases().last else {
            Issue.record("expected suggesting, got \(String(describing: phases().last))")
            return
        }
        #expect(query == "zzz")
        #expect(rows.isEmpty)
    }

    /// Completions that land after Search was pressed must not replace the
    /// results the viewer asked for.
    @Test func completionsDoNotOverwriteSubmittedResults() async {
        let (viewModel, phases) = makeViewModel(StubSuggestProvider([suggestion("sofia")]))

        viewModel.queryChanged("sof")
        viewModel.submitQuery("sof")
        try? await Task.sleep(for: .milliseconds(60))

        #expect(!phases().isEmpty)
        guard case .suggesting = phases().last else { return }
        Issue.record("a late completion replaced the search results")
    }

    // MARK: - Selection

    /// A completion that is not a person runs as a search — the field follows
    /// and the query is recorded. (A completion that IS a person opens them
    /// instead; that lives in `SearchProfileTapTests`.)
    @Test func tappingANonPersonCompletionSearchesForIt() async {
        let (viewModel, phases) = makeViewModel(
            StubSuggestProvider([suggestion("swiftui", kind: .hashtag)])
        )
        var fieldText: String?
        viewModel.onQueryTextChange = { fieldText = $0 }

        viewModel.queryChanged("swi")
        _ = await settledRows(phases, expecting: 1)
        viewModel.didSelectRow("swiftui")

        #expect(fieldText == "swiftui")
        for _ in 0..<500 {
            if phases().contains(where: { $0 == .loading || $0 == .empty(query: "swiftui") }) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(phases().contains { $0 == .loading || $0 == .empty(query: "swiftui") })
    }
}
