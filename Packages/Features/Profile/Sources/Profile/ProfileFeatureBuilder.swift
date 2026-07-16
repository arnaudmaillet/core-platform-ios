import MediaCore
import CoreModels
import CoreNavigation
import ProfileInterface
import UIKit

/// The profile feature's entry point, resolved by the composition root and
/// consumed through `ProfileFeatureBuilding` by the app shell.
@MainActor
public struct ProfileFeatureBuilder: ProfileFeatureBuilding {
    private let repository: any ProfileProviding
    private let imagePipeline: ImagePipeline
    private let router: (any Router)?

    public init(repository: any ProfileProviding, imagePipeline: ImagePipeline, router: (any Router)? = nil) {
        self.repository = repository
        self.imagePipeline = imagePipeline
        self.router = router
    }

    public func makeCurrentUserProfileViewController(onLogout: @escaping () -> Void) -> UIViewController {
        let repository = repository
        return ProfileViewController(
            viewModel: ProfileViewModel(repository: repository, source: .currentUser),
            imagePipeline: imagePipeline,
            onLogout: onLogout,
            makeEditViewController: { onSaved in
                EditProfileViewController(
                    viewModel: EditProfileViewModel(repository: repository, onSaved: onSaved)
                )
            }
        )
    }

    public func makeProfileViewController(for profileID: ProfileID, identityStub: ProfileIdentityStub?) -> UIViewController {
        ProfileViewController(
            viewModel: ProfileViewModel(repository: repository, source: .profile(profileID), router: router),
            imagePipeline: imagePipeline,
            onLogout: nil,
            identityStub: identityStub
        )
    }

    public func viewerAvatarImage() async -> UIImage? {
        guard let url = (try? await repository.currentUserProfile())?.avatarURL else { return nil }
        return try? await imagePipeline.image(for: url)
    }
}
