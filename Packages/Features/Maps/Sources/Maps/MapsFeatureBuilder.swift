import CoreLocation
import CoreModels
import CoreNavigation
import CoreStorage
import FeedInterface
import LaunchArguments
import LocalStore
import MapsInterface
import MediaCore
import MediaPlayback
import MediaUI
import PlaceInterface
import UIKit
import WalletInterface

/// The Maps feature's entry point, resolved by the composition root and
/// consumed through `MapsFeatureBuilding` by the app shell.
@MainActor
public struct MapsFeatureBuilder: MapsFeatureBuilding {
    /// Everything the map needs, handed in by the composition root (#2375):
    /// each collaborator the app always wires is required, so forgetting one
    /// fails to compile. The optionals are absent in production on the fleet
    /// (the shop and the country access are the mock's) or when the device
    /// store can't be opened.
    public struct Dependencies {
        /// The tiles' pins and clusters.
        public var repository: any GeoDiscoveryProviding
        /// The filter bar's favorites section and the people rail's pins.
        public var favoritesRepository: any MapFavoritesProviding
        public var imagePipeline: ImagePipeline
        /// A Maps-dedicated player pool (separate from the feed's) for the
        /// live pin previews, so the two surfaces never contend.
        public var videoPlayback: VideoPlaybackController
        /// Resolves the feed builder lazily, so the map can expand a
        /// pin/cluster into the shared snap feed without the composition root
        /// ordering the two features.
        public var feedFeature: () -> any FeedFeatureBuilding
        /// Resolves the place page's builder lazily (#2381): the page a
        /// hierarchy cluster's feed closes down onto, and a place link's.
        public var placeFeature: () -> any PlaceFeatureBuilding
        /// Fires the app's profile destination for a person the map surfaces
        /// (the sub-filter sheet's Profile swipe). Injected rather than
        /// imported so Maps keeps knowing nothing about routes or the Profile
        /// feature.
        public var openProfile: (ProfileID, ProfileIdentityStub?) -> Void
        /// Fires the app's message-this-person destination (the sub-filter
        /// pill menu's Send Message). Injected for the same reason as
        /// `openProfile`.
        public var openConversation: (ProfileID, ProfileIdentityStub?) -> Void
        /// Whether tile responses are decorated with the DEBUG place catalog
        /// (`MapMockPlaces`) — the semantic city/country clusters. The
        /// composition root passes its one `seedsMapPlaces` decision here AND
        /// to the mock backend's seeding, so the pins that arrive and the
        /// ladders they wear always agree; false keeps the pins
        /// identity-clean. Release builds ignore it — the catalog does not
        /// exist there.
        public var seedsMockPlaces: Bool
        /// Each mock post's author avatar, keyed by post id — the stand-in for
        /// the author `RadarPin` does not carry. Empty off the mock.
        public var mockAuthorAvatars: [PostID: URL]
        /// Baked animated icons, keyed by post id — text-only posts only.
        ///
        /// Same shape of absence as `mockAuthorAvatars`: `RadarPin` carries no
        /// `icon_id` yet (`dev/issues/BACKEND_ANIMATED_PIN_ICONS.md` proposes
        /// field 12), so mock mode supplies what the wire cannot and
        /// production leaves it empty.
        public var mockAnimatedIcons: [PostID: String]
        /// Baked preview sheets, keyed by post id — MEDIA posts only. Empty
        /// off the mock.
        public var mockPreviewSheets: [PostID: String]
        /// What the markers wear as icon faces.
        public var iconCatalog: any AnimatedIconProviding
        /// The media markers' baked previews.
        public var previewCatalog: AnimatedIconCatalog
        /// Which countries the account has unlocked — see `CountryAccess`.
        /// Nil on the fleet, which has no country access yet: every country
        /// opens and none is sold.
        public var countryAccess: (any CountryAccess)?
        /// What the Shop's Boosts sells — see `StakePackSelling`. Nil on the
        /// fleet, like the shop itself: none is sold.
        public var stakePacks: (any StakePackSelling)?
        /// What the Shop's Profile shelf sells (#944). Nil on the fleet, like
        /// the shop itself: none is sold.
        public var profileItems: (any ProfileItemSelling)?
        /// Whether the viewer has an account. A guest has no people: no
        /// favourites dock, no Friends / Following rows.
        public var isMember: @MainActor () -> Bool
        /// Where the device is, for the locate button and the "See posts
        /// around you" card.
        public var locator: any CurrentCountryLocating
        /// The device store (#893): the map opens on the pins of its last
        /// viewports at a cold start. Nil when the device store can't be
        /// opened: the map stays in memory only.
        public var localStore: LocalStore?
        /// The app's one storage scope (#2376): the map's own stores — the
        /// followed places, the people rails, the dock — are the active
        /// profile's.
        public var storageScope: StorageScope

