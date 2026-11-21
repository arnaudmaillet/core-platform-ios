#if MOCK_BACKEND
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

// The map's mock half (#2391): the countries the mock account owns, the
// stand-ins for what the wire does not carry yet, and the mock's animated
// avatars. Mock builds only: the production target links no mock.
extension AppContainer {
    /// The countries' standings and unlocks in mock mode (`makeCountryAccess`).
    func makeMockCountryAccess() -> CountryAccessService {
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
            viewerEvents: viewerEvents,
            activity: CountryAccessService.mockActivity(in: mockBackend),
            isMember: { [unowned self] in self.memberGate.isMember },
            locator: currentCountry,
            covers: CountryAccessService.mockCovers(in: mockBackend),
            // A member's countries are the server's (#1475).
            geo: GeoDiscovery_V1_GeoDiscoveryServiceClient(client: authenticatedRPCClient)
        )
    }

    /// The mock's answers for the fields `RadarPin` omits (`MapStandIns`).
    func mockMapStandIns() -> MapStandIns {
        MapStandIns(
            authorAvatars: Self.mockAuthorAvatars(in: mockBackend),
            animatedIcons: Self.mockAnimatedIcons(in: mockBackend),
            previewSheets: Self.mockPreviewSheets(in: mockBackend, catalogue: Self.mapPreviewCatalog)
        )
    }

    /// Animated avatars (`installAnimatedAvatars`) from the mock's clips.
    @MainActor
    func installMockAnimatedAvatars() {
        // The mock and MediaCore must mark a sheet avatar's URL alike.
        assert(MockSocialDataset.sheetAvatarFragment == AnimatedAvatars.sheetFragment)
        AnimatedAvatars.shared.resolver = MockAnimatedAvatarResolver(catalog: Self.mapPreviewCatalog)
    }

    static func mockPreviewSheets(
        in backend: MockBackend, catalogue: AnimatedIconCatalog
    ) -> [PostID: String] {
        backend.dataset.previewSheetIDsByPostID(catalogue: catalogue.ids)
            .reduce(into: [:]) { result, entry in
                result[PostID(entry.key)] = entry.value
            }
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
    static func mockAnimatedIcons(in backend: MockBackend) -> [PostID: String] {
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
    static func mockAuthorAvatars(in backend: MockBackend) -> [PostID: URL] {
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
#endif
