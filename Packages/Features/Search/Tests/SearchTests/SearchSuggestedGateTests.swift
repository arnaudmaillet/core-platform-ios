import CoreModels
import CoreStorage
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Search

/// Suggested's bones on the kit's timing (#1770): none before the delay,
/// the bones after it, and after 10 s the section goes, as a failed one does.
@MainActor
struct SearchSuggestedGateTests {
    private actor SilentSearch: SearchProviding {
        func searchProfiles(
            matching query: String, sort: SearchSortOrder, limit: Int32
        ) async throws -> [ProfileSearchResult] { [] }
        func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
    }

    /// A trending list that never answers.
    private struct SilentExplore: ExploreProviding {
        func corpus(limit: Int) async throws -> [ExplorePost] {
            try await Task.sleep(for: .seconds(3600))
            return []
        }
    }

    @Test func suggestedBonesFollowTheGate() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        let time = ManualLoadingClock()
        let model = SearchViewModel(
            repository: SilentSearch(),
            recentSearches: RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 }),
            explore: SilentExplore(),
            localCache: nil
        )
        let screen = SearchViewController(
            viewModel: model, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        // Never seen: the fold's bones once they are due.
        screen.presence = SectionPresenceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        screen.skeletonClock = time.clock
        window.rootViewController = UINavigationController(rootViewController: screen)
        screen.loadViewIfNeeded()
        window.layoutIfNeeded()

        #expect(!screen.debugSections.contains(.suggestions), "bones before the delay")
        time.advance(LoadingTiming.skeletonDelay)
        #expect(screen.debugSections.contains(.suggestions))
        time.advance(LoadingTiming.takingLonger)
        #expect(!screen.debugSections.contains(.suggestions), "bones past the long wait")
    }
}
