import Auth
import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreNetworkingMocks
import CoreRealtime
import CoreStorage
import DesignSystem
import EntityStore
import Feed
import FeedInterface
import Foundation
import LocalStore
import MediaCore
import MediaPlayback
import Profile
import ProfileData
import ProfileInterface
import UIKit

// Feed (#2375): the feed's repositories and builder, Discover, the sound sheet
// and the saves. Its properties are declared in `AppContainer.swift`, since an
// extension holds no stored property; they are built here.
extension AppContainer {
    /// Hands the app's saved pile its way to the server and sends what an
    /// earlier launch left queued. Called once, after connectivity starts.
    @MainActor
    func startSavedPostsSync() {
        guard savedPostsSync == nil else { return }
        let sync = SavedPostsSync(
            store: postBookmarks,
            outbox: SaveOutbox(),
            transport: EngagementSavedPosts(client: Engagement_V1_EngagementServiceClient(client: authenticatedRPCClient)),
            scope: storageScope
        )
        postBookmarks.sync = sync
        sync.start()
        savedPostsSync = sync
    }

    func makeFeedRepository() -> FeedRepository {
        FeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: authenticatedRPCClient),
            postClient: Post_V1_PostServiceClient(client: authenticatedRPCClient),
            profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
            engagementClient: Engagement_V1_EngagementServiceClient(client: authenticatedRPCClient),
            likeStaking: likeStaking,
            authSession: sessionManager,
            viewer: viewerSession,
            localCache: feedLocalCache
        )
    }

    func makeCommentsRepository() -> CommentsRepository {
        let repository = CommentsRepository(
            commentClient: Comment_V1_CommentServiceClient(client: authenticatedRPCClient),
            profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
            authSession: sessionManager,
            viewer: viewerSession,
            localStore: localStore,
            people: entityStore,
            // A voice comment's take goes up the way a voice post's does
            // (#2309, #2209).
            mediaUploader: MediaAssetUploader(
                mediaClient: Media_V1_MediaServiceClient(client: authenticatedRPCClient),
                transport: mediaUploadTransport
            )
        )
        // The shared viewer already carries the switch; this only drops the
        // composer's cached face the moment a switch is announced, without
        // waiting for the viewer's transition to reach the repository. The
        // Text Post page reads that face synchronously when it is built.
        activeViewerObserver = NotificationCenter.default.addObserver(
            forName: .activeProfileDidChange, object: nil, queue: .main
        ) { [repository] notification in
            guard let id = ActiveProfileChange.profileID(from: notification) else { return }
            Task { await repository.setActiveViewer(id) }
        }
        return repository
    }

    func makeFeedBuilder() -> FeedFeatureBuilder {
        FeedFeatureBuilder(dependencies: .init(
            repository: feedRepository,
            engagementProvider: feedRepository,
            commentsProvider: commentsRepository,
            realtime: realtimeClient,
            composedPosts: composedPostChannel,
            router: routeResolver,
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            // The comments composer's avatar opens the same switcher the profile
            // header offers. Lazily, and one instance per composer: the factory
            // caches its pre-formatted rows, so two surfaces sharing one would
            // race over that cache. `unowned self` matches `profileFeature`'s
            // own accessor below — the container outlives every screen.
            makeProfileSwitcher: { [unowned self] in self.profileFeature.makeProfileSwitcher() },
            wallet: walletStore,
            // The SAME sheet the map's badge presents — one claim surface,
            // reachable from wherever the balance is showing.
            makeWalletSheet: { [unowned self] in self.makeWalletSheet() },
            // No balance on any bar for a guest (#1146), asked per screen.
            showsBalance: { [unowned self] in self.memberGate.isMember },
            // A post card's "..." raises moderation cases and unfollows through the
            // SAME two repositories the profile screen uses. Feed sees only the
            // `CoreModels` protocols; which class satisfies them is the composition
            // root's business, which is what lets a feed row report a post without
            // the Feed package knowing the Profile package exists.
            reporting: profileReportRepository,
            socialGraph: profileRepository,
            // And whether the viewer follows an author already — the snap feed's
            // author pill offers "+" only to someone they do not.
            followRelations: profileRepository,
            // And a post menu's Mute and Block (#1498 §3), the profile's own.
            moderation: profileRepository,
            // And hear a follow made on any other surface, so that "+" and the
            // profile's button never disagree.
            followEvents: followGraphEvents,
            // counter.v1, so a card can show reach. The timeline read hydrates
            // likes only, and a card's counter chip shows VIEWS — without this it
            // has nothing to say and hides itself, which is what it did.
            postCounters: postCounters,
            postDrafts: postDraftStore,
            // The sound sheet's answers. Mock mode knows each clip's full sound;
            // the fleet's post contract carries no audio yet, so there every clip
            // is its own original sound (the feed's fallback).
            soundProvider: postSoundProvider,
            // "Use this sound": the shell opens its camera with it. Read at the
            // tap, because the shell sets it after this builder exists.
            useSound: { [unowned self] sound in self.onUseSound?(sound) },
            discovery: discoveryRepository,
            localCache: feedLocalCache,
            entities: entityStore,
            // A post's share sheet sends to the profile sheet's people (#1710).
            shareTargeting: profileShareTargetsRepository,
            // The viewer's stores (#2376): the app's one of each.
            bookmarks: postBookmarks,
            viewHistory: viewHistory,
            unavailablePosts: unavailablePosts,
            savedSounds: savedSounds,
            viewerProfile: { [storageScope] in
                guard case .member(_, let profile?) = storageScope.owner else { return nil }
                return ProfileID(profile)
            }
        ))
    }

    func makeDiscoveryRepository() -> DiscoveryFeedRepository {
        DiscoveryFeedRepository(
            timelineClient: Timeline_V1_TimelineServiceClient(client: authenticatedRPCClient),
            base: feedRepository,
            reader: { [weak self] in await self?.discoveryReader() ?? .guest },
            localCache: feedLocalCache
        )
    }

    /// Who reads Discover (#407, #413): the active profile, its Sensitive
    /// Content setting as the content level, and its Personalised
    /// Recommendations setting. A guest — and anything that can't be read — is restricted
    /// and unpersonalised; the server clamps teens and guests anyway.
    private func discoveryReader() async -> DiscoveryReader {
        guard memberGate.isMember,
              let profileID = try? await viewerSession.activeProfileID() else { return .guest }
        var request = Profile_V1_GetProfileByIdRequest()
        request.profileID = profileID.rawValue
        let view = await Profile_V1_ProfileServiceClient(client: authenticatedRPCClient)
            .getProfileByID(request: request, headers: [:]).message
        return DiscoveryReader(
            contentLevel: view?.feedSettings.sensitiveContent == .standard ? .standard : .restricted,
            profileID: profileID.rawValue,
            nonPersonalized: view?.feedSettings.nonPersonalized ?? true
        )
    }

    private var postSoundProvider: (any PostSoundProviding)? {
        switch environment {
        case .mock: MockPostSoundProvider(dataset: mockBackend.dataset, counters: mockBackend.counterStore)
        case .localFleet: nil
        }
    }
}