        public init(
            repository: any GeoDiscoveryProviding,
            favoritesRepository: any MapFavoritesProviding,
            imagePipeline: ImagePipeline,
            videoPlayback: VideoPlaybackController,
            feedFeature: @escaping () -> any FeedFeatureBuilding,
            placeFeature: @escaping () -> any PlaceFeatureBuilding,
            openProfile: @escaping (ProfileID, ProfileIdentityStub?) -> Void,
            openConversation: @escaping (ProfileID, ProfileIdentityStub?) -> Void,
            seedsMockPlaces: Bool,
            mockAuthorAvatars: [PostID: URL],
            mockAnimatedIcons: [PostID: String],
            mockPreviewSheets: [PostID: String],
            iconCatalog: any AnimatedIconProviding,
            previewCatalog: AnimatedIconCatalog,
            countryAccess: (any CountryAccess)?,
            stakePacks: (any StakePackSelling)?,
            profileItems: (any ProfileItemSelling)?,
            isMember: @escaping @MainActor () -> Bool,
            locator: any CurrentCountryLocating,
            localStore: LocalStore?,
            storageScope: StorageScope
        ) {
            self.repository = repository
            self.favoritesRepository = favoritesRepository
            self.imagePipeline = imagePipeline
            self.videoPlayback = videoPlayback
            self.feedFeature = feedFeature
            self.placeFeature = placeFeature
            self.openProfile = openProfile
            self.openConversation = openConversation
            self.seedsMockPlaces = seedsMockPlaces
            self.mockAuthorAvatars = mockAuthorAvatars
            self.mockAnimatedIcons = mockAnimatedIcons
            self.mockPreviewSheets = mockPreviewSheets
            self.iconCatalog = iconCatalog
            self.previewCatalog = previewCatalog
            self.countryAccess = countryAccess
            self.stakePacks = stakePacks
            self.profileItems = profileItems
            self.isMember = isMember
            self.locator = locator
            self.localStore = localStore
            self.storageScope = storageScope
        }
    }

    private let repository: any GeoDiscoveryProviding
    private let favoritesRepository: any MapFavoritesProviding
    private let imagePipeline: ImagePipeline
    private let videoPlayback: VideoPlaybackController
    private let feedFeature: () -> any FeedFeatureBuilding
    private let placeFeature: () -> any PlaceFeatureBuilding
    private let openProfile: (ProfileID, ProfileIdentityStub?) -> Void
    private let openConversation: (ProfileID, ProfileIdentityStub?) -> Void
    /// Curating the people rail, shared with whatever else pins a profile —
    /// today the profile screen's pin button. Built here (not injected)
    /// because the state it owns is the map's own: no service vends a
    /// favorites list, so the device is the only place it has ever lived.
    /// Handed OUT through `profilePinning` so the composition root can give
    /// the same instance to another feature.
    private let pinService: MapProfilePinService
    /// The followed PLACES, built here for the same reason as `pinService`:
    /// no service vends them, so the device is where they live. One instance
    /// feeds both consumers — the gallery header's toggle and the map's
    /// Favorites sub-filter — which is what makes the toggle show up on the
    /// map at all.
    private let placeFollows: MapPlaceFollowStore
    /// The places pinned to the dock (#1598), for every map this builder
    /// makes and every place page's "Add Pin to Map".
    private let dockedPlaces: MapDockedPlacesStore

    /// The interface-typed seam the composition root hands to other features.
    public var profilePinning: any MapProfilePinning { pinService }

    private let countryAccess: (any CountryAccess)?
    private let locator: any CurrentCountryLocating
    private let stakePacks: (any StakePackSelling)?
    private let profileItems: (any ProfileItemSelling)?
    private let isMember: @MainActor () -> Bool
    /// One for the app's lifetime: every map the builder makes reads and
    /// folds into the same stored pins.
    private let pinsCache: MapPinsLocalCache?
    /// The dock's and the rows' people on the device (#1776).
    private let peopleCache: MapPeopleLocalCache?

