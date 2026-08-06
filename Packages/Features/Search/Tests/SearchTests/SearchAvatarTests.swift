import CoreModels
import CoreStorage
import Foundation
import Testing
@testable import Search

private actor StubProvider: SearchProviding {
    private let results: [ProfileSearchResult]
    private let completions: [SearchSuggestion]

    init(results: [ProfileSearchResult] = [], completions: [SearchSuggestion] = []) {
        self.results = results
        self.completions = completions
    }

    func searchProfiles(matching query: String, limit: Int32) async throws -> [ProfileSearchResult] { results }
    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { completions }
}

private actor StubAvatars: ProfileAvatarProviding {
    private let urls: [ProfileID: URL]
    private(set) var asked: [[ProfileID]] = []

    init(_ urls: [String: String]) {
        self.urls = Dictionary(uniqueKeysWithValues: urls.map { (ProfileID($0.key), URL(string: $0.value)!) })
    }

    func avatarURLs(for ids: [ProfileID]) async -> [ProfileID: URL] {
        asked.append(ids)
        return urls.filter { ids.contains($0.key) }
    }

    func requests() -> [[ProfileID]] { asked }
}

/// Every `.person` row shows a picture when the person has one, whichever list
/// it appears in.
///
/// These exist because the three lists get their people from three different
/// reads and only one of them carries an avatar: `search.v1` answers with a
/// storage key nothing resolves, `Suggest` answers with no image at all, and
/// only the timeline behind Suggestions hydrates through `profile.v1`. So two
/// of the three surfaces rendered initials forever, which looked like a UI bug
/// and was a data one.
@MainActor
struct SearchAvatarTests {
    private func make(
        results: [ProfileSearchResult] = [],
        completions: [SearchSuggestion] = [],
        avatars: StubAvatars,
        seeded: [RecentSearch] = []
    ) -> (SearchViewModel, RecentSearchStore, () -> [SearchViewModel.Phase]) {
        let store = RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 })
        for entry in seeded { store.record(entry) }
        let viewModel = SearchViewModel(
            repository: StubProvider(results: results, completions: completions),
            recentSearches: store,
            avatars: avatars,
            suggestDebounce: .zero
        )
        var phases: [SearchViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        return (viewModel, store, { phases })
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func recents(_ phases: () -> [SearchViewModel.Phase]) -> [SearchRowDisplayModel] {
        for phase in phases().reversed() {
            if case .explore(let model) = phase { return model.recents }
        }
        return []
    }

    private func results(_ phases: () -> [SearchViewModel.Phase]) -> [SearchResultDisplayModel] {
        for phase in phases().reversed() {
            if case .results(let models) = phase { return models }
        }
        return []
    }

    // MARK: - Results

    @Test func aSearchResultGetsItsAvatarResolved() async {
        let (viewModel, _, phases) = make(
            results: [ProfileSearchResult(
                id: ProfileID("prof-1"), handle: "ada", displayName: "Ada", isVerified: false
            )],
            avatars: StubAvatars(["prof-1": "https://example.com/ada.jpg"])
        )

        viewModel.submitQuery("ada")
        await settle(until: { results(phases).first?.avatarURL != nil })

        #expect(results(phases).map(\.avatarURL) == [URL(string: "https://example.com/ada.jpg")])
    }

    // MARK: - Completions

    @Test func aProfileCompletionGetsItsAvatarResolved() async {
        let (viewModel, _, phases) = make(
            completions: [SearchSuggestion(text: "ada", kind: .profile, id: "prof-1")],
            avatars: StubAvatars(["prof-1": "https://example.com/ada.jpg"])
        )

        viewModel.queryChanged("ad")
        await settle(until: {
            if case .suggesting(_, let rows) = phases().last { return rows.first?.avatarURL != nil }
            return false
        })

        guard case .suggesting(_, let rows) = phases().last else {
            Issue.record("expected suggesting")
            return
        }
        #expect(rows.map(\.avatarURL) == [URL(string: "https://example.com/ada.jpg")])
    }

    // MARK: - Recents

    /// A remembered person recorded WITHOUT a picture (from a completion, say)
    /// still gets one on the next visit rather than staying on initials.
    @Test func aRememberedPersonWithNoStoredPictureIsResolved() async throws {
        let entry = try #require(RecentSearch.profile(
            id: "prof-1", displayName: "Ada", handle: "ada", searchedAtMS: 1
        ))
        let (viewModel, _, phases) = make(
            avatars: StubAvatars(["prof-1": "https://example.com/ada.jpg"]), seeded: [entry]
        )

        viewModel.showExplore()
        await settle(until: { recents(phases).first?.avatarURL != nil })

        #expect(recents(phases).map(\.avatarURL) == [URL(string: "https://example.com/ada.jpg")])
    }

    /// ⚠️ The regression that started this: re-recording the same person from
    /// a thinner source must not erase the picture already stored for them.
    @Test func reRecordingAPersonNeverErasesTheirStoredPicture() throws {
        let store = RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 })
        store.recordProfile(
            id: "prof-1", displayName: "Ada Lovelace", handle: "ada",
            avatarURL: "https://example.com/ada.jpg"
        )

        // The completion route knows a handle and an id and nothing else.
        store.recordProfile(id: "prof-1", displayName: "ada", handle: "ada", avatarURL: nil)

        let entry = try #require(store.recents.first)
        #expect(store.recents.count == 1)
        #expect(entry.avatarURL == "https://example.com/ada.jpg")
    }

    // MARK: - Cost

    /// Only what is on screen, and only once. The resolver is an N+1 read, so
    /// a second sighting of the same person must not spend another request.
    @Test func aPersonIsOnlyAskedAboutOnce() async {
        let avatars = StubAvatars(["prof-1": "https://example.com/ada.jpg"])
        let (viewModel, _, phases) = make(
            results: [ProfileSearchResult(
                id: ProfileID("prof-1"), handle: "ada", displayName: "Ada", isVerified: false
            )],
            avatars: avatars
        )

        viewModel.submitQuery("ada")
        await settle(until: { results(phases).first?.avatarURL != nil })
        viewModel.submitQuery("ada")
        await settle(until: { results(phases).first?.avatarURL != nil })

        // The second search found the picture already in hand and asked for
        // nothing — the request list never grew a second non-empty entry.
        let nonEmpty = await avatars.requests().filter { !$0.isEmpty }
        #expect(nonEmpty.count == 1)
    }
}
