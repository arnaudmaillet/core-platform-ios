import CoreModels
import CoreStorage
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Search

/// #827: what the Search screen shows before an answer exists — skeleton rows
/// shaped like the results while a search runs, and the typeahead for the
/// carried query on a refine screen's first frame.
@MainActor
struct SearchFirstFrameTests {
    /// People search held at a gate the test opens; completions never come.
    private actor GatedProvider: SearchProviding {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var held: Int { waiting.count }

        func open() {
            waiting.forEach { $0.resume() }
            waiting = []
        }

        func searchProfiles(
            matching query: String, sort: SearchSortOrder, limit: Int32
        ) async throws -> [ProfileSearchResult] {
            await withCheckedContinuation { waiting.append($0) }
            return [ProfileSearchResult(id: ProfileID("p1"), handle: query, displayName: query, isVerified: false)]
        }

        func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
    }

    private let provider = GatedProvider()
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))

    private func viewModel() -> SearchViewModel {
        SearchViewModel(
            repository: provider,
            recentSearches: RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 }),
            // The remote half of the typeahead never lands in these tests:
            // whatever the first frame shows, it did not wait for it.
            suggestDebounce: .seconds(60)
        )
    }

    private func show(_ screen: SearchViewController) {
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.makeKeyAndVisible()
        screen.loadViewIfNeeded()
        window.layoutIfNeeded()
    }

    /// Polls on state with a look budget, never a deadline.
    private func settle(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func aRunningSearchShowsSkeletonRowsInTheResultsSection() async throws {
        let model = viewModel()
        let screen = SearchViewController(
            viewModel: model, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        show(screen)

        model.submitQuery("nina")
        try #require(await settle { await provider.held == 1 })

        #expect(screen.debugSections == [.results])
        let skeleton = screen.debugItems.allSatisfy {
            if case .resultSkeleton = $0 { true } else { false }
        }
        #expect(!screen.debugItems.isEmpty && skeleton, "got \(screen.debugItems)")
        #expect(!screen.debugStatusIsShowing)

        await provider.open()
        try #require(await settle { screen.debugItems == [.result(ProfileID("p1"))] },
                     "the answer never replaced the skeleton: \(screen.debugItems)")
    }

    @Test func aRefineScreensFirstFrameShowsTheTypeaheadForItsQuery() async throws {
        let model = viewModel()
        model.submitQuery("nina")

        let refine = SearchViewController(
            viewModel: model, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), mode: .refine
        )
        show(refine)

        // The history holds the query just submitted, so the typeahead for it
        // has a row — on the first frame, with `Suggest` still unanswered.
        #expect(refine.debugSections == [.completions], "got \(refine.debugSections)")
        #expect(!refine.debugItems.isEmpty)
        await provider.open()
    }
}