    public init(dependencies: Dependencies) {
        let storageScope = dependencies.storageScope
        let localStore = dependencies.localStore
        let favoritesRepository = dependencies.favoritesRepository
        self.placeFollows = MapPlaceFollowStore(scope: storageScope)
        self.dockedPlaces = MapDockedPlacesStore(scope: storageScope)
        self.pinsCache = localStore.map(MapPinsLocalCache.init(store:))
        self.peopleCache = localStore.map(MapPeopleLocalCache.init(store:))
        self.isMember = dependencies.isMember
        self.locator = dependencies.locator
        self.countryAccess = dependencies.countryAccess
        self.stakePacks = dependencies.stakePacks
        self.profileItems = dependencies.profileItems
        self.iconCatalog = dependencies.iconCatalog
        self.previewCatalog = dependencies.previewCatalog
        self.repository = dependencies.repository
        self.favoritesRepository = favoritesRepository
        self.imagePipeline = dependencies.imagePipeline
        self.videoPlayback = dependencies.videoPlayback
        self.feedFeature = dependencies.feedFeature
        self.placeFeature = dependencies.placeFeature
        self.openProfile = dependencies.openProfile
        self.openConversation = dependencies.openConversation
        self.pinService = MapProfilePinService(
            store: MapFavoritesStore(scope: storageScope), favorites: favoritesRepository
        )
        #if DEBUG
        // ⚠️ ONE DECORATION, TWO STAND-INS, and both are the same shape of
        // absence: `RadarPin` carries neither a place (`BACKEND_GAPS` §18) nor
        // an author (`dev/issues/BACKEND_MAP_PIN_AUTHOR.md`), so mock mode
        // supplies each from what the mock dataset knows and production leaves
        // both nil. Folded into one closure so a pin is decorated once.
        let places = dependencies.seedsMockPlaces
        let avatars = dependencies.mockAuthorAvatars
        let icons = dependencies.mockAnimatedIcons
        let previews = dependencies.mockPreviewSheets
        if places || !avatars.isEmpty || !icons.isEmpty || !previews.isEmpty {
            self.placeDecoration = { pins in
                let tagged = places ? MapMockPlaces.decorate(pins) : pins
                return tagged.map { pin in
                    // TEXT ONLY, both of them, and the guard is here rather
                    // than in the seed so a caller cannot hand in a media post
                    // by accident. A media pin has a cover; a second answer to
                    // "what is this" painted over it is not a feature.
                    // A MEDIA pin gets a preview of its own footage; a TEXT pin
                    // gets an icon or an avatar. The two populations are
                    // disjoint by construction, which is what stops a marker
                    // ever carrying both.
                    guard pin.isText else {
                        let base = pin.postID.rawValue.split(separator: "#").first.map(String.init)
                        let sheet = previews[pin.postID]
                            ?? base.flatMap({ previews[PostID($0)] })
                        #if DEBUG
                        // `-maps-log-sheets`: the ONE question four rounds of
                        // fixture archaeology never actually asked — does a
                        // sheet id reach this pin? The HUD's `sheets=` counts
                        // ADVANCING sheets, so it reads zero for a marker that
                        // is wearing one perfectly, and every conclusion drawn
                        // from it was unfounded.
                        if LaunchArgument.mapsLogSheets.isPassed() {
                            print("[sheet] \(pin.postID.rawValue) kind=\(pin.kind)"
                                  + " sheet=\(sheet ?? "nil") seeded=\(previews.count)")
                        }
                        #endif
                        guard let sheet else { return pin }
                        return pin.previewing(sheet)
                    }
                    var decorated = pin
                    let avatarBase = pin.postID.rawValue.split(separator: "#").first.map(String.init)
                    if let avatar = avatars[pin.postID]
                        ?? avatarBase.flatMap({ avatars[PostID($0)] }) {
                        decorated = decorated.wearing(avatar)
                    }
                    // The `#n` suffix is `-maps-mock-density`'s replication
                    // marker. Falling back to the base id is what lets a dense
                    // field wear icons at all — the seed is keyed by the ids the
                    // DATASET knows, and a clone is not one of them. Each copy
                    // still gets its own phase, because that comes from the full
                    // id, so a replicated field animates out of step rather than
                    // as one block.
                    let base = pin.postID.rawValue.split(separator: "#").first.map(String.init)
                    if let icon = icons[pin.postID]
                        ?? base.flatMap({ icons[PostID($0)] }) {
                        decorated = decorated.showing(icon)
                    }
                    return decorated
                }
            }
        } else {
            self.placeDecoration = { $0 }
        }
        #else
        self.placeDecoration = { $0 }
        #endif
    }

