import AVFoundation
import CacheKit
import Connect
import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworkingMocks
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

    func makeCountryAccess() -> CountryAccessService? {
        guard environment == .mock else { return nil }
        let unlocks = CountryUnlockStore()
        // The mock account owns the world seed's countries from the first
        // launch, as if it had bought them (`MockWorldSeed`; Mexico, South
        // Korea and most one-post countries stay locked WITH posts, for the
        // locked design). Seeded ONCE per code into the same store a purchase
        // writes, so a later unlock or relock of the account's own survives
        // every relaunch — and an install seeded before the seed grew gets
        // only the new codes.
        // `-countries-no-seed` skips it (with `-countries-reset`: home only).
        if !LaunchArgument.countriesNoSeed.isPassed() {
            unlocks.seedUnlocks(MockWorldSeed.unlockedCountryCodes, for: MockAuthService.accountID)
        }
        return CountryAccessService(
            accountID: MockAuthService.accountID,
            // The account's own country. The mock account lives in Paris.
            homeCountry: "FR",
            wallet: walletStore,
            unlocks: unlocks,
            teen: teenProtections,
            activity: CountryAccessService.mockActivity(in: mockBackend),
            isMember: { [unowned self] in self.memberGate.isMember },
            locator: currentCountry,
            covers: CountryAccessService.mockCovers(in: mockBackend),
            // A member's countries are the server's (#1475).
            geo: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: authenticatedRPCClient)
        )
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
        MapsFeatureBuilder(
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
            seedsMockPlaces: environment == .mock && Self.seedsMapPlaces,
            // Same rule, same reason: a text marker wears its author's face, and
            // the wire has no author to give it
            // (`dev/issues/BACKEND_MAP_PIN_AUTHOR.md`). The mock knows the
            // authorship `RadarPin` omits, so it can answer here; on the fleet this
            // is empty and the marker keeps the glyph.
            mockAuthorAvatars: environment == .mock ? Self.mockAuthorAvatars(in: mockBackend) : [:],
            // Same rule again, one field further out: a TEXT-ONLY post may carry an
            // animated icon, and the wire has no `icon_id` to give it
            // (`dev/issues/BACKEND_ANIMATED_PIN_ICONS.md`, proposed field 12). The
            // mock knows which posts are text-only; on the fleet this is empty and
            // the marker keeps the author's face. The icon is an EMOTE — the one the
            // caption carries — resolved by `mapIcons` (see `EmoteMapIcons`).
            mockAnimatedIcons: environment == .mock ? Self.mockAnimatedIcons(in: mockBackend) : [:],
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
            mockPreviewSheets: environment == .mock
                ? Self.mockPreviewSheets(in: mockBackend, catalogue: Self.mapPreviewCatalog) : [:],
            // ⚠️ The ids above are always handed out, even when the provider
            // handed to the map cannot honour them. That is the whole point of
            // `-map-icons-unavailable`: seeding from an empty catalogue would give
            // no pin an icon id at all, so no marker would wear `.icon` and the
            // fallback would never run — the flag would prove the opposite of what
            // it claims. Here the pins carry ids and the catalogue answers nothing,
            // which is exactly a fleet build, an evicted asset, or a decode that
            // failed.
            iconCatalog: Self.mapIconProvider,
            previewCatalog: Self.previewsUnavailable ? Self.unavailableIconCatalog : Self.mapPreviewCatalog,
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
        )
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
    private static let unavailableIconCatalog: AnimatedIconCatalog? = nil
    #endif

    /// Animated avatars (#1358, #1444): the sheets of the authors the mock
    /// declares animated (about half), baked from the map's clip previews in
    /// the geometry the backend is asked to bake (core-platform-backend#945,
    /// #948). An animated avatar has no photo. Off the mock, none until the
    /// sheet rendition ships.
    @MainActor
    func installAnimatedAvatars() {
        guard environment == .mock, !Self.previewsUnavailable else { return }
        // The mock and MediaCore must mark a sheet avatar's URL alike.
        assert(MockSocialDataset.sheetAvatarFragment == AnimatedAvatars.sheetFragment)
        AnimatedAvatars.shared.resolver = MockAnimatedAvatarResolver(catalog: Self.mapPreviewCatalog)
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

    private static func mockPreviewSheets(
        in backend: MockBackend, catalogue: AnimatedIconCatalog
    ) -> [PostID: String] {
        backend.dataset.previewSheetIDsByPostID(catalogue: catalogue.ids)
            .reduce(into: [:]) { result, entry in
                result[PostID(entry.key)] = entry.value
            }
    }

    /// The baked animated-icon catalogue that ships in the app bundle.
    ///
    /// A stand-in for the CDN the contract describes: production fetches these
    /// by URL from `AnimatedIcon.still_url` / `sheet_url`. Built by
    /// `Tools/IconBaker` — 16 decomposed stills and 5 sheets baked from real
    /// GIFs, every step an integer multiple of a 30 fps base so the whole
    /// catalogue changes on ONE grid.
    private static let mapIconCatalog = AnimatedIconCatalog(manifest: "mapicons")

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
    private static var mapIconProvider: (any AnimatedIconProviding)? {
        if iconsUnavailable { return unavailableIconCatalog }
        return mapIcons
    }

    /// Which mock post wears which icon face. The dataset decides WHICH text
    /// posts wear one; each wears the emote its caption carries, or a face
    /// handed out in turn — never one of the catalogue's geometric
    /// placeholders, which read as an empty disc (`EmoteMapIcons`).
    ///
    /// `-maps-baked-icons` (DEBUG) hands out the baked catalogue's own ids
    /// instead, in manifest order as before — the ONLY way the map shows its
    /// decomposed still+track icons now that no face is one, kept for the
    /// playback and cost instruments (`-map-icon-hud`, `-icon-bench`) that
    /// measure that path. Their discs and squircles are the empty markers.
    private static func mockAnimatedIcons(in backend: MockBackend) -> [PostID: String] {
        if wearsBakedIcons {
            return backend.dataset.animatedIconIDsByPostID(catalogue: mapIconCatalog.ids)
                .reduce(into: [:]) { result, entry in result[PostID(entry.key)] = entry.value }
        }
        let captions = Dictionary(
            backend.dataset.posts.map { ($0.postID, $0.caption) }, uniquingKeysWith: { first, _ in first }
        )
        return backend.dataset.animatedIconIDsByPostID(catalogue: EmoteMapIcons.defaultFaceIDs)
            .reduce(into: [:]) { result, entry in
                result[PostID(entry.key)] = captions[entry.key].flatMap {
                    EmoteMapIcons.faceID(forCaption: $0)
                } ?? entry.value
            }
    }

    /// Each mock post's author avatar, keyed by post id — the stand-in for the
    /// author `RadarPin` does not carry.
    private static func mockAuthorAvatars(in backend: MockBackend) -> [PostID: URL] {
        backend.dataset.authorAvatarURLsByPostID().reduce(into: [:]) { result, entry in
            guard let url = URL(string: entry.value) else { return }
            result[PostID(entry.key)] = url
        }
    }
}

