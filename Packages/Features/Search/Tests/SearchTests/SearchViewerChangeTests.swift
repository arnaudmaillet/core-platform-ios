import AuthInterface
import CoreModels
import Foundation
import Synchronization
import Testing
@testable import Search

/// A SEARCH SCREEN STILL PUSHED ACROSS A VIEWER CHANGE REFRESHES (#978).
///
/// What a row says about a person — "Following", and so whether the Following
/// scope keeps them — was read for the viewer who searched. After a profile
/// switch the screen used to keep those answers until it was reopened.
@MainActor
struct SearchViewerChangeTests {
    private actor Provider: SearchProviding {
        func searchProfiles(matching query: String, sort: SearchSortOrder, limit: Int32) async throws -> [ProfileSearchResult] {
            [ProfileSearchResult(id: ProfileID("prof-1"), handle: "ada", displayName: "Ada", isVerified: false)]
        }
        func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
    }

    /// Answers for whichever viewer is "signed in": A follows prof-1, B does not.
    private final class Metadata: ProfileMetadataProviding, @unchecked Sendable {
        let viewer = Mutex("A")
        func metadata(for ids: [ProfileID]) async -> [ProfileID: ProfileRowMetadata] {
            let followed = viewer.withLock { $0 == "A" }
            return Dictionary(uniqueKeysWithValues: ids.map {
                ($0, ProfileRowMetadata(avatarURL: nil, isFollowed: followed, followerCount: nil))
            })
        }
    }

    /// Up to 6 000 looks 10 ms apart: a look budget, not a deadline.
    private func settle(_ done: () -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    private func results(_ phases: [SearchViewModel.Phase]) -> [SearchResultDisplayModel]? {
        for phase in phases.reversed() {
            if case .results(let models) = phase { return models }
        }
        return nil
    }

    @Test func aViewerChangeReadsTheRowsAgainForTheNewViewer() async {
        let center = NotificationCenter()
        let metadata = Metadata()
        let viewModel = SearchViewModel(
            repository: Provider(), metadata: metadata, suggestDebounce: .zero, notificationCenter: center
        )
        var phases: [SearchViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.setScope(.following)

        viewModel.submitQuery("ada")
        #expect(await settle { results(phases)?.map(\.id) == [ProfileID("prof-1")] },
                "guard: A follows prof-1, so the Following scope keeps them")

        // The switch: the metadata repository already answers for B.
        metadata.viewer.withLock { $0 = "B" }
        phases = []
        center.post(name: .viewerDidChange, object: nil)

        #expect(await settle { results(phases)?.isEmpty == true },
                "the pushed screen kept A's Following row for B: \(phases)")
    }

    @Test func theModelStopsHearingViewerChangesWhenItGoes() async {
        let center = NotificationCenter()
        weak var released: SearchViewModel?
        do {
            let viewModel = SearchViewModel(repository: Provider(), notificationCenter: center)
            released = viewModel
        }
        #expect(released == nil, "the observer kept the model alive")
        // Nothing left to call: posting must not reach a freed model.
        center.post(name: .viewerDidChange, object: nil)
    }
}