    /// What the view model runs over every tile response — the place
    /// decoration in DEBUG mock mode, identity everywhere else.
    private let placeDecoration: ([MapPin]) -> [MapPin]
    private let iconCatalog: any AnimatedIconProviding
    private let previewCatalog: AnimatedIconCatalog

    public func makeMapViewController() -> UIViewController {
        let feedFeature = feedFeature
        let placeFeature = placeFeature
        let placeFollows = placeFollows
        let dockedPlaces = dockedPlaces
        let map = MapsViewController(
            viewModel: MapsViewModel(
                repository: repository,
                followedPlaceIDs: { placeFollows.followedPlaceIDs },
                decorate: placeDecoration,
                localCache: pinsCache
            ),
            favoritesRepository: favoritesRepository,
            pinService: pinService,
            dockedPlaces: dockedPlaces,
            imagePipeline: imagePipeline,
            iconCatalog: iconCatalog,
            previewCatalog: previewCatalog,
            videoPlayback: videoPlayback,
            // A marker's or a cluster's posts are everything it has: the feed
            // knows its last post is the end, and a swipe up there closes it
            // (#628).
            makeSnapFeed: { postIDs in
                feedFeature().makeSnapFeedViewController(
                    postIDs: postIDs, ownsInteractiveDismissal: true, sourceIsComplete: true
                )
            },
            // The same feed, arrived at by the platform's own slide — what a
            // marker opens with under Reduce Motion. A complete set too (#674):
            // every route a marker opens by knows its last post is the end.
            // Every non-media marker opens this way since #2015. `beneath`
            // carries the semantic cluster's place page through, so a
            // text-faced city or country dismisses downward into it like a
            // media-faced one does.
            pushPlainSnapFeed: { postIDs, presenter, beneath in
                feedFeature().pushSnapFeed(
                    postIDs: postIDs, from: presenter, sourceIsComplete: true, beneath: beneath
                )
            },
            // The same window asked for at CLOSE time: a feed opened by a hero
            // whose viewer paged onto a post with no media has nothing left to
            // fly, and the honest close is the marker's own window.
            makeRevealGeometry: { feed, origin, onWillClose in
                feedFeature().makeRevealGeometry(
                    dismissing: feed, origin: origin, onWillClose: onWillClose
                )
            },
            // The place gallery a hierarchy cluster's feed dismisses into —
            // built by the Place feature (#2381). `mapReturn` rides through so
            // the page's own dismissal can fly home to the marker.
            makeClusterGallery: { postIDs, place, countryCode, centre, feed, mapReturn, markerClose in
                placeFeature().makeClusterGallery(
                    postIDs: postIDs,
                    title: place.galleryTitle,
                    rank: place.rankBadge,
                    identity: Self.placeIdentity(
                        of: place, countryCode: countryCode, centre: centre, dockedPlaces: dockedPlaces
                    ),
                    // The header's follow toggle, bound to THIS place's
                    // identity in the map's own store — which is also what
                    // the Favorites sub-filter reads, so the button and the
                    // filter agree by construction.
                    following: ClusterGalleryFollowing(
                        isFollowing: { placeFollows.isFollowed(place.id) },
                        toggle: { placeFollows.toggle(place.id) }
                    ),
                    feed: feed,
                    mapReturn: mapReturn,
                    markerClose: markerClose
                )
            },
            prewarm: { ids in await feedFeature().prewarmPosts(ids) },
            warmPlayback: { id, seconds in feedFeature().warmPlayback(of: id, at: seconds) },
            prerollPlayback: { id, seconds in feedFeature().prerollPlayback(of: id, at: seconds) },
            openProfile: openProfile,
            openConversation: openConversation,
            countryAccess: countryAccess,
            stakePacks: stakePacks,
            profileItems: profileItems,
            isMember: isMember,
            // Always: the locked guest map's card is its only way out, on
            // the fleet too, where there is no country access yet (#564).
            // Members there still see no location controls without it.
            locator: locator,
            // The text bubble (#2203): a text post's words, from the feed's store.
            loadTextPosts: { ids in await feedFeature().galleryPosts(ids) },
            heldTextPost: { id in feedFeature().heldGalleryPost(id) }
        )
        // The dock's and the rows' people open on their last list (#1776).
        map.peopleCache = peopleCache
        // Nothing plays on the map (`AvatarMotionPolicy`).
        map.traitOverrides.avatarMotionScreen = .map
        return map
    }
}

