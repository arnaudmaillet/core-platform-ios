import CacheKit
import Connect
import CoreContracts
import CoreModels
import CoreNavigation
import CoreStorage
import EmoteKit
import FeedInterface
import Foundation
import LaunchArguments
import LocalStore
import Maps
import MapsInterface
import MediaCore
import MediaPlayback
import MediaUI
import PlaceInterface
import UIKit
import Wallet

// Maps (#2375): the map's repositories and builder, the countries, the baked
// icon and preview catalogues, and the mock's animated avatars. Its properties
// are declared in `AppContainer.swift`, since an extension holds no stored
// property; they are built here.
extension AppContainer {
    func makeMapsRepository() -> GeoDiscoveryRepository {
        GeoDiscoveryRepository(
            geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: authenticatedRPCClient),
            // counter.v1, so each tile's pins carry their LIKE counts and a
            // cluster can wear its most popular member's face.
            counterClient: Counter_V1_CounterServiceClient(client: authenticatedRPCClient)
        )
    }

    func makeMapsFavoritesRepository() -> MapFavoritesRepository {
        MapFavoritesRepository(
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: authenticatedRPCClient),
            profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient)
        )
    }

    /// The countries' standings and unlocks: the mock's (`makeMockCountryAccess`),
    /// nil on a real backend, which carries no unlocks yet.
    func makeCountryAccess() -> CountryAccessService? {
        #if MOCK_BACKEND
        if environment == .mock { return makeMockCountryAccess() }
        #endif
        return nil
    }

    func makeCurrentCountry() -> CurrentCountryProvider {
        CurrentCountryProvider(
            // Only the country the server grants opens (B10): it checks the code
            // against the network's GeoIP country.
            verifier: GeoCountryAccessVerifier(
                geoClient: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: authenticatedRPCClient)
            )
        )
    }

    func makeMapsFeature() -> any MapsFeatureBuilding {
        let standIns = mapStandIns()
        return MapsFeatureBuilder(dependencies: .init(
            repository: mapsRepository,
            favoritesRepository: mapsFavoritesRepository,
            imagePipeline: imagePipeline,
            videoPlayback: mapsVideoPlayback,
            feedFeature: { [unowned self] in self.feedFeature },
            placeFeature: { [unowned self] in self.placeFeature },
            openProfile: { [unowned self] id, stub in
                self.router.route(to: .profile(id, stub: stub))
            },
            openConversation: { [unowned self] id, stub in
                self.router.route(to: .messageUser(id, stub: stub))
            },
            // Mock mode only: fleet pins are real posts and must never wear the
            // stand-in place catalog, however the flag reads.
            seedsMockPlaces: environment.isMock && Self.seedsMapPlaces,
            // Same rule, same reason: a text marker wears its author's face, and
            // the wire has no author to give it
            // (`dev/issues/BACKEND_MAP_PIN_AUTHOR.md`). The mock knows the
            // authorship `RadarPin` omits, so it can answer here; on the fleet this
            // is empty and the marker keeps the glyph.
            mockAuthorAvatars: standIns.authorAvatars,
            // Same rule again, one field further out: a TEXT-ONLY post may carry an
            // animated icon, and the wire has no `icon_id` to give it
            // (`dev/issues/BACKEND_ANIMATED_PIN_ICONS.md`, proposed field 12). The
            // mock knows which posts are text-only; on the fleet this is empty and
            // the marker keeps the author's face. The icon is an EMOTE — the one the
            // caption carries — resolved by `mapIcons` (see `EmoteMapIcons`).
            mockAnimatedIcons: standIns.animatedIcons,
            // Baked previews of a media post's own footage — the decode-free
            // alternative to a player, and the ONLY animated media the map can show
            // without a network: the sheets are in the app bundle, so unlike live
            // playback they owe nothing to `-rich-media`, whose absence leaves every
            // media post pointing at an unplayable `mock://video/...`.
            //
            // No longer behind a launch argument. It was, while the memory cost was
            // an open question; it is now measured. 24 distinct sheets are 4.8 MB on
            // the wire and 65.0 MB if every one were resident at once, against a
            // 64 MB byte-budgeted cache — so full variety GUARANTEES eviction, and
            // eviction was measured holding at 7-9 resident (19.0-24.4 MB) across
            // every run including a 464-marker field. The worst case measured 144
            // markers with 80 sheets advancing at a locked 60fps, and the animation
            // itself costs +1.6 ms of frame mean against animating nothing at all.
            mockPreviewSheets: standIns.previewSheets,
            // ⚠️ The ids above are always handed out, even when the provider
            // handed to the map cannot honour them. That is the whole point of
            // `-map-icons-unavailable`: seeding from an empty catalogue would give
            // no pin an icon id at all, so no marker would wear `.icon` and the
            // fallback would never run — the flag would prove the opposite of what
            // it claims. Here the pins carry ids and the catalogue answers nothing,
            // which is exactly a fleet build, an evicted asset, or a decode that
            // failed.
            iconCatalog: Self.mapIconProvider,
            previewCatalog: Self.mapPreviewProvider,
            countryAccess: countryAccess,
            stakePacks: stakePacks,
            profileItems: profileItems,
            // A guest has no people: no favourites dock, no Friends / Following.
            isMember: { [unowned self] in self.memberGate.isMember },
            locator: currentCountry,
            // The pins of the last viewports, so a cold start opens the map on
            // its markers (#893).
            localStore: localStore,
            // The map's own stores are the active profile's (#2376).
            storageScope: storageScope
        ))
    }

    #if DEBUG
    /// `-map-icons-unavailable` / `-map-previews-unavailable`: keep the ids,
    /// break the resolution. The floor under an icon face is invisible in a
    /// screenshot of a healthy build, so without these it is only ever pinned by
    /// unit tests.
    static let iconsUnavailable =
        LaunchArgument.mapIconsUnavailable.isPassed()
    static let previewsUnavailable =
        LaunchArgument.mapPreviewsUnavailable.isPassed()
    /// A manifest that does not exist. `AnimatedIconCatalog` answers an absent
    /// manifest with an empty table rather than trapping, so every lookup misses
    /// and every async resolve throws — the real failure path, not a stub.
    private static let unavailableIconCatalog =
        AnimatedIconCatalog(manifest: "mapicons-deliberately-absent")
    /// `-maps-baked-icons`: text posts wear the baked catalogue's icons, the
    /// decomposed placeholders included — see `mockAnimatedIcons`.
    static let wearsBakedIcons =
        LaunchArgument.mapsBakedIcons.isPassed()
    #else
    static let wearsBakedIcons = false
    static let iconsUnavailable = false
    static let previewsUnavailable = false
    #endif

    /// Animated avatars (#1358, #1444): the sheets of the authors the mock
    /// declares animated (about half), baked from the map's clip previews in
    /// the geometry the backend is asked to bake (core-platform-backend#945,
    /// #948). An animated avatar has no photo. Off the mock, none until the
    /// sheet rendition ships.
    @MainActor
    func installAnimatedAvatars() {
        #if MOCK_BACKEND
        guard environment == .mock, !Self.previewsUnavailable else { return }
        installMockAnimatedAvatars()
        #endif
    }

    /// Baked from real clips by `Tools/IconBaker` — 24 frames at a 172px cell,
    /// which is the 56pt media face at @3x plus the contract's 2px gutter.
    static let mapPreviewCatalog = AnimatedIconCatalog(
        manifest: "mappreviews",
        // ⚠️ 64 MB, not the icons' 24. A preview is 2.71 MB resident against an
        // icon's 0.07 — a shared budget would let the dear one evict the cheap
        // one on every pan. Nineteen previews is 51.5 MB, so this is sized to
        // hold the measured field rather than to a round number.
        memoryBudgetMB: 64,
        // Cut from posts' clips: feed media, not a UI asset (#971). Goes with
        // the feed under memory pressure, ahead of the icons.
        priorityClass: .standard
    )

    /// The baked animated-icon catalogue that ships in the app bundle.
    ///
    /// A stand-in for the CDN the contract describes: production fetches these
    /// by URL from `AnimatedIcon.still_url` / `sheet_url`. Built by
    /// `Tools/IconBaker` — 16 decomposed stills and 5 sheets baked from real
    /// GIFs, every step an integer multiple of a 30 fps base so the whole
    /// catalogue changes on ONE grid.
    static let mapIconCatalog = AnimatedIconCatalog(manifest: "mapicons")

    /// Hands the map's baked icon catalogue to EmoteKit, for the house emotes
    /// drawn from it (`:lol:`, `:blush:`). The map's own catalogue, so nothing
    /// is bundled twice; EmoteKit keeps a matted copy of each sheet it uses
    /// (`EmoteIconMatte` lifts the white paper off). Until this runs those
    /// emotes stay on their stand-in emoji.
    @MainActor
    static func configureEmotes() {
        EmoteEngine.shared.iconCatalog = mapIconCatalog
    }

    /// What the map's markers wear as icon faces: emotes, through EmoteKit,
    /// over the baked catalogue — see `EmoteMapIcons`.
    private static let mapIcons = EmoteMapIcons(catalogue: mapIconCatalog)

    /// `mapIcons`, or under `-map-icons-unavailable` a catalogue that resolves
    /// nothing.
    private static var mapIconProvider: any AnimatedIconProviding {
        #if DEBUG
        if iconsUnavailable { return unavailableIconCatalog }
        #endif
        return mapIcons
    }

    /// `mapPreviewCatalog`, or under `-map-previews-unavailable` a catalogue
    /// that resolves nothing.
    private static var mapPreviewProvider: AnimatedIconCatalog {
        #if DEBUG
        if previewsUnavailable { return unavailableIconCatalog }
        #endif
        return mapPreviewCatalog
    }

    /// What the mock knows that the wire does not carry yet (`MapStandIns`):
    /// the mock's own (`mockMapStandIns`), none on a real backend.
    private func mapStandIns() -> MapStandIns {
        #if MOCK_BACKEND
        if environment == .mock { return mockMapStandIns() }
        #endif
        return MapStandIns()
    }
}

/// The map's stand-ins for fields the wire does not carry yet, which only the
/// mock can answer (#2391: built by `mockMapStandIns`, empty off the mock).
struct MapStandIns {
    /// A text marker's author face (`dev/issues/BACKEND_MAP_PIN_AUTHOR.md`).
    var authorAvatars: [PostID: URL] = [:]
    /// A text-only post's animated icon (`dev/issues/BACKEND_ANIMATED_PIN_ICONS.md`).
    var animatedIcons: [PostID: String] = [:]
    /// A media post's baked preview sheet.
    var previewSheets: [PostID: String] = [:]
}
