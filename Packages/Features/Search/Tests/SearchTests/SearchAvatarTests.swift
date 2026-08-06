import CoreModels
import CoreStorage
import DesignSystem
import Foundation
import Testing
@testable import Search

fileprivate actor StubProvider: SearchProviding {
    private let results: [ProfileSearchResult]
    private let completions: [SearchSuggestion]

    init(results: [ProfileSearchResult] = [], completions: [SearchSuggestion] = []) {
        self.results = results
        self.completions = completions
    }

    func searchProfiles(matching query: String, limit: Int32) async throws -> [ProfileSearchResult] { results }
    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { completions }
}

fileprivate actor StubAvatars: ProfileMetadataProviding {
    private let entries: [ProfileID: ProfileRowMetadata]
    private(set) var asked: [[ProfileID]] = []

    init(_ urls: [String: String], followed: Set<String> = [], followers: [String: Int] = [:]) {
        var built: [ProfileID: ProfileRowMetadata] = [:]
        for key in Set(urls.keys).union(followed).union(followers.keys) {
            built[ProfileID(key)] = ProfileRowMetadata(
                avatarURL: urls[key].flatMap(URL.init(string:)),
                isFollowed: followed.contains(key),
                followerCount: followers[key]
            )
        }
        entries = built
    }

    func metadata(for ids: [ProfileID]) async -> [ProfileID: ProfileRowMetadata] {
        asked.append(ids)
        return entries.filter { ids.contains($0.key) }
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
    fileprivate func make(
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
            metadata: avatars,
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

    fileprivate func results(_ phases: () -> [SearchViewModel.Phase]) -> [SearchResultDisplayModel] {
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

/// The trailing context label — what a row says about a person beside their
/// name, and where each surface gets it from.
@MainActor
struct SearchRowContextTests {
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The label itself

    @Test func followingReadsAsFollowing() {
        #expect(ProfileRowContext.following.label == "Following")
    }

    @Test func nothingKnownRendersNoLabelAtAll() {
        // Not an empty string: a row with no context must be exactly as tall
        // as it always was.
        #expect(ProfileRowContext.none.label == nil)
    }

    @Test func followerCountsAreAbbreviated() {
        #expect(ProfileRowContext.followerCount(0).label == "0 followers")
        #expect(ProfileRowContext.followerCount(999).label == "999 followers")
        #expect(ProfileRowContext.followerCount(1_000).label == "1K followers")
        #expect(ProfileRowContext.followerCount(1_240).label == "1.2K followers")
        #expect(ProfileRowContext.followerCount(2_500_000).label == "2.5M followers")
    }

    /// Truncated, not rounded: 1,999 followers is "1.9K", never "2K". The
    /// number must never claim more than the count it came from.
    @Test func abbreviationNeverRoundsUp() {
        #expect(ProfileRowContext.followerCount(1_999).label == "1.9K followers")
        #expect(ProfileRowContext.followerCount(1_099).label == "1K followers")
    }

    // MARK: - Which context a row gets

    @Test func aFollowedPersonSaysFollowingRatherThanTheirCount() async {
        let (viewModel, _, phases) = SearchAvatarTests().make(
            results: [ProfileSearchResult(
                id: ProfileID("prof-1"), handle: "ada", displayName: "Ada", isVerified: false
            )],
            avatars: StubAvatars([:], followed: ["prof-1"], followers: ["prof-1": 4_200])
        )

        viewModel.submitQuery("ada")
        await settle(until: {
            SearchAvatarTests().results(phases).first.map { $0.context != .none } == true
        })

        #expect(SearchAvatarTests().results(phases).map(\.context) == [.following])
    }

    @Test func aStrangerWithAKnownCountSaysTheCount() async {
        let (viewModel, _, phases) = SearchAvatarTests().make(
            results: [ProfileSearchResult(
                id: ProfileID("prof-1"), handle: "ada", displayName: "Ada", isVerified: false
            )],
            avatars: StubAvatars([:], followers: ["prof-1": 4_200])
        )

        viewModel.submitQuery("ada")
        await settle(until: {
            SearchAvatarTests().results(phases).first.map { $0.context != .none } == true
        })

        #expect(SearchAvatarTests().results(phases).map(\.context) == [.followerCount(4_200)])
    }

    /// A person nothing is known about says nothing, rather than "0 followers".
    @Test func aStrangerWithNoKnownCountSaysNothing() async {
        let (viewModel, _, phases) = SearchAvatarTests().make(
            results: [ProfileSearchResult(
                id: ProfileID("prof-1"), handle: "ada", displayName: "Ada", isVerified: false
            )],
            avatars: StubAvatars(["prof-1": "https://example.com/a.jpg"])
        )

        viewModel.submitQuery("ada")
        await settle(until: { SearchAvatarTests().results(phases).first?.avatarURL != nil })

        #expect(SearchAvatarTests().results(phases).map(\.context) == [ProfileRowContext.none])
    }

    /// ⚠️ A suggested creator starts with NO context and is told about like
    /// anyone else.
    ///
    /// This briefly shipped as "everyone in Suggestions is followed, because
    /// the corpus is the following timeline" — and that is false: the mock's
    /// timeline serves every author regardless of the graph, so a person whose
    /// Suggestions row said "Following" came back "3 followers" when searched
    /// for. The relationship is per person, never inherited from the corpus.
    @Test func aSuggestedCreatorClaimsNothingUntilItIsTold() {
        let creator = ExploreCreator(
            id: ProfileID("prof-1"), displayName: "Ada", handle: "ada",
            monogram: "A", avatarURL: nil
        )

        #expect(creator.context == .none)
    }
}
