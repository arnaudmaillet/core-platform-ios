import UIKit
import UploadInterface

/// The upload feature's entry point, resolved by the composition root and
/// consumed through `UploadFeatureBuilding` by the app shell. Wraps the
/// compose screen in its own navigation controller for modal presentation.
@MainActor
public struct UploadFeatureBuilder: UploadFeatureBuilding {
    private let composer: any PostComposing

    public init(composer: any PostComposing) {
        self.composer = composer
    }

    public func makeComposeViewController() -> UIViewController {
        let composeVC = ComposeViewController(viewModel: ComposeViewModel(composer: composer))
        let navigation = UINavigationController(rootViewController: composeVC)
        navigation.modalPresentationStyle = .automatic
        return navigation
    }
}
