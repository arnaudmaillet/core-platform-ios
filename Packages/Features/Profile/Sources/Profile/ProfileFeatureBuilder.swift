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
    private let gallery: (any ProfileGalleryProviding)?
    /// One store for every profile screen: the gallery filter is a GLOBAL
    /// user preference, so all view models read and write the same place.
    private let galleryPreferences = GalleryPreferences()
    private let imagePipeline: ImagePipeline
    private let router: (any Router)?
    /// Reads the viewer's account for the settings screen (own profile only).
    private let account: (any AccountProviding)?

    public init(
        repository: any ProfileProviding,
        gallery: (any ProfileGalleryProviding)? = nil,
        imagePipeline: ImagePipeline,
        router: (any Router)? = nil,
        account: (any AccountProviding)? = nil
    ) {
        self.repository = repository
        self.gallery = gallery
        self.imagePipeline = imagePipeline
        self.router = router
        self.account = account
    }

    public func makeCurrentUserProfileViewController(onLogout: @escaping () -> Void) -> UIViewController {
        let repository = repository
        return ProfileViewController(
            viewModel: ProfileViewModel(
                repository: repository,
                gallery: gallery,
                galleryPreferences: galleryPreferences,
                source: .currentUser,
                router: router
            ),
            imagePipeline: imagePipeline,
            onLogout: onLogout,
            makeEditViewController: { [imagePipeline] onSaved in
                EditProfileViewController(
                    viewModel: EditProfileViewModel(repository: repository, onSaved: onSaved),
                    imagePipeline: imagePipeline
                )
            },
            makeSettingsViewController: account.map { account in
                { AccountSettingsViewController(account: account, onLogout: onLogout) }
            }
        )
    }

    public func makeProfileViewController(for profileID: ProfileID, identityStub: ProfileIdentityStub?) -> UIViewController {
        ProfileViewController(
            viewModel: ProfileViewModel(
                repository: repository,
                gallery: gallery,
                galleryPreferences: galleryPreferences,
                source: .profile(profileID),
                router: router
            ),
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
