import MediaCore
import CoreModels
import CoreNavigation
import CoreStorage
import PostGrid
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
    /// Supplies the share sheet's quick-send row. Nil simply hides the row.
    private let shareTargeting: (any ProfileShareTargeting)?
    private let gallery: (any ProfileGalleryProviding)?
    /// Serves the followers / following lists. Nil leaves the header's
    /// counters inert — the screen is a destination, not a decoration, and a
    /// tap that opens an unfillable list is worse than no tap.
    private let relationships: (any ProfileRelationshipsProviding)?
    /// One store for every profile screen: the gallery filter is a GLOBAL
    /// user preference, so all view models read and write the same place.
    private let galleryPreferences = GalleryPreferences()
    /// The viewer's saved pile. Built here rather than injected because there is
    /// nothing to inject it from: no service owns this list, so the device is
    /// the only place it has ever lived. See `PostBookmarkStore`.
    private let bookmarks = PostBookmarkStore()
    /// Last-known profiles, shared by every profile screen so a switch to one
    /// already seen renders instantly. One per app, like the preferences.
    private let cache = ProfileCache()
    private let imagePipeline: ImagePipeline
    private let router: (any Router)?
    /// Reads the viewer's account for the settings screen (own profile only).
    private let account: (any AccountProviding)?
    /// Multi-profile switching for the account (lists profiles, switches active).
    private let switching: (any ProfileSwitching)?

    public init(
        repository: any ProfileProviding,
        reporting: (any ProfileReporting)? = nil,
        shareTargeting: (any ProfileShareTargeting)? = nil,
        gallery: (any ProfileGalleryProviding)? = nil,
        relationships: (any ProfileRelationshipsProviding)? = nil,
        imagePipeline: ImagePipeline,
        router: (any Router)? = nil,
        account: (any AccountProviding)? = nil,
        switching: (any ProfileSwitching)? = nil
    ) {
        self.repository = repository
        self.reporting = reporting
        self.shareTargeting = shareTargeting
        self.gallery = gallery
        self.relationships = relationships
        self.imagePipeline = imagePipeline
        self.router = router
        self.account = account
        self.switching = switching
    }

    private func makeSwitcherFactory() -> ProfileSwitcherMenuFactory? {
        switching.map { ProfileSwitcherMenuFactory(switching: $0, imagePipeline: imagePipeline) }
    }

    /// The counter row's destination, shared by both profile entry points —
    /// the viewer's own profile and any routed-to one — so the two can't drift.
    private func makeRelationshipsFactory() -> (
        (ProfileRelationshipsViewModel.Subject, RelationshipDirection) -> UIViewController
    )? {
        guard let relationships else { return nil }
        return { [imagePipeline, router] subject, direction in
            ProfileRelationshipsViewController(
                viewModel: ProfileRelationshipsViewModel(
                    subject: subject,
                    repository: relationships,
                    router: router,
                    direction: direction
                ),
                imagePipeline: imagePipeline
            )
        }
    }

    public func makeProfileSwitcher() -> ProfileSwitcherPresenting? {
        makeSwitcherFactory()
    }

    public func makeCurrentUserProfileViewController(
        onLogout: (() -> Void)?,
        identityStub: ProfileIdentityStub?,
        trayPlacement: ProfileTrayPlacement
    ) -> UIViewController {
        let repository = repository
        return ProfileViewController(
            viewModel: ProfileViewModel(
                repository: repository,
                reporting: reporting,
                gallery: gallery,
                galleryPreferences: galleryPreferences,
                // Own profile only — the Saved tab exists nowhere else, and a
                // store handed to a profile that cannot show one would be a
                // dependency nothing reads.
                bookmarks: bookmarks,
                source: .currentUser,
                router: router,
                cache: cache
            ),
            imagePipeline: imagePipeline,
            shareTargeting: shareTargeting,
            onLogout: onLogout,
            makeEditViewController: { [imagePipeline] onSaved in
                let editor = EditProfileViewController(
                    viewModel: EditProfileViewModel(repository: repository, onSaved: onSaved),
                    imagePipeline: imagePipeline
                )
                editor.onOpenPrivacy = { [weak editor] in
                    editor?.navigationController?.pushViewController(
                        PrivacySettingsViewController(store: RelationshipPrivacyStore()), animated: true
                    )
                }
                return editor
            },
            // Both are account management, so both ride on `onLogout`: a
            // routed arrival gets the profile without the global actions. Edit
            // Profile is deliberately NOT gated — editing your own bio is a
            // profile action, and it is safe at any stack depth.
            makeSettingsViewController: onLogout.flatMap { onLogout in
                account.map { account in
                    { AccountSettingsViewController(account: account, onLogout: onLogout) }
                }
            },
            switcherFactory: onLogout == nil ? nil : makeSwitcherFactory(),
            makeRelationshipsViewController: makeRelationshipsFactory(),
            identityStub: identityStub,
            trayPlacement: trayPlacement
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
                router: router,
                cache: cache
            ),
            imagePipeline: imagePipeline,
            shareTargeting: shareTargeting,
            onLogout: nil,
            makeRelationshipsViewController: makeRelationshipsFactory(),
            identityStub: identityStub
        )
    }

    public func viewerAvatarImage() async -> UIImage? {
        guard let url = (try? await repository.currentUserProfile())?.avatarURL else { return nil }
        return try? await imagePipeline.image(for: url)
    }
}
