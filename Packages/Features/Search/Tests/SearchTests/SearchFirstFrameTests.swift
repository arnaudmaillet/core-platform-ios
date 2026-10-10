import CoreModels
import CoreStorage
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Search

/// #827: a refine screen's first frame shows the typeahead for the query it
/// carries, without waiting for `Suggest`.
@MainActor
struct SearchFirstFrameTests {
    /// People search that never answers, and completions that never come.
    private actor SilentProvider: SearchProviding {
        func searchProfiles(
            matching query: String, sort: SearchSortOrder, limit: Int32
        ) async throws -> [ProfileSearchResult] {
            throw CancellationError()
        }

        func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
    }

    /// Runs `body` with a visible window, then takes the window down: emptied,
    /// hidden and laid out, so nothing is left for a later flush to lay out
    /// once the test that owned it is gone.
    private func hosting(_ body: (UIWindow) throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        defer {
            window.rootViewController = nil
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try body(window)
    }

    @Test func aRefineScreensFirstFrameShowsTheTypeaheadForItsQuery() {
        let model = SearchViewModel(
            repository: SilentProvider(),
            recentSearches: RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 }),
            // The remote half of the typeahead never lands in this test:
            // whatever the first frame shows, it did not wait for it.
            suggestDebounce: .seconds(60)
        )
        model.submitQuery("nina")

        hosting { window in
            let refine = SearchViewController(
                viewModel: model, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), mode: .refine
            )
            window.rootViewController = UINavigationController(rootViewController: refine)
            refine.loadViewIfNeeded()
            window.layoutIfNeeded()

            // The history holds the query just submitted, so the typeahead for
            // it has a row — on the first frame, with `Suggest` unanswered.
            #expect(refine.debugSections == [.completions], "got \(refine.debugSections)")
            #expect(!refine.debugItems.isEmpty)
        }
    }
}