extension MapsFeatureBuilder {
    /// What a place's page wears beside its name: its country's round flag,
    /// LARGE (a city wears its country's, as its marker's border does), and
    /// its subtitle — a country's continent, a city's country; neither for a
    /// place in no country (at sea) — and its share link, for its QR code.
    static func placeIdentity(
        of place: MapPlace, countryCode: String, centre: CLLocationCoordinate2D? = nil,
        dockedPlaces: MapDockedPlacesStore
    ) -> PlaceIdentity? {
        let country = CountryAtlas.shared.country(code: countryCode)
        let link = shareURL(of: place, countryCode: countryCode, centre: centre)
        return PlaceIdentity(
            flag: country.flatMap { FlagPalette.largeRoundFlag(for: $0.code) ?? FlagPalette.image(for: $0.code) },
            subtitle: country.map { place.kind == .country ? $0.continent : $0.name },
            shareURL: link,
            query: placeQuery(of: place, countryCode: countryCode, centre: centre),
            dockPin: link.map {
                dockPin(for: MapDockedPlacesStore.Entry(url: $0.absoluteString, name: place.name), store: dockedPlaces)
            }
        )
    }

    /// The place page's "Add Pin to Map" (#1598), bound to the map's dock:
    /// the place by its public link, the one identity every route agrees on.
    static func dockPin(
        for entry: MapDockedPlacesStore.Entry, store: MapDockedPlacesStore
    ) -> ClusterGalleryFollowing {
        return ClusterGalleryFollowing(
            isFollowing: { store.isDocked(entry.url) },
            toggle: { store.toggle(entry) }
        )
    }

    /// The place as the server lists its posts (#643): a country by its code,
    /// a city by its marker's centre. Nil when neither is known (at sea).
    static func placeQuery(of place: MapPlace, countryCode: String, centre: CLLocationCoordinate2D?) -> PlaceQuery? {
        switch place.kind {
        case .country:
            return countryCode.isEmpty ? nil : .country(countryCode)
        case .city:
            return centre.map { .city(latitude: $0.latitude, longitude: $0.longitude) }
        }
    }

    /// A place's public web address (#985): what the server lists its posts
    /// by — a country's code, a city's point with its name — on
    /// `AppRoute.webHost` (`PlaceLink`). Never the mock's own `MapPlace.id`,
    /// which no other device or mode could open. Nil when the place has
    /// neither (at sea).
    static func shareURL(of place: MapPlace, countryCode: String, centre: CLLocationCoordinate2D?) -> URL? {
        placeLink(of: place, countryCode: countryCode, centre: centre)?.url
    }

    static func placeLink(of place: MapPlace, countryCode: String, centre: CLLocationCoordinate2D?) -> PlaceLink? {
        switch place.kind {
        case .country:
            return countryCode.isEmpty ? nil : .country(code: countryCode.uppercased())
        case .city:
            return centre.map {
                .city(latitude: $0.latitude, longitude: $0.longitude, name: place.name,
                      countryCode: countryCode.isEmpty ? nil : countryCode.uppercased())
            }
        }
    }

    /// A place's page opened from a link (#985): alone, its posts from the
    /// server page by page, its identity from the atlas — a country's name,
    /// flag and continent; a city's name, its country's flag and name. Nil
    /// for a country the atlas does not know.
    /// `storageScope`: the app's one (#2376), whose profile's dock the page's
    /// "Add Pin to Map" writes.
    public static func placePage(
        for link: PlaceLink, place placeFeature: any PlaceFeatureBuilding, storageScope: StorageScope
    ) -> UIViewController? {
        let place: MapPlace
        let countryCode: String
        let centre: CLLocationCoordinate2D?
        switch link {
        case .country(let code):
            guard let country = CountryAtlas.shared.country(code: code) else { return nil }
            place = MapPlace(id: "country:" + code.lowercased(), name: country.name, kind: .country)
            countryCode = code
            centre = nil
        case .city(let latitude, let longitude, let name, let code):
            place = MapPlace(id: "city:" + name.lowercased(), name: name, kind: .city)
            countryCode = code ?? ""
            centre = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        guard let identity = placeIdentity(
            of: place, countryCode: countryCode, centre: centre,
            dockedPlaces: MapDockedPlacesStore(scope: storageScope)
        ) else { return nil }
        return placeFeature.makePlacePage(title: place.galleryTitle, identity: identity)
    }
}
