import AppPreferences
import AuthInterface
import CacheKit
import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import LocalStore
import MediaCore
import ProfileData
import ProfileInterface
import SettingsInterface
import UIKit

/// What Settings reads and writes on the active profile. One repository
/// answers all of it (`ProfileRepository`): composed here, so the wiring is
/// checked by the compiler instead of asked at run time (#2375).
public typealias ProfileSettingsManaging = BlockedAccountsManaging & ProfileMuting & ProfileRestricting
    & InteractionLimitsManaging & CommentFiltersManaging & ProfileVisibilityManaging & FollowRequestsManaging
    & PostWindowManaging & CommentAudienceManaging & PostSharingManaging & InteractionAudienceManaging
    & ProfileTabVisibilityManaging & ListPrivacyManaging & ActivityDiscoveryManaging & ShareLinkManaging
    & LocationSharingManaging & FeedPreferencesManaging & ProfileViewerResolving & ContactFollowing
    & AccountTypeManaging & VerificationRequesting

/// What Settings reads and changes on the account (`AccountRepository`).
public typealias AccountSettingsManaging = AccountProviding & AccountLifecycleManaging & AccountDeactivating
    & AccountConsentManaging & AccountDeletionCancelling & SupervisionManaging & ContactProfileFinding

/// The account's credentials and sessions, for Security and Login
/// (`AccountSessionsRepository`).
public typealias AccountSecurityManaging = AccountSessionsManaging & CredentialStepUp & ContactChanging
    & TwoStepManaging & PasskeysManaging & PasskeyStepUp & AuthorizedAppsManaging

/// Builds every Settings and Account screen (#2382), the Settings feature's
/// entry point, consumed through `SettingsFeatureBuilding` by the profile and
/// the app shell. The profile feature used to build these screens itself,
/// asking its repositories at run time what they could do (`as? any …`): a
/// capability that was not wired compiled, and its row quietly said "Coming
/// Soon". Here each one is a typed dependency, so forgetting one fails to
/// compile.
@MainActor
public struct SettingsAssembly: SettingsFeatureBuilding {
    /// Everything the settings screens need, handed in by the composition
    /// root.
    public struct Dependencies {
        /// The active profile's settings (Privacy, Safety, What You See…).
        public var profile: any ProfileSettingsManaging
        /// The account's details, lifecycle, consents and supervision.
        public var account: any AccountSettingsManaging
        /// Security and Login: sessions, two-step, passkeys, authorized apps.
        public var security: any AccountSecurityManaging
        /// Safety → Account Status, and each decision's appeal.
        public var accountStatus: any AccountStatusProviding & ModerationDecisionReviewing
        /// Safety → Your Reports: the repository that files reports lists them.
        public var reports: any ReportHistoryProviding
        /// Settings → Notifications (#392).
        public var notificationPreferences: any NotificationPreferencesManaging
        /// Your Activity → Recently Deleted (#887).
        public var trash: any PostTrashManaging
        /// The account's profiles, for "Switch Profile" and Delete Account's
        /// checklist.
        public var switching: any ProfileSwitching
        /// What You See → Your Interests (#413).
        public var interestTags: any InterestTagsManaging
        /// What is left in the wallet, named before Delete Account (#402).
        public var wallet: any WalletReading
        public var imagePipeline: ImagePipeline
        public var router: any Router
        /// The app's one follow-change channel, for Find Friends from
        /// Contacts. Nil: each row keeps the answer it loaded.
        public var followEvents: FollowGraphEvents?
        /// The device store (#1776): the settings screens open on their last
        /// answers. Nil keeps nothing.
        public var localStore: LocalStore?
        /// Settings → Storage measures and clears every cache through it, and
        /// applies the storage limit and the cellular choice (#899). Nil
        /// leaves Storage with the caches it names itself.
        public var cacheCoordinator: CacheCoordinator?
        /// Settings → Wallet and Purchases (#400): the wallet's screen.
        public var makeWalletSection: @MainActor () -> UIViewController
        /// The app's one profile switcher (#2034), for "Switch Profile". Nil
        /// when the account can't switch.
        public var makeSwitcher: @MainActor () -> (any ProfileSwitcherPresenting)?
        /// Makes the device's passkeys (#551): the system sheet, or a
        /// simulated one in mock mode.
        public var makePasskeyAuthorizer: @MainActor () -> any PasskeyAuthorizing
        /// A post restored from Recently Deleted is back in its author's
        /// gallery: a revisit must not open on the pages without it (#887).
        public var onGalleryRestored: (ProfileID) -> Void
        /// …and the app's feeds and For You let it in again (#896).
        public var onPostRestored: @MainActor (PostID) -> Void

