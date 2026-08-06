import CoreNavigation
import CoreStorage
import MediaCore
import SearchInterface
import UIKit

/// The search feature's entry point, resolved by the composition root and
/// consumed through `SearchFeatureBuilding` by the app shell.
@MainActor
public struct SearchFeatureBuilder: SearchFeatureBuilding {
    private let repository: any SearchProviding
    private let recentSearches: RecentSearchStore?
    private let explore: (any ExploreProviding)?
    private let metadata: (any ProfileMetadataProviding)?
    private let imagePipeline: ImagePipeline
    private let router: (any Router)?

    public init(
        repository: any SearchProviding,
        recentSearches: RecentSearchStore? = nil,
        explore: (any ExploreProviding)? = nil,
        metadata: (any ProfileMetadataProviding)? = nil,
        imagePipeline: ImagePipeline,
        router: (any Router)? = nil
    ) {
        self.repository = repository
        self.recentSearches = recentSearches
        self.explore = explore
        self.metadata = metadata
        self.imagePipeline = imagePipeline
        self.router = router
    }

    public func makeSearchViewController() -> UIViewController {
        SearchViewController(
            viewModel: SearchViewModel(
                repository: repository,
                router: router,
                recentSearches: recentSearches,
                explore: explore,
                metadata: metadata
            ),
            imagePipeline: imagePipeline
        )
    }
}
