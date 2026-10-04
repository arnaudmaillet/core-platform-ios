import MediaCore
import CoreModels
import CoreNavigation
import FeedInterface
import MapsInterface
import MediaPlayback
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
    private let reporting: (any ContentReporting)?
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
    /// Lists and ends the account's sessions (Settings → Security and Login).
    /// Nil leaves that section on its coming-soon page.
    private let accountSessions: (any AccountSessionsManaging)?
    /// Active restrictions on the account (Safety → Account Status). Nil
    /// leaves the row under Coming Soon.
    private let accountStatus: (any AccountStatusProviding)?

    public init(
        repository: any ProfileProviding,
        reporting: (any ContentReporting)? = nil,
        shareTargeting: (any ProfileShareTargeting)? = nil,
        gallery: (any ProfileGalleryProviding)? = nil,
        relationships: (any ProfileRelationshipsProviding)? = nil,
        imagePipeline: ImagePipeline,
        router: (any Router)? = nil,
        account: (any AccountProviding)? = nil,
        switching: (any ProfileSwitching)? = nil,
        accountSessions: (any AccountSessionsManaging)? = nil,
        accountStatus: (any AccountStatusProviding)? = nil
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
        self.accountSessions = accountSessions
        self.accountStatus = accountStatus
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
        return { [imagePipeline, router, followEvents] subject, direction in
            ProfileRelationshipsViewController(
                viewModel: ProfileRelationshipsViewModel(
                    subject: subject,
                    repository: relationships,
                    router: router,
                    direction: direction,
                    followEvents: followEvents
                ),
                imagePipeline: imagePipeline
            )
        }
    }

    public func makeGuestSettingsViewController(onSignIn: @escaping () -> Void) -> UIViewController {
        SettingsViewController(
            switching: nil,
            switcher: nil,
            makeDestination: { section in
                switch section {
                case .help:
                    SettingsLinksViewController.help(links: .current)
                case .legal:
                    SettingsLinksViewController.legal(links: .current, version: SettingsLinksViewController.appVersion())
                default:
                    nil
                }
            },
            onLogout: {},
            onSignIn: onSignIn
        )
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
        let controller = ProfileViewController(
            viewModel: ProfileViewModel(
                repository: repository,
                // Harmless here: the pin is never offered on your own profile
                // (you cannot follow yourself), so this is wired for symmetry
                // rather than for a button that could appear.
                mapPinning: mapPinning,
                reporting: reporting,
                gallery: gallery,
                galleryPreferences: galleryPreferences,
                // Own profile only — the Saved tab exists nowhere else, and a
                // store handed to a profile that cannot show one would be a
                // dependency nothing reads.
                bookmarks: bookmarks,
                source: .currentUser,
                router: router,
                cache: cache,
                followEvents: followEvents
            ),
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            shareTargeting: shareTargeting,
            onLogout: onLogout,
            makeEditViewController: { [imagePipeline] profile, onSaved in
                let editor = EditProfileViewController(
                    viewModel: EditProfileViewModel(repository: repository, seed: profile, onSaved: onSaved),
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
                    { [switching, accountSessions, accountStatus, imagePipeline] in
                        SettingsViewController(
                            switching: switching,
                            switcher: makeSwitcherFactory(),
                            makeDestination: { section in
                                switch section {
                                case .account:
                                    AccountSettingsViewController(
                                        account: account,
                                        lifecycle: account as? any AccountLifecycleManaging,
                                        onAccountDeleted: onLogout
                                    )
                                case .security:
                                    accountSessions.map {
                                        SecuritySettingsViewController(
                                            viewModel: SecuritySettingsViewModel(sessions: $0),
                                            onSignedOutEverywhere: onLogout
                                        )
                                    }
                                case .safety:
                                    (repository as? any BlockedAccountsManaging).map { blocks in
                                        var destinations: [SafetySettingsViewController.Destination] = [
                                            .init(title: "Blocked Accounts", symbolName: "nosign") {
                                                BlockedAccountsViewController(
                                                    viewModel: BlockedAccountsViewModel(blocks: blocks),
                                                    imagePipeline: imagePipeline
                                                )
                                            }
                                        ]
                                        if let accountStatus {
                                            destinations.append(.init(title: "Account Status", symbolName: "checkmark.shield") {
                                                AccountStatusViewController(status: accountStatus)
                                            })
                                        }
                                        return SafetySettingsViewController(
                                            destinations: destinations,
                                            planned: ["Muted accounts", "Hidden words and comment filters", "Your reports"]
                                                + (accountStatus == nil ? ["Account status"] : [])
                                                + ["Statements of reasons and appeals"]
                                        )
                                    }
                                case .appPreferences:
                                    AppPreferencesViewController()
                                case .help:
                                    SettingsLinksViewController.help(links: .current)
                                case .legal:
                                    SettingsLinksViewController.legal(links: .current, version: SettingsLinksViewController.appVersion())
                                case .privacy:
                                    if let visibility = repository as? any ProfileVisibilityManaging {
                                        PrivacySectionViewController(
                                            viewModel: PrivacySectionViewModel(visibility: visibility),
                                            makeListPrivacy: { PrivacySettingsViewController(store: RelationshipPrivacyStore()) },
                                            makeDataTransparency: { DataTransparencyViewController() }
                                        )
                                    } else {
                                        PrivacySettingsViewController(store: RelationshipPrivacyStore())
                                    }
                                default: nil
                                }
                            },
                            onLogout: onLogout
                        )
                    }
                }
            },
            switcherFactory: onLogout == nil ? nil : makeSwitcherFactory(),
            makeRelationshipsViewController: makeRelationshipsFactory(),
            identityStub: identityStub,
            trayPlacement: trayPlacement
        )
        controller.feedHero = openFeedHero
        controller.staking = wallet.map(PostCardStaking.init)
        return controller
    }

    /// Flies a tapped gallery post into the unified feed. Set by the
    /// composition root, which is the only place that can see both features.
    /// Nil leaves taps on the plain route — the same feed, without the flight.
    /// The shared player pool, so profile video autoplays on the same terms
    /// as every other surface. Nil leaves profiles as stills.
    /// Curates the map's pinned people, for the header's pin button. Set by
    /// the composition root — the only place that can see both features — and
    /// nil leaves the button unoffered rather than inert.
    public var mapPinning: (any MapProfilePinning)?
    public var videoPlayback: VideoPlaybackController?
    public var openFeedHero: (([PostID], UIViewController, SnapFeedHeroOrigin) -> Void)?
    /// The wallet the gallery cards' like chips stake from — the app's one
    /// instance. Nil leaves the chips counters.
    public var wallet: WalletStore?
    /// The app's one follow-change channel: the header's Follow button and
    /// the followers lists keep agreeing with a follow made anywhere else.
    /// Nil leaves each screen with the answer it loaded.
    public var followEvents: FollowGraphEvents?

    public func makeProfileViewController(for profileID: ProfileID, identityStub: ProfileIdentityStub?) -> UIViewController {
        // Idempotent: the cache hears the follow channel from the first
        // routed profile on (the channel is set after this builder is made).
        cache.observe(followEvents)
        let controller = ProfileViewController(
            viewModel: ProfileViewModel(
                repository: repository,
                mapPinning: mapPinning,
                reporting: reporting,
                gallery: gallery,
                galleryPreferences: galleryPreferences,
                source: .profile(profileID),
                router: router,
                cache: cache,
                followEvents: followEvents
            ),
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            shareTargeting: shareTargeting,
            onLogout: nil,
            makeRelationshipsViewController: makeRelationshipsFactory(),
            identityStub: identityStub
        )
        controller.feedHero = openFeedHero
        controller.staking = wallet.map(PostCardStaking.init)
        return controller
    }

    public func viewerAvatarImage() async -> UIImage? {
        guard let url = (try? await repository.currentUserProfile())?.avatarURL else { return nil }
        return try? await imagePipeline.image(for: url)
    }
}
