import Auth
import AuthInterface
import ChatInterface
import Connect
import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreStorage
import EntityStore
import Feed
import FeedInterface
import Foundation
import LaunchArguments
import LocalStore
import MapsInterface
import MediaCore
import MediaPlayback
import NotificationsInterface
import PostGrid
import Profile
import ProfileData
import ProfileInterface
import SettingsInterface
import UIKit
import Wallet

// Profile (#2375): the profile's repositories and builder, the account and the
// supervised teen's time. Its properties are declared in `AppContainer.swift`,
// since an extension holds no stored property; they are built here.
extension AppContainer {
    func makeProfileRepository() -> ProfileRepository {
        ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
            counterClient: Counter_V1_CounterServiceClient(client: authenticatedRPCClient),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: authenticatedRPCClient),
            authSession: sessionManager,
            viewer: viewerSession,
            followEvents: followGraphEvents,
            people: entityStore
        )
    }

    func makeProfileReportRepository() -> ProfileReportRepository {
        ProfileReportRepository(
            moderationClient: Moderation_V1_ModerationServiceClient(client: authenticatedRPCClient)
        )
    }

    func makeAccountRepository() -> AccountRepository {
        AccountRepository(
            accountClient: Account_V1_AccountServiceClient(client: authenticatedRPCClient),
            authSession: sessionManager,
            teenProtections: teenProtections
        )
    }

    func makeSupervisedScreenTime() -> SupervisedScreenTime {
        let session: any AuthSessionProviding = sessionManager
        return SupervisedScreenTime(
            reporter: accountRepository,
            defaults: .standard,
            accountID: { await Self.signedInAccount(session) },
            isMinor: { [teenProtections] in teenProtections.isMinor },
            calendar: { Calendar.current },
            now: { Date() }
        )
    }

    private nonisolated static func signedInAccount(_ session: any AuthSessionProviding) async -> String? {
        guard case .authenticated(let account) = await session.currentState() else { return nil }
        return account.rawValue
    }

    /// Who set the supervised teen's daily limit, by handle, for the pause
    /// screen; nil when it can't be told.
    func supervisedLimitSetter() async -> String? {
        await SupervisedPauseCopy.limitSetter(using: accountRepository)
    }

    func makeProfileGalleryRepository() -> ProfileGalleryRepository {
        ProfileGalleryRepository(
            postClient: Post_V1_PostServiceClient(client: authenticatedRPCClient),
            searchClient: Search_V1_SearchServiceClient(client: authenticatedRPCClient),
            postCounters: postCounters,
            // Resolves whose posts the tiles are. The grid draws none of it; the
            // full-screen page a tile opens into is seeded from the tile's model,
            // and without this that page arrives with an anonymous author capsule
            // until its own fetch answers.
            profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
            // The Liked tab and another profile's Saved tab (#411, #837).
            engagementClient: Engagement_V1_EngagementServiceClient(client: authenticatedRPCClient),
            pageLimit: Self.galleryPageSize
        )
    }

    /// Posts per profile gallery page (#634).
    ///
    /// `-gallery-page-size <n>` (DEBUG): smaller pages, so a mock profile's
    /// gallery pages on the simulator at all — at the real size most fit in one.
    private static var galleryPageSize: Int32 {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let size = LaunchArgument.galleryPageSize.value(in: arguments).flatMap { Int32($0) }, size > 0 {
            return size
        }
        #endif
        return 30
    }

    func makeProfileShareTargetsRepository() -> ProfileShareTargetsRepository {
        ProfileShareTargetsRepository(
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: authenticatedRPCClient),
            profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
            searchClient: Search_V1_SearchServiceClient(client: authenticatedRPCClient),
            viewer: profileRepository
        )
    }

    func makeProfileRelationshipsRepository() -> ProfileRelationshipsRepository {
        ProfileRelationshipsRepository(
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: authenticatedRPCClient),
            profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
            viewer: profileRepository,
            supportsFollowerRemoval: true,
            followEvents: followGraphEvents,
            people: entityStore
        )
    }

    func makeProfileFeature() -> any ProfileFeatureBuilding {
        // A profile's Channels tab (#2232): Chat's read of the channels a
        // profile owns, and its new channel's sheet for "Create a Channel".
        // Only with `-channels` — off, no profile asks, and opening one
        // never builds Chat. The rows' Join / Request / Open are the
        // showcase card's (`PostEmbedView.makeChannelActions`, above).
        var makeProfileChannels: (@MainActor () -> (any ProfileChannelsProviding)?)?
        var makeChannelCreation: (@MainActor () -> UIViewController?)?
        if DebugFlags.isOn("-channels") {
            makeProfileChannels = { [unowned self] in chatFeature.makeProfileChannels() }
            makeChannelCreation = { [unowned self] in chatFeature.makeChannelCreationViewController() }
        }
        return ProfileFeatureBuilder(dependencies: .init(
            repository: profileRepository,
            reporting: profileReportRepository,
            shareTargeting: profileShareTargetsRepository,
            gallery: profileGalleryRepository,
            relationships: profileRelationshipsRepository,
            imagePipeline: imagePipeline,
            router: routeResolver,
            switching: profileRepository,
            settings: settingsFeature,
            profileItems: profileItems,
            localStore: localStore,
            presence: sectionPresence,
            bookmarks: postBookmarks,
            viewHistory: viewHistory,
            // The same pool every other surface draws on, so a profile's video
            // competes for the same slots rather than opening a second one.
            videoPlayback: videoPlayback,
            // Pinning a profile onto the map's people rail, from the profile
            // screen. The SAME service the map itself writes through, so the rail
            // and the button cannot hold different opinions about who is pinned.
            mapPinning: mapsFeature.profilePinning,
            // The switcher's counts and the Profile tab's dot (#2034): each
            // profile's unread notifications, from the feature that holds them.
            unreadNotifications: { [unowned self] id in
                await self.notificationsFeature.unreadCount(forProfile: id.rawValue)
            },
            // The one place that can see both features, which is the whole reason
            // this is injected rather than reached for: Profile describes where a
            // tapped post is, Feed owns the card and the flight, and neither
            // imports the other.
            openFeedHero: { [weak self] postIDs, presenter, origin in
                self?.feedFeature.presentSnapFeedHero(
                    postIDs: postIDs, from: presenter, origin: origin
                )
            },
            // The profile's pages are For You's own grid (#1273, epic #1269).
            makePostGridPage: { [unowned self] style, savesPosts in
                feedBuilder.makePostGridPage(style: style, savesPosts: savesPosts)
            },
            makeProfileChannels: makeProfileChannels,
            makeChannelCreation: makeChannelCreation,
            // The gallery cards' like chips stake from the app's one wallet, and
            // draw their posts' live counts (#896).
            makeCardStaking: { [unowned self] in
                PostCardStaking(wallet: self.walletStore, entities: self.entityStore, saves: self.postBookmarks)
            },
            // A person opens with what the app already knows of them (#1859).
            knownIdentity: { [unowned self] id, stub in
                self.entityStore.knownIdentity(of: id, stub: stub)
            },
            // A follow made on another surface (a feed's "+", a card's Unfollow)
            // reaches the profile screens and their followers lists.
            followEvents: followGraphEvents,
            // A post the viewer deleted leaves every feed and For You (#896).
            onPostDeleted: { [unowned self] id in self.entityStore.deletePost(id) },
            // The app's viewer channel (#2376): the shared profile cache forgets
            // on a viewer change, and the switchers publish on it.
            viewerEvents: viewerEvents
        ))
    }
}
