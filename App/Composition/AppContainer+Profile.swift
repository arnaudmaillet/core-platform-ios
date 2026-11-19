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
            authSession: sessionManager
        )
    }

    func makeSupervisedScreenTime() -> SupervisedScreenTime {
        let session: any AuthSessionProviding = sessionManager
        return SupervisedScreenTime(
            reporter: accountRepository,
            defaults: .standard,
            accountID: { await Self.signedInAccount(session) },
            isMinor: { TeenProtections.shared.isMinor },
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
        var builder = ProfileFeatureBuilder(
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
            localStore: localStore
        )
        // The one place that can see both features, which is the whole reason
        // this is injected rather than reached for: Profile describes where a
        // tapped post is, Feed owns the card and the flight, and neither
        // imports the other.
        // The same pool every other surface draws on, so a profile's video
        // competes for the same slots rather than opening a second one.
        builder.videoPlayback = videoPlayback
        // The switcher's counts and the Profile tab's dot (#2034): each
        // profile's unread notifications, from the feature that holds them.
        builder.unreadNotifications = { [unowned self] id in
            await self.notificationsFeature.unreadCount(forProfile: id.rawValue)
        }
        // The gallery cards' like chips stake from the app's one wallet.
        builder.wallet = walletStore
        // …and draw their posts' live counts (#896).
        // A person opens with what the app already knows of them (#1859).
        builder.knownIdentity = { [unowned self] id, stub in
            self.entityStore.knownIdentity(of: id, stub: stub)
        }
        builder.makeCardStaking = { [unowned self] in
            PostCardStaking(wallet: self.walletStore, entities: self.entityStore)
        }
        // A post the viewer deleted leaves every feed and For You (#896).
        builder.onPostDeleted = { [unowned self] id in self.entityStore.deletePost(id) }
        // A follow made on another surface (a feed's "+", a card's Unfollow)
        // reaches the profile screens and their followers lists.
        builder.followEvents = followGraphEvents
        builder.openFeedHero = { [weak self] postIDs, presenter, origin in
            self?.feedFeature.presentSnapFeedHero(
                postIDs: postIDs, from: presenter, origin: origin
            )
        }
        // The profile's pages are For You's own grid (#1273, epic #1269).
        builder.makePostGridPage = { [unowned self] style, savesPosts in
            feedFeature.makePostGridPage(style: style, savesPosts: savesPosts)
        }
        // Pinning a profile onto the map's people rail, from the profile
        // screen. The SAME service the map itself writes through, so the rail
        // and the button cannot hold different opinions about who is pinned.
        builder.mapPinning = mapsFeature.profilePinning
        // A profile's Channels tab (#2232): Chat's read of the channels a
        // profile owns, and its new channel's sheet for "Create a Channel".
        // Only with `-channels` — off, no profile asks, and opening one
        // never builds Chat. The rows' Join / Request / Open are the
        // showcase card's (`PostEmbedView.makeChannelActions`, above).
        if DebugFlags.isOn("-channels") {
            builder.makeProfileChannels = { [unowned self] in chatFeature.makeProfileChannels() }
            builder.makeChannelCreation = { [unowned self] in chatFeature.makeChannelCreationViewController() }
        }
        return builder
    }
}
