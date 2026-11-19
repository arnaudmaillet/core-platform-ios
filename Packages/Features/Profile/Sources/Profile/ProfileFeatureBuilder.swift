import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import LocalStore
import MapsInterface
import MediaCore
import MediaPlayback
import PostGrid
import ProfileData
import ProfileInterface
import SettingsInterface
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
    /// The viewer's saved pile: the app's one (#2376), a view over the
    /// EntityStore's saved fact (#896), so a save made in a feed is on the
    /// gallery's cards. See `PostBookmarkStore`.
    private let bookmarks: PostBookmarkStore
    /// What the viewer viewed (#1344): the app's one pile, which the feeds
    /// record into (#2376).
    private let viewHistory: PostViewHistoryStore
    /// Which tabs each profile had last time (#1773): the app's one store
    /// (#2376).
    private let presence: SectionPresenceStore
    /// Last-known profiles, shared by every profile screen so a switch to one
    /// already seen renders instantly. One per app, like the preferences;
    /// backed by the device store when the app hands one in (#893).
    private let cache: ProfileCache
    /// Followers, Following and Friends on the device (#1776).
    private let relationshipsCache: ProfileRelationshipsLocalCache?
    private let imagePipeline: ImagePipeline
    private let router: (any Router)?
    /// Multi-profile switching for the account (lists profiles, switches active).
    private let switching: (any ProfileSwitching)?
    /// Settings and Account (#2382), through its interface: the own
    /// profile's gear, and Edit Profile's Account Type and list privacy rows.
    private let settings: any SettingsFeatureBuilding
    /// The gem-shop items a profile wears (#944): Edit Profile's Video
    /// Banner row. Nil hides the row.
    private let profileItems: (any ProfileItemAccess)?

    public init(
        repository: any ProfileProviding,
        reporting: (any ContentReporting)? = nil,
        shareTargeting: (any ProfileShareTargeting)? = nil,
        gallery: (any ProfileGalleryProviding)? = nil,
        relationships: (any ProfileRelationshipsProviding)? = nil,
        imagePipeline: ImagePipeline,
        router: (any Router)? = nil,
        switching: (any ProfileSwitching)? = nil,
        settings: any SettingsFeatureBuilding,
        profileItems: (any ProfileItemAccess)? = nil,
        /// The device store (#893): the viewer's own profile and the profiles
        /// they visited open on their last content at a cold start. Nil keeps
        /// the profile cache in memory.
        localStore: LocalStore? = nil,
        presence: SectionPresenceStore,
        bookmarks: PostBookmarkStore,
        viewHistory: PostViewHistoryStore
    ) {
        self.presence = presence
        self.bookmarks = bookmarks
        self.viewHistory = viewHistory
        self.cache = ProfileCache(store: localStore)
        self.relationshipsCache = localStore.map(ProfileRelationshipsLocalCache.init(store:))
        self.repository = repository
        self.reporting = reporting
        self.shareTargeting = shareTargeting
        self.gallery = gallery
        self.relationships = relationships
        self.imagePipeline = imagePipeline
        self.router = router
        self.switching = switching
        self.settings = settings
        self.profileItems = profileItems
    }

    private func makeSwitcherFactory() -> ProfileSwitcherMenuFactory? {
        switching.map {
            ProfileSwitcherMenuFactory(switching: $0, imagePipeline: imagePipeline, unreadCount: unreadNotifications)
        }
    }

    /// The counter row's destination, shared by both profile entry points —
    /// the viewer's own profile and any routed-to one — so the two can't drift.
    private func makeRelationshipsFactory() -> (
        (ProfileRelationshipsViewModel.Subject, RelationshipDirection) -> UIViewController
    )? {
        guard let relationships else { return nil }
        return { [imagePipeline, router, followEvents, relationshipsCache] subject, direction in
            ProfileRelationshipsViewController(
                viewModel: ProfileRelationshipsViewModel(
                    subject: subject,
                    repository: relationships,
                    router: router,
                    direction: direction,
                    followEvents: followEvents,
                    deviceCache: relationshipsCache
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
                viewHistory: viewHistory,
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
            presence: presence,
            shareTargeting: shareTargeting,
            onLogout: onLogout,
            makeEditViewController: { [imagePipeline, gallery, profileItems, settings] profile, onSaved in
                let editor = EditProfileViewController(
                    viewModel: EditProfileViewModel(
                        repository: repository, seed: profile,
                        banner: repository as? any ProfileBannerManaging, gallery: gallery, items: profileItems,
                        onSaved: onSaved
                    ),
                    imagePipeline: imagePipeline
                )
                editor.onOpenAccountType = { [weak editor] in
                    editor?.navigationController?.pushViewController(settings.makeAccountTypeViewController(), animated: true)
                }
                editor.onOpenPrivacy = { [weak editor] in
                    editor?.navigationController?.pushViewController(settings.makeListPrivacyViewController(), animated: true)
                }
                return editor
            },
            // Both are account management, so both ride on `onLogout`: a
            // routed arrival gets the profile without the global actions. Edit
            // Profile is deliberately NOT gated — editing your own bio is a
            // profile action, and it is safe at any stack depth.
            makeSettingsViewController: onLogout.map { [settings] onLogout in
                { settings.makeSettingsViewController(onLogout: onLogout) }
            },
            switcherFactory: onLogout == nil ? nil : makeSwitcherFactory(),
            makeRelationshipsViewController: makeRelationshipsFactory(),
            identityStub: identityStub,
            trayPlacement: trayPlacement,
            channels: makeChannelsModel(isOwnProfile: true),
            makeChannelCreation: makeChannelCreation
        )
        controller.feedHero = openFeedHero
        controller.staking = makeCardStaking?() ?? wallet.map { PostCardStaking(wallet: $0, saves: bookmarks) }
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
    /// One profile of the account's unread notifications (#2034), for the
    /// switcher's rows and the Profile tab's dot. Notifications answers it;
    /// the app wires it.
    public var unreadNotifications: (@MainActor @Sendable (ProfileID) async -> Int?)?
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
    /// The channels a profile owns (#2232): Chat's read, handed in by the
    /// composition root — the only place that sees both features. Nil, or
    /// nil answered (the channels off), and no profile has a Channels tab.
    public var makeProfileChannels: (@MainActor () -> (any ProfileChannelsProviding)?)?
    /// The new channel's sheet (Chat's, the "+" menu's), for the own
    /// Channels tab's "Create a Channel" (#2232). Nil: the row isn't offered.
    public var makeChannelCreation: (@MainActor () -> UIViewController?)?

    /// The Channels tab's model for one profile screen, or nil with no
    /// channels to read.
    private func makeChannelsModel(isOwnProfile: Bool) -> ProfileChannelsViewModel? {
        guard let provider = makeProfileChannels?() else { return nil }
        return ProfileChannelsViewModel(
            provider: provider, isOwnProfile: isOwnProfile, offersCreation: makeChannelCreation != nil
        )
    }

    /// The wallet the gallery cards' like chips stake from — the app's one
    /// instance. Nil leaves the chips counters.
    public var wallet: (any WalletStaking)?
    /// Builds a gallery's card staking with the app's live post counts
    /// (#896): a like in the feed shows on the profile's cards. Nil: the
    /// cards stake from `wallet` and keep the counts they loaded.
    public var makeCardStaking: (@MainActor () -> PostCardStaking?)?
    /// What the app knows of a person about to be opened (#1859): the route's
    /// stub, completed from the app's store (`EntityStore.knownIdentity`).
    /// Nil: the stub alone.
    public var knownIdentity: (@MainActor (ProfileID, ProfileIdentityStub?) -> ProfileIdentityStub?)?

    /// The identity a routed profile opens with: the stub, completed.
    private func identity(of source: ProfileViewModel.Source, stub: ProfileIdentityStub?) -> ProfileIdentityStub? {
        guard case .profile(let id) = source, let knownIdentity else { return stub }
        return knownIdentity(id, stub)
    }
    /// The app's one follow-change channel: the header's Follow button and
    /// the followers lists keep agreeing with a follow made anywhere else.
    /// Nil leaves each screen with the answer it loaded.
    ///
    /// The shared cache hears it from the moment it is set, not from the
    /// first profile made (#1670): a request asked from a feed's "+" before
    /// any card was opened must still reach the card opened next.
    public var followEvents: FollowGraphEvents? {
        didSet { cache.observe(followEvents) }
    }
    /// A post of the viewer's own the server deleted here (#896): the
    /// composition root writes it to the app's `EntityStore`, so the feeds and
    /// For You drop the post. Nil: only this profile's gallery knows.
    /// (Settings → Recently Deleted restores, through `SettingsAssembly`.)
    public var onPostDeleted: (@MainActor (PostID) -> Void)?

    public func invalidateGallery(of author: ProfileID) {
        cache.removeGallery(for: author)
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
        let known = identity(of: source, stub: identityStub)
        let viewModel = ProfileViewModel(
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
        )
        viewModel.identity = known
        let controller = ProfileViewController(
            viewModel: viewModel,
            imagePipeline: imagePipeline,
            videoPlayback: videoPlayback,
            makeGridPage: gridPageFactory,
            presence: presence,
            shareTargeting: shareTargeting,
            onLogout: nil,
            makeRelationshipsViewController: makeRelationshipsFactory(),
            identityStub: known,
            // `isOwnProfile` follows the view model's source: a routed
            // profile is read as someone's page, even the viewer's (#2232).
            channels: makeChannelsModel(isOwnProfile: viewModel.isOwnProfile)
        )
        controller.feedHero = openFeedHero
        controller.staking = makeCardStaking?() ?? wallet.map { PostCardStaking(wallet: $0, saves: bookmarks) }
        return controller
    }

    public func makeProfileCardViewController(
        for profileID: ProfileID,
        identityStub: ProfileIdentityStub?,
        openProfile: @escaping () -> Void,
        push: @escaping (UIViewController) -> Void
    ) -> UIViewController {
        cache.observe(followEvents)
        let known = identity(of: .profile(profileID), stub: identityStub)
        let viewModel = ProfileViewModel(
            repository: repository,
            mapPinning: mapPinning,
            reporting: reporting,
            gallery: gallery,
            galleryPreferences: galleryPreferences,
            source: .profile(profileID),
            router: router,
            cache: cache,
            followEvents: followEvents,
            lookup: nil,
            postDeleted: onPostDeleted
        )
        viewModel.identity = known
        let card = ProfileCardViewController(
            viewModel: viewModel,
            imagePipeline: imagePipeline,
            shareTargeting: shareTargeting,
            makeRelationshipsViewController: makeRelationshipsFactory(),
            identityStub: known,
            actions: .init(openProfile: openProfile, push: push),
            videoPlayback: videoPlayback
        )
        return card.wrappedInSheet()
    }

    public func viewerAvatarImage() async -> UIImage? {
        guard let url = (try? await repository.currentUserProfile())?.avatarURL else { return nil }
        return try? await imagePipeline.image(for: url, size: .avatar)
    }
}
