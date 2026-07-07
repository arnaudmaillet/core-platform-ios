import CoreMedia
import CoreModels
import ProfileInterface
import UIKit

/// The profile feature's entry point, resolved by the composition root and
/// consumed through `ProfileFeatureBuilding` by the app shell.
@MainActor
public struct ProfileFeatureBuilder: ProfileFeatureBuilding {
    private let repository: any ProfileProviding
    private let imagePipeline: ImagePipeline

    public init(repository: any ProfileProviding, imagePipeline: ImagePipeline) {
        self.repository = repository
        self.imagePipeline = imagePipeline
    }

    public func makeCurrentUserProfileViewController(onLogout: @escaping () -> Void) -> UIViewController {
        ProfileViewController(
            viewModel: ProfileViewModel(repository: repository, source: .currentUser),
            imagePipeline: imagePipeline,
            onLogout: onLogout
        )
    }

    public func makeProfileViewController(for profileID: ProfileID) -> UIViewController {
        ProfileViewController(
            viewModel: ProfileViewModel(repository: repository, source: .profile(profileID)),
            imagePipeline: imagePipeline,
            onLogout: nil
        )
    }
}
