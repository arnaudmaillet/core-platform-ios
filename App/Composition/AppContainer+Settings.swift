import Auth
import CacheKit
import Connect
import CoreContracts
import CoreModels
import CoreNavigation
import CoreStorage
import EntityStore
import Foundation
import LocalStore
import MediaCore
import ProfileData
import ProfileInterface
import Settings
import SettingsInterface
import UIKit
import Wallet

// Settings (#2375): Settings' own repositories and its assembly. Its properties
// are declared in `AppContainer.swift`, since an extension holds no stored
// property; they are built here.
extension AppContainer {
    func makeAccountSessionsRepository() -> AccountSessionsRepository {
        AccountSessionsRepository(
            authClient: Auth_V1_AuthServiceClient(client: authenticatedRPCClient),
            // A step-up's fresh access token replaces the session's, so the
            // gated call right after it (deactivation…) carries the proof.
            tokenInstaller: sessionManager,
            // No password any more (#840): a code to the account's address signs
            // the holder in again, which is the proof the server accepts.
            account: accountRepository,
            reauthenticator: sessionManager
        )
    }

    func makeNotificationPreferencesRepository() -> NotificationPreferencesRepository {
        NotificationPreferencesRepository(
            notificationClient: Notification_V1_NotificationServiceClient(client: authenticatedRPCClient),
            viewer: profileRepository
        )
    }

    func makeAccountStatusRepository() -> AccountStatusRepository {
        AccountStatusRepository(
            moderationClient: Moderation_V1_ModerationServiceClient(client: authenticatedRPCClient),
            authSession: sessionManager
        )
    }

    func makeSettingsFeature() -> any SettingsFeatureBuilding {
        SettingsAssembly(dependencies: .init(
            profile: profileRepository,
            account: accountRepository,
            security: accountSessionsRepository,
            accountStatus: accountStatusRepository,
            reports: profileReportRepository,
            notificationPreferences: notificationPreferencesRepository,
            trash: profileGalleryRepository,
            switching: profileRepository,
            // What You See → Your Interests (#413).
            interestTags: InterestTagsRepository(
                timelineClient: Timeline_V1_TimelineServiceClient(client: authenticatedRPCClient),
                profiles: profileRepository
            ),
            // Delete Account names what is left in the app's one wallet (#402).
            wallet: walletStore,
            imagePipeline: imagePipeline,
            router: routeResolver,
            followEvents: followGraphEvents,
            localStore: localStore,
            // Settings → Storage measures and clears every cache, and applies the
            // storage limit and the cellular choice, through the coordinator (#899).
            cacheCoordinator: cacheCoordinator,
            // Settings → Wallet and Purchases: the server wallet's history (#400).
            makeWalletSection: { [unowned self] in
                WalletScreens.history(wallet: self.walletStore, deviceCache: self.walletHistoryCache)
            },
            // The app's one switcher (#2034), for "Switch Profile".
            makeSwitcher: { [unowned self] in self.profileFeature.makeProfileSwitcher() },
            // Settings → Passkeys (#551): the same authenticator as sign-in's.
            makePasskeyAuthorizer: { [environment] in Self.makePasskeyAuthorizer(for: environment) },
            // A post restored from Recently Deleted is back in its author's
            // gallery, and may come back to every feed and For You (#887, #896).
            onGalleryRestored: { [unowned self] author in self.profileFeature.invalidateGallery(of: author) },
            onPostRestored: { [unowned self] id in self.entityStore.restorePost(id) },
            // The profile section follows a switch made anywhere (#2376).
            viewerEvents: viewerEvents
        ))
    }
}