/// The mock's animated avatars (#1358, #1444): the authors the dataset
/// declares as sheet avatars (`MockSocialDataset.sheetAvatarURL`), which have
/// NO photo. Each sheet is baked at the rung asked for from one clip preview,
/// as a seamless loop of that clip's own frames, its tail fading back into
/// its first frame (#1424).
///
/// ⚠️ NO FACE PHOTO BLENDED IN (the owner, 2026-10-20). The sheet used to
/// fade in and out of a separate face photo, unrelated to the clip: on
/// For You's Friends faces the photo and the clip showed together, two
/// media in one avatar. An animated avatar's only media is its sheet.
private struct MockAnimatedAvatarResolver: AnimatedAvatarResolving, @unchecked Sendable {
    let catalog: AnimatedIconCatalog

    func sheet(for avatarURL: URL, rung: AnimatedAvatars.Rung) async -> AnimatedIconSheet? {
        guard let index = MockSocialDataset.sheetAvatarIndex(avatarURL) else { return nil }
        guard let previewID = Self.previewID(forSheetAvatar: index) else { return nil }
        // Baked once, then read back on every launch after (#1841): cutting
        // 48 frames out of a clip at launch kept the first post's avatar on
        // its skeleton for 8–17 s on the simulator.
        let key = "\(previewID)-\(rung.rawValue)-v\(Self.bakeVersion)"
        if let kept = await Task.detached(priority: .utility, operation: { Self.store.sheet(forKey: key) }).value {
            return kept
        }
        guard let baked = await bake(previewID: previewID, rung: rung) else { return nil }
        Task.detached(priority: .utility) { Self.store.store(baked, forKey: key) }
        return baked
    }

    /// The preview an animated avatar is cut from: its clip's opening sheet
    /// (`MockClipCatalog.avatarClip(forSheetAvatar:)`, never a post's clip).
    static func previewID(forSheetAvatar index: Int) -> String? {
        MockClipCatalog.shared.avatarClip(forSheetAvatar: index).map { "\($0.id)-0" }
    }

    /// Where the baked sheets are kept across launches.
    private static let store = AnimatedIconSheetDiskStore.caches(named: "MockAnimatedAvatarSheets")
    /// Bumped whenever the bake changes, so a kept sheet is never stale.
    private static let bakeVersion = 1

    private func bake(previewID: String, rung: AnimatedAvatars.Rung) async -> AnimatedIconSheet? {
        // 48 frames, 4 s at 12 fps, cut from the clip itself (the owner,
        // 2026-10-25: avatars twice as long) — the map preview carries only
        // 24 frames over 2 s. The preview stays the fallback.
        let clipID = String(previewID.dropLast(2))
        if let video = MockClipCatalog.shared.videoFileURL(clipID: clipID),
           let sheet = await Self.bakeFromVideo(video, rung: rung) {
            return sheet
        }
        guard case .sheet(let source)? = try? await catalog.art(for: previewID) else { return nil }
        return await Task.detached(priority: .utility) {
            AnimatedAvatars.bakeSquareSheet(from: source, cellPX: rung.rawValue)
        }.value
    }

    /// Frames of an avatar sheet, per the backend's geometry: 48 at 12 fps.
    static let sheetFrames = 48
    static let sheetFrameDuration: CFTimeInterval = 1.0 / 12.0

    /// 48 frames of `video` from 1 s in (earlier when the clip is short),
    /// baked as a seamless square sheet at `rung`.
    private static func bakeFromVideo(_ video: URL, rung: AnimatedAvatars.Rung) async -> AnimatedIconSheet? {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return nil }
        let span = Double(sheetFrames) * sheetFrameDuration
        let start = max(0, min(1.0, duration - span))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: rung.rawValue * 2, height: rung.rawValue * 2)
        let tolerance = CMTime(seconds: sheetFrameDuration / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var cells: [CGImage?] = []
        for index in 0..<sheetFrames {
            let time = CMTime(seconds: min(start + Double(index) * sheetFrameDuration, duration - 0.01), preferredTimescale: 600)
            cells.append(try? await generator.image(at: time).image)
        }
        guard cells.contains(where: { $0 != nil }) else { return nil }
        let frames = cells
        return await Task.detached(priority: .utility) {
            AnimatedAvatars.bakeSquareSheet(cells: frames, frameDuration: sheetFrameDuration, cellPX: rung.rawValue)
        }.value
    }
}
