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
    /// Files moderation reports from the profile's overflow menu. Optional:
    /// nil hides nothing, but a Report tap then reports the feature as
    /// unavailable rather than silently succeeding.
    private let reporting: (any ProfileReporting)?
    private let gallery: (any ProfileGalleryProviding)?
    /// One store for every profile screen: the gallery filter is a GLOBAL
    /// user preference, so all view models read and write the same place.
    private let galleryPreferences = GalleryPreferences()
    private let imagePipeline: ImagePipeline
    private let router: (any Router)?
    /// Reads the viewer's account for the settings screen (own profile only).
    private let account: (any AccountProviding)?
    /// Multi-profile switching for the account (lists profiles, switches active).
    private let switching: (any ProfileSwitching)?

    public init(
        repository: any ProfileProviding,
        reporting: (any ProfileReporting)? = nil,
        gallery: (any ProfileGalleryProviding)? = nil,
        imagePipeline: ImagePipeline,
        router: (any Router)? = nil,
        account: (any AccountProviding)? = nil,
        switching: (any ProfileSwitching)? = nil
    ) {
        self.repository = repository
        self.reporting = reporting
        self.gallery = gallery
        self.imagePipeline = imagePipeline
        self.router = router
        self.account = account
        self.switching = switching
    }

    private func makeSwitcherFactory() -> ProfileSwitcherMenuFactory? {
        switching.map { ProfileSwitcherMenuFactory(switching: $0, imagePipeline: imagePipeline) }
    }

    public func makeProfileSwitcher() -> ProfileSwitcherPresenting? {
        makeSwitcherFactory()
    }

    public func makeCurrentUserProfileViewController(onLogout: @escaping () -> Void) -> UIViewController {
        let repository = repository
        return ProfileViewController(
            viewModel: ProfileViewModel(
                repository: repository,
                reporting: reporting,
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
            },
            switcherFactory: makeSwitcherFactory()
        )
    }

    public func makeProfileViewController(for profileID: ProfileID, identityStub: ProfileIdentityStub?) -> UIViewController {
        ProfileViewController(
            viewModel: ProfileViewModel(
                repository: repository,
                reporting: reporting,
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