        public init(
            profile: any ProfileSettingsManaging,
            account: any AccountSettingsManaging,
            security: any AccountSecurityManaging,
            accountStatus: any AccountStatusProviding & ModerationDecisionReviewing,
            reports: any ReportHistoryProviding,
            notificationPreferences: any NotificationPreferencesManaging,
            trash: any PostTrashManaging,
            switching: any ProfileSwitching,
            interestTags: any InterestTagsManaging,
            wallet: any WalletReading,
            imagePipeline: ImagePipeline,
            router: any Router,
            followEvents: FollowGraphEvents?,
            localStore: LocalStore?,
            cacheCoordinator: CacheCoordinator?,
            makeWalletSection: @escaping @MainActor () -> UIViewController,
            makeSwitcher: @escaping @MainActor () -> (any ProfileSwitcherPresenting)?,
            makePasskeyAuthorizer: @escaping @MainActor () -> any PasskeyAuthorizing,
            onGalleryRestored: @escaping (ProfileID) -> Void,
            onPostRestored: @escaping @MainActor (PostID) -> Void
        ) {
            self.profile = profile
            self.account = account
            self.security = security
            self.accountStatus = accountStatus
            self.reports = reports
            self.notificationPreferences = notificationPreferences
            self.trash = trash
            self.switching = switching
            self.interestTags = interestTags
            self.wallet = wallet
            self.imagePipeline = imagePipeline
            self.router = router
            self.followEvents = followEvents
            self.localStore = localStore
            self.cacheCoordinator = cacheCoordinator
            self.makeWalletSection = makeWalletSection
            self.makeSwitcher = makeSwitcher
            self.makePasskeyAuthorizer = makePasskeyAuthorizer
            self.onGalleryRestored = onGalleryRestored
            self.onPostRestored = onPostRestored
        }
    }

