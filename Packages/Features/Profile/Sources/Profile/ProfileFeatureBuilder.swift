import AuthInterface
import CacheKit
import MediaCore
import CoreModels
import CoreNavigation
import FeedInterface
import LocalStore
import MapsInterface
import MediaPlayback
import CoreStorage
import DesignSystem
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
    /// The viewer's saved pile: the app's one, a view over the EntityStore's
    /// saved fact (#896), so a save made in a feed is on the gallery's cards.
    /// See `PostBookmarkStore`.
    private let bookmarks = PostBookmarkStore.shared
    /// Last-known profiles, shared by every profile screen so a switch to one
    /// already seen renders instantly. One per app, like the preferences;
    /// backed by the device store when the app hands one in (#893).
    private let cache: ProfileCache
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
    /// Push preferences (Settings → Notifications, #392). Nil leaves the
    /// section on its coming-soon page.
    private let notificationPreferences: (any NotificationPreferencesManaging)?

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
        accountStatus: (any AccountStatusProviding)? = nil,
        notificationPreferences: (any NotificationPreferencesManaging)? = nil,
        /// The device store (#893): the viewer's own profile and the profiles
        /// they visited open on their last content at a cold start. Nil keeps
        /// the profile cache in memory.
        localStore: LocalStore? = nil
    ) {
        self.cache = ProfileCache(store: localStore)
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
        self.notificationPreferences = notificationPreferences
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

    /// A family supervision invite opened from a link (#417): the code filled
    /// in, nothing linked until the viewer taps Link. Once linked, the screen
    /// steps back and says so. Nil when the account can't take one.
    /// Family and Teens from a supervision notification (#1106): the same
    /// page Settings opens, which then opens the link with `otherAccountID`
    /// if it still exists. Reached outside Settings, its protection rows
    /// open nothing (there is no Settings stack to open them in).
    public func makeFamilyAndTeensViewController(openingSupervisionWith otherAccountID: String?) -> UIViewController? {
        guard let account else { return nil }
        let page = FamilyAndTeensViewController(
            isTeen: { try await account.currentAccount().ageBracket.isTeen },
            supervision: account as? any SupervisionManaging,
            imagePipeline: imagePipeline,
            router: router
        )
        page.pendingSupervisionAccountID = otherAccountID
        return page
    }

    public func makeSupervisionAcceptViewController(code: String) -> UIViewController? {
        guard let account, let manager = account as? any SupervisionManaging else { return nil }
        return SupervisionAcceptViewController(
            model: SupervisionAcceptModel(manager: manager, code: code),
            resolveTeen: { try await account.currentAccount().ageBracket.isTeen }
        ) { accept, link in
            let navigation = accept.navigationController
            navigation?.popViewController(animated: true)
            if let landing = navigation?.topViewController ?? navigation {
                Feedback.success(SupervisionCopy.linkedToast(link), from: landing)
            }
        }
    }

    public func makeGuestSettingsViewController(onSignIn: @escaping () -> Void) -> UIViewController {
        SettingsViewController(
            switching: nil,
            switcher: nil,
            makeDestination: { section in
                switch section {
                // Device settings need no account: a guest's choices stay on
                // this iPhone like anyone's (#468).
                case .playback, .display, .emojis, .mediaComments, .language:
                    AppPreferencesViewController(page: section)
                case .storage:
                    makeStorageSettings()
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
                // The History tab's pile (#1344): the own profile's only.
                viewHistory: .shared,
                source: .currentUser,
                router: router,
                cache: cache,
                followEvents: followEvents,
                shareLinks: repository as? any ShareLinkManaging,
                postDeleted: onPostDeleted
            ),
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            makeGridPage: gridPageFactory,
            shareTargeting: shareTargeting,
            onLogout: onLogout,
            makeEditViewController: { [imagePipeline] profile, onSaved in
                let editor = EditProfileViewController(
                    viewModel: EditProfileViewModel(repository: repository, seed: profile, onSaved: onSaved),
                    imagePipeline: imagePipeline
                )
                if let types = repository as? any AccountTypeManaging {
                    editor.onOpenAccountType = { [weak editor] in
                        editor?.navigationController?.pushViewController(
                            AccountTypeViewController(manager: types, verifier: repository as? any VerificationRequesting),
                            animated: true
                        )
                    }
                }
                if let lists = repository as? any ListPrivacyManaging {
                    editor.onOpenPrivacy = { [weak editor] in
                        editor?.navigationController?.pushViewController(
                            ListPrivacyViewController(manager: lists), animated: true
                        )
                    }
                }
                return editor
            },
            // Both are account management, so both ride on `onLogout`: a
            // routed arrival gets the profile without the global actions. Edit
            // Profile is deliberately NOT gated — editing your own bio is a
            // profile action, and it is safe at any stack depth.
            makeSettingsViewController: onLogout.flatMap { onLogout in
                account.map { account in
                    { [switching, accountSessions, accountStatus, reporting, gallery, notificationPreferences, imagePipeline,
                       makeWalletSection = self.makeWalletSection] in
                        SettingsViewController(
                            switching: switching,
                            switcher: makeSwitcherFactory(),
                            makeDestination: { section in
                                switch section {
                                case .account:
                                    AccountSettingsViewController(
                                        account: account,
                                        lifecycle: account as? any AccountLifecycleManaging,
                                        onAccountDeleted: onLogout,
                                        deactivator: account as? any AccountDeactivating,
                                        stepUp: accountSessions as? any CredentialStepUp,
                                        contactChanger: accountSessions as? any ContactChanging,
                                        onDeactivated: onLogout,
                                        deletionChecklist: deletionChecklist
                                    )
                                case .security:
                                    accountSessions.map { sessions in
                                        SecuritySettingsViewController(
                                            viewModel: SecuritySettingsViewModel(sessions: sessions),
                                            onSignedOutEverywhere: onLogout,
                                            makeCheckup: {
                                                SecurityCheckupViewController(
                                                    account: account, sessions: sessions, authenticator: DeviceAuthenticator()
                                                )
                                            },
                                            makeTwoStep: (sessions as? any TwoStepManaging & CredentialStepUp).map { twoStep in
                                                { TwoStepViewController(account: account, manager: twoStep, stepUp: twoStep) }
                                            },
                                            makePasskeys: (sessions as? any PasskeysManaging & CredentialStepUp).map { passkeys in
                                                { [makePasskeyAuthorizer] in
                                                    PasskeysViewController(
                                                        model: PasskeysModel(manager: passkeys, authorizer: makePasskeyAuthorizer()),
                                                        stepUp: passkeys,
                                                        passkeyStepUp: passkeys as? any PasskeyStepUp
                                                    )
                                                }
                                            },
                                            passkeysAvailable: (sessions as? any PasskeysManaging).map { passkeys in
                                                { await passkeys.passkeysAvailable() }
                                            },
                                            makeAuthorizedApps: (sessions as? any AuthorizedAppsManaging).map { apps in
                                                { [imagePipeline] in
                                                    AuthorizedAppsViewController(
                                                        viewModel: AuthorizedAppsViewModel(manager: apps),
                                                        imagePipeline: imagePipeline
                                                    )
                                                }
                                            }
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
                                        let muting = repository as? any ProfileMuting
                                        if let muting {
                                            destinations.append(.init(title: "Muted Accounts", symbolName: "speaker.slash") {
                                                MutedAccountsViewController(
                                                    viewModel: MutedAccountsViewModel(muting: muting),
                                                    imagePipeline: imagePipeline
                                                )
                                            })
                                        }
                                        if let restricting = repository as? any ProfileRestricting {
                                            destinations.append(.init(title: "Restricted Accounts", symbolName: "person.crop.circle.badge.minus") {
                                                RestrictedAccountsViewController(
                                                    viewModel: RestrictedAccountsViewModel(restricting: restricting),
                                                    imagePipeline: imagePipeline
                                                )
                                            })
                                        }
                                        if let limits = repository as? any InteractionLimitsManaging {
                                            destinations.append(.init(title: "Limits", symbolName: "hand.raised") {
                                                LimitInteractionsViewController(manager: limits)
                                            })
                                        }
                                        let filters = repository as? any CommentFiltersManaging
                                        if let filters {
                                            destinations.append(.init(title: "Hidden Words", symbolName: "text.badge.xmark") {
                                                HiddenWordsViewController(manager: filters)
                                            })
                                        }
                                        if let accountStatus {
                                            destinations.append(.init(title: "Account Status", symbolName: "checkmark.shield") {
                                                AccountStatusViewController(
                                                    status: accountStatus,
                                                    reviewer: accountStatus as? any ModerationDecisionReviewing
                                                )
                                            })
                                        }
                                        // The repository that files reports lists them back.
                                        let history = reporting as? any ReportHistoryProviding
                                        if let history {
                                            destinations.append(.init(title: "Your Reports", symbolName: "flag") {
                                                YourReportsViewController(
                                                    history: history,
                                                    appeals: accountStatus as? any ModerationDecisionReviewing
                                                )
                                            })
                                        }
                                        return SafetySettingsViewController(
                                            destinations: destinations,
                                            planned: (muting == nil ? ["Muted accounts"] : [])
                                                + (filters == nil ? ["Hidden words and comment filters"] : [])
                                                + (history == nil ? ["Your reports"] : [])
                                                + (accountStatus == nil ? ["Account status"] : [])
                                        )
                                    }
                                case .notifications:
                                    notificationPreferences.map { NotificationSettingsViewController(manager: $0) }
                                case .activity:
                                    YourActivityViewController(makeRecentlyDeleted: {
                                        guard let trash = gallery as? any PostTrashManaging,
                                              let viewer = repository as? any ProfileViewerResolving else { return nil }
                                        return {
                                            RecentlyDeletedViewController(
                                                viewModel: RecentlyDeletedViewModel(
                                                    trash: trash, viewer: viewer,
                                                    // A restored post is back in the author's gallery: a
                                                    // revisit must not open on the pages without it (#887).
                                                    onRestored: { [cache] author in cache.removeGallery(for: author) },
                                                    onPostRestored: onPostRestored
                                                ),
                                                imagePipeline: imagePipeline
                                            )
                                        }
                                    }())
                                case .adsAndData:
                                    (account as? any AccountConsentManaging).map { manager in
                                        ConsentsViewController(manager: manager, makeDeleteAccount: {
                                            (account as? any AccountLifecycleManaging).map { lifecycle in
                                                DeleteAccountViewController(
                                                    viewModel: DeleteAccountViewModel(lifecycle: lifecycle, checklist: deletionChecklist),
                                                    onAccountDeleted: onLogout,
                                                    stepUp: accountSessions as? any CredentialStepUp,
                                                    canceller: lifecycle as? any AccountDeletionCancelling
                                                )
                                            }
                                        })
                                    }
                                case .playback, .display, .emojis, .mediaComments, .language:
                                    AppPreferencesViewController(page: section)
                                case .storage:
                                    makeStorageSettings()
                                case .help:
                                    SettingsLinksViewController.help(links: .current)
                                case .legal:
                                    SettingsLinksViewController.legal(links: .current, version: SettingsLinksViewController.appVersion())
                                case .privacy:
                                    (repository as? any ProfileVisibilityManaging).map { visibility in
                                        PrivacySectionViewController(
                                            viewModel: PrivacySectionViewModel(
                                                visibility: visibility,
                                                requests: repository as? any FollowRequestsManaging,
                                                windows: repository as? any PostWindowManaging,
                                                comments: repository as? any CommentAudienceManaging,
                                                sharing: repository as? any PostSharingManaging,
                                                audiences: repository as? any InteractionAudienceManaging,
                                                tabs: repository as? any ProfileTabVisibilityManaging
                                            ),
                                            makeListPrivacy: (repository as? any ListPrivacyManaging).map { lists in
                                                { ListPrivacyViewController(manager: lists) }
                                            },
                                            makeDataTransparency: { DataTransparencyViewController() },
                                            makeActivityDiscovery: (repository as? any ActivityDiscoveryManaging).map { manager in
                                                { ActivityDiscoveryViewController(manager: manager, shareLinks: repository as? any ShareLinkManaging) }
                                            },
                                            makeLocationSharing: (repository as? any LocationSharingManaging).map { manager in
                                                { LocationSharingViewController(manager: manager) }
                                            },
                                            imagePipeline: imagePipeline
                                        )
                                    }
                                case .familyAndTeens:
                                    // Throws on a failed read: never "adult" by default (#799).
                                    FamilyAndTeensViewController(
                                        isTeen: { try await account.currentAccount().ageBracket.isTeen },
                                        // Parental Supervision (#417).
                                        supervision: account as? any SupervisionManaging,
                                        imagePipeline: imagePipeline,
                                        router: router
                                    )
                                case .whatYouSee:
                                    (repository as? any FeedPreferencesManaging).map { preferences in
                                        WhatYouSeeViewController(preferences: preferences, interestTags: interestTags, isTeen: {
                                            try await account.currentAccount().ageBracket.isTeen
                                        })
                                    }
                                // The wallet's history (#400): the app's screen,
                                // which reads the server wallet.
                                case .wallet:
                                    makeWalletSection?()
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
        controller.staking = makeCardStaking?() ?? wallet.map(PostCardStaking.init)
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
    /// For You's grid page, built by the composition root (#1273): the pages
    /// the profile's posts are drawn on. `savesPosts` offers the save control.
    public var makePostGridPage: ((_ style: PostGridPageStyle, _ savesPosts: Bool) -> any PostGridPage)?

    /// `makePostGridPage`, which the composition root always wires: the
    /// profile has no grid of its own any more.
    private var gridPageFactory: ProfileGridPageFactory {
        guard let makePostGridPage else {
            preconditionFailure("ProfileFeatureBuilder.makePostGridPage is not wired (AppContainer)")
        }
        return makePostGridPage
    }
    /// The wallet the gallery cards' like chips stake from — the app's one
    /// instance. Nil leaves the chips counters.
    public var wallet: WalletStore?
    /// Settings → Wallet and Purchases (#400): built by the composition
    /// root, which can read the server wallet. Nil leaves it coming soon.
    public var makeWalletSection: (@MainActor () -> UIViewController)?
    /// Builds a gallery's card staking with the app's live post counts
    /// (#896): a like in the feed shows on the profile's cards. Nil: the
    /// cards stake from `wallet` and keep the counts they loaded.
    public var makeCardStaking: (@MainActor () -> PostCardStaking?)?
    /// The app's one follow-change channel: the header's Follow button and
    /// the followers lists keep agreeing with a follow made anywhere else.
    /// Nil leaves each screen with the answer it loaded.
    public var followEvents: FollowGraphEvents?
    /// A post of the viewer's own the server deleted here, and one restored
    /// from Recently Deleted (#896): the composition root writes them to the
    /// app's `EntityStore`, so the feeds and For You drop the post — and let
    /// it in again. Nil: only this profile's gallery knows.
    public var onPostDeleted: (@MainActor (PostID) -> Void)?
    public var onPostRestored: (@MainActor (PostID) -> Void)?
    /// The active profile's interest tags (timeline #662), for What You See.
    /// Nil leaves the Your Interests section out.
    public var interestTags: (any InterestTagsManaging)?
    /// The app's one cache coordinator, through which Settings → Storage
    /// measures and clears every cache, and applies the storage limit and
    /// the cellular choice (#899). Nil leaves Storage with the caches it
    /// names itself.
    public var cacheCoordinator: CacheCoordinator?

    /// Makes the device's passkeys for Settings → Passkeys (#551): the
    /// system sheet by default; the app hands in a simulated one in mock mode,
    /// whose relying party no device is associated with.
    public var makePasskeyAuthorizer: @MainActor () -> any PasskeyAuthorizing = { PlatformPasskeyAuthorizer() }

    /// Settings → Storage, on the app's coordinator.
    private func makeStorageSettings() -> StorageSettingsViewController {
        StorageSettingsViewController(model: StorageSettingsModel(
            inventory: .standard(coordinator: cacheCoordinator),
            coordinator: cacheCoordinator
        ))
    }

    /// What Delete Account names before the irreversible step (#402): every
    /// profile on the account, and what is left in the wallet.
    private var deletionChecklist: @Sendable () async -> DeletionChecklist? {
        let switching = switching
        let wallet = wallet
        return {
            let profiles = try? await switching?.accountProfiles()
            return DeletionChecklist(
                profileHandles: profiles?.map(\.handle),
                points: wallet?.balance,
                gems: wallet?.snapshot().gems
            )
        }
    }

    public func makeProfileViewController(for profileID: ProfileID, identityStub: ProfileIdentityStub?) -> UIViewController {
        makeRoutedProfileViewController(source: .profile(profileID), lookup: nil, identityStub: identityStub)
    }

    public func makeProfileViewController(
        resolving reference: ProfileReference,
        lookup: @escaping ProfileLookingUp
    ) -> UIViewController {
        // The same screen as an author's profile, on the same skeleton: only
        // the id it loads arrives a round trip later (#800).
        makeRoutedProfileViewController(source: .lookup(reference), lookup: lookup, identityStub: nil)
    }

    private func makeRoutedProfileViewController(
        source: ProfileViewModel.Source,
        lookup: ProfileLookingUp?,
        identityStub: ProfileIdentityStub?
    ) -> UIViewController {
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
                source: source,
                router: router,
                cache: cache,
                followEvents: followEvents,
                lookup: lookup,
                // A routed profile can be the viewer's own (a link to it).
                postDeleted: onPostDeleted
            ),
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            makeGridPage: gridPageFactory,
            shareTargeting: shareTargeting,
            onLogout: nil,
            makeRelationshipsViewController: makeRelationshipsFactory(),
            identityStub: identityStub
        )
        controller.feedHero = openFeedHero
        controller.staking = makeCardStaking?() ?? wallet.map(PostCardStaking.init)
        return controller
    }

    public func viewerAvatarImage() async -> UIImage? {
        guard let url = (try? await repository.currentUserProfile())?.avatarURL else { return nil }
        return try? await imagePipeline.image(for: url, size: .avatar)
    }
}
