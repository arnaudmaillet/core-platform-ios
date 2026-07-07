import CoreNavigation
import SearchInterface
import UIKit

/// The search feature's entry point, resolved by the composition root and
/// consumed through `SearchFeatureBuilding` by the app shell.
@MainActor
public struct SearchFeatureBuilder: SearchFeatureBuilding {
    private let repository: any SearchProviding
    private let router: (any Router)?

    public init(repository: any SearchProviding, router: (any Router)? = nil) {
        self.repository = repository
        self.router = router
    }

    public func makeSearchViewController() -> UIViewController {
        SearchViewController(
            viewModel: SearchViewModel(repository: repository, router: router)
        )
    }
}