    private let dependencies: Dependencies
    /// The settings screens' last answers on the device (#1776).
    private let settingsCache: SettingsLocalCache?

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
        self.settingsCache = dependencies.localStore.map(SettingsLocalCache.init(store:))
    }

    // MARK: - Entry points

    /// The signed-in viewer's Settings, the own profile's gear. `onLogout`
    /// is the shell's: Log Out, and what a deleted or deactivated account
    /// leaves behind.
    public func makeSettingsViewController(onLogout: @escaping () -> Void) -> UIViewController {
        SettingsViewController(
            switching: dependencies.switching,
            switcher: dependencies.makeSwitcher(),
            makeDestination: { section in makeDestination(section, onLogout: onLogout) },
            onLogout: onLogout
        )
    }

    /// Settings for a guest (guest mode): only what works without an
    /// account, with "Log in or sign up", which calls `onSignIn`.
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

    /// Family and Teens from a supervision notification (#1106): the same
    /// page Settings opens, which then opens the link with `otherAccountID`
    /// if it still exists. Reached outside Settings, its protection rows
    /// open nothing (there is no Settings stack to open them in).
    public func makeFamilyAndTeensViewController(openingSupervisionWith otherAccountID: String?) -> UIViewController {
        let page = makeFamilyAndTeens()
        page.pendingSupervisionAccountID = otherAccountID
        return page
    }

    /// A family supervision invite opened from a link (#417): the code filled
    /// in, nothing linked until the viewer taps Link. Once linked, the screen
    /// steps back and says so.
    public func makeSupervisionAcceptViewController(code: String) -> UIViewController {
        let account = dependencies.account
        return SupervisionAcceptViewController(
            model: SupervisionAcceptModel(manager: account, code: code),
            resolveTeen: { try await account.currentAccount().ageBracket.isTeen }
        ) { accept, link in
            let navigation = accept.navigationController
            accept.closeScreen()
            if let landing = navigation?.topViewController ?? navigation {
                Feedback.success(SupervisionCopy.linkedToast(link), from: landing)
            }
        }
    }

    /// Edit Profile → Account Type (personal, creator, business).
    public func makeAccountTypeViewController() -> UIViewController {
        AccountTypeViewController(manager: dependencies.profile, verifier: dependencies.profile)
    }

    /// Edit Profile → who sees the followers and following lists.
    public func makeListPrivacyViewController() -> UIViewController {
        ListPrivacyViewController(manager: dependencies.profile).cachingSettings(in: settingsCache)
    }

    public func presentPasskeyOfferIfDue(
        on host: @escaping () -> UIViewController?,
        afterSignUp: Bool,
        completion: @escaping () -> Void
    ) {
        PasskeyOffer.presentIfDue(
            on: host,
            afterSignUp: afterSignUp,
            manager: dependencies.security,
            authorizer: dependencies.makePasskeyAuthorizer(),
            completion: completion
        )
    }

    // MARK: - Sections

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func makeDestination(_ section: SettingsSection, onLogout: @escaping () -> Void) -> UIViewController? {
        let profile = dependencies.profile
        let account = dependencies.account
        let security = dependencies.security
        let imagePipeline = dependencies.imagePipeline
        let settingsCache = settingsCache
        switch section {
        case .account:
            return AccountSettingsViewController(
                account: account,
                lifecycle: account,
                onAccountDeleted: onLogout,
                deactivator: account,
                stepUp: security,
                contactChanger: security,
                onDeactivated: onLogout,
                deletionChecklist: deletionChecklist
            )
        case .security:
            return SecuritySettingsViewController(
                viewModel: SecuritySettingsViewModel(sessions: security),
                onSignedOutEverywhere: onLogout,
                makeCheckup: {
                    SecurityCheckupViewController(account: account, sessions: security, authenticator: DeviceAuthenticator())
                },
                makeTwoStep: { TwoStepViewController(account: account, manager: security, stepUp: security) },
                makePasskeys: { [makePasskeyAuthorizer = dependencies.makePasskeyAuthorizer] in
                    PasskeysViewController(
                        model: PasskeysModel(manager: security, authorizer: makePasskeyAuthorizer()),
                        stepUp: security,
                        passkeyStepUp: security
                    )
                },
                passkeysAvailable: { await security.passkeysAvailable() },
                makeAuthorizedApps: {
                    AuthorizedAppsViewController(
                        viewModel: AuthorizedAppsViewModel(manager: security),
                        imagePipeline: imagePipeline
                    )
                }
            )
        case .safety:
            return makeSafety()
        case .notifications:
            return NotificationSettingsViewController(manager: dependencies.notificationPreferences)
                .cachingSettings(in: settingsCache)
        case .activity:
            let trash = dependencies.trash
            let onGalleryRestored = dependencies.onGalleryRestored
            let onPostRestored = dependencies.onPostRestored
            return YourActivityViewController(makeRecentlyDeleted: {
                RecentlyDeletedViewController(
                    viewModel: RecentlyDeletedViewModel(
                        trash: trash, viewer: profile,
                        onRestored: onGalleryRestored,
                        onPostRestored: onPostRestored
                    ),
                    imagePipeline: imagePipeline
                )
            })
        case .adsAndData:
            return ConsentsViewController(manager: account, makeDeleteAccount: {
                DeleteAccountViewController(
                    viewModel: DeleteAccountViewModel(lifecycle: account, checklist: deletionChecklist),
                    onAccountDeleted: onLogout,
                    stepUp: security,
                    canceller: account
                )
            }, settingsCache: settingsCache)
        case .playback, .display, .emojis, .mediaComments, .language:
            return AppPreferencesViewController(page: section)
        case .storage:
            return makeStorageSettings()
        case .help:
            return SettingsLinksViewController.help(links: .current)
        case .legal:
            return SettingsLinksViewController.legal(links: .current, version: SettingsLinksViewController.appVersion())
        case .privacy:
            return PrivacySectionViewController(
                viewModel: PrivacySectionViewModel(
                    visibility: profile,
                    requests: profile,
                    windows: profile,
                    comments: profile,
                    sharing: profile,
                    audiences: profile,
                    tabs: profile
                ),
                makeListPrivacy: { ListPrivacyViewController(manager: profile).cachingSettings(in: settingsCache) },
                makeDataTransparency: { DataTransparencyViewController() },
                makeActivityDiscovery: {
                    ActivityDiscoveryViewController(
                        manager: profile,
                        shareLinks: profile,
                        makeContactFriends: { makeContactFriends() }
                    ).cachingSettings(in: settingsCache)
                },
                makeLocationSharing: { LocationSharingViewController(manager: profile).cachingSettings(in: settingsCache) },
                imagePipeline: imagePipeline
            )
        case .familyAndTeens:
            return makeFamilyAndTeens()
        case .whatYouSee:
            return WhatYouSeeViewController(preferences: profile, interestTags: dependencies.interestTags, isTeen: {
                try await account.currentAccount().ageBracket.isTeen
            }).cachingSettings(in: settingsCache)
        // The wallet's history (#400): the app's screen, which reads the
        // server wallet.
        case .wallet:
            return dependencies.makeWalletSection()
        default:
            return nil
        }
    }

    /// Safety: blocked, muted and restricted accounts, limits, hidden words,
    /// the account's status and the viewer's reports.
    private func makeSafety() -> UIViewController {
        let profile = dependencies.profile
        let accountStatus = dependencies.accountStatus
        let reports = dependencies.reports
        let imagePipeline = dependencies.imagePipeline
        let settingsCache = settingsCache
        return SafetySettingsViewController(destinations: [
            .init(title: "Blocked Accounts", symbolName: "nosign") {
                BlockedAccountsViewController(viewModel: BlockedAccountsViewModel(blocks: profile), imagePipeline: imagePipeline)
            },
            .init(title: "Muted Accounts", symbolName: "speaker.slash") {
                MutedAccountsViewController(viewModel: MutedAccountsViewModel(muting: profile), imagePipeline: imagePipeline)
            },
            .init(title: "Restricted Accounts", symbolName: "person.crop.circle.badge.minus") {
                RestrictedAccountsViewController(
                    viewModel: RestrictedAccountsViewModel(restricting: profile),
                    imagePipeline: imagePipeline
                )
            },
            .init(title: "Limits", symbolName: "hand.raised") {
                LimitInteractionsViewController(manager: profile).cachingSettings(in: settingsCache)
            },
            .init(title: "Hidden Words", symbolName: "text.badge.xmark") {
                HiddenWordsViewController(manager: profile).cachingSettings(in: settingsCache)
            },
            .init(title: "Account Status", symbolName: "checkmark.shield") {
                AccountStatusViewController(status: accountStatus, reviewer: accountStatus)
            },
            .init(title: "Your Reports", symbolName: "flag") {
                YourReportsViewController(history: reports, appeals: accountStatus)
            }
        ], planned: [])
    }

    /// Family and Teens. Throws on a failed age read: never "adult" by
    /// default (#799).
    private func makeFamilyAndTeens() -> FamilyAndTeensViewController {
        let account = dependencies.account
        return FamilyAndTeensViewController(
            isTeen: { try await account.currentAccount().ageBracket.isTeen },
            // Parental Supervision (#417).
            supervision: account,
            imagePipeline: dependencies.imagePipeline,
            router: dependencies.router
        )
    }

    /// Find Friends from Contacts (#412): the account matches the hashes,
    /// the profile repository follows on the app's follow channel.
    private func makeContactFriends() -> UIViewController {
        ContactFriendsViewController(
            viewModel: ContactFriendsViewModel(
                finder: dependencies.account,
                following: dependencies.profile,
                router: dependencies.router,
                followEvents: dependencies.followEvents
            ),
            imagePipeline: dependencies.imagePipeline
        )
    }

    /// Settings → Storage, on the app's coordinator.
    private func makeStorageSettings() -> StorageSettingsViewController {
        StorageSettingsViewController(model: StorageSettingsModel(
            inventory: .standard(coordinator: dependencies.cacheCoordinator),
            coordinator: dependencies.cacheCoordinator
        ))
    }

    /// What Delete Account names before the irreversible step (#402): every
    /// profile on the account, and what is left in the wallet.
    private var deletionChecklist: @Sendable () async -> DeletionChecklist? {
        let switching = dependencies.switching
        let wallet = dependencies.wallet
        return {
            let profiles = try? await switching.accountProfiles()
            return DeletionChecklist(
                profileHandles: profiles?.map(\.handle),
                likes: wallet.balance,
                gems: wallet.snapshot().gems
            )
        }
    }
}
