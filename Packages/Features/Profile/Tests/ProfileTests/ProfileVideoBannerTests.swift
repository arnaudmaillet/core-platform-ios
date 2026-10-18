import CoreContracts
import CoreModels
import Foundation
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Profile

/// The video banner (#944): read off the profile's own banner media, played
/// over its still by the header when the screen says so.
@MainActor
struct ProfileVideoBannerTests {
    private func view(bannerURL: String = "", renditions: [(Media_V1_RenditionKind, String)] = []) -> Profile_V1_ProfileView {
        var view = Profile_V1_ProfileView()
        view.profileID = "prof-1"
        view.avatarURL = "https://example.com/avatar.jpg"
        view.bannerURL = bannerURL
        var media = Media_V1_DeliveredMedia()
        media.renditions = renditions.map { kind, url in
            var rendition = Media_V1_DeliveredRendition()
            rendition.kind = kind
            rendition.url = url
            return rendition
        }
        view.banner = media
        return view
    }

    @Test func theBannersStillIsItsURLThenItsPoster() {
        #expect(ProfileRepository.bannerStill(of: view(bannerURL: "https://example.com/b.jpg"))
            == URL(string: "https://example.com/b.jpg"))
        #expect(ProfileRepository.bannerStill(of: view(renditions: [(.mediaRenditionKindPoster, "https://example.com/p.jpg")]))
            == URL(string: "https://example.com/p.jpg"))
        #expect(ProfileRepository.bannerStill(of: view()) == nil, "a profile with no banner invented one")
    }

    private func profile(bannerURL: URL?, bannerVideoURL: URL?) -> UserProfile {
        UserProfile(
            id: ProfileID("prof-1"), handle: "ada", displayName: "Ada", bio: "",
            avatarURL: URL(string: "https://example.com/avatar.jpg"),
            bannerURL: bannerURL, bannerVideoURL: bannerVideoURL,
            websiteURL: nil, isVerified: false,
            followerCount: .unavailable, followingCount: .unavailable, reactionCount: .unavailable
        )
    }

    /// No banner of its own: the avatar, as every profile has always shown.
    @Test func aProfileWithoutABannerShowsItsAvatar() {
        let model = ProfileDisplayModel(profile: profile(bannerURL: nil, bannerVideoURL: nil))
        #expect(model.bannerImageURL == URL(string: "https://example.com/avatar.jpg"))
        #expect(model.bannerVideoURL == nil)
    }

    @Test func aVideoBannerCarriesItsLoopAndItsStill() {
        let still = URL(string: "https://example.com/poster.jpg")
        let loop = URL(string: "https://example.com/loop.m3u8")
        let model = ProfileDisplayModel(profile: profile(bannerURL: still, bannerVideoURL: loop))
        #expect(model.bannerImageURL == still)
        #expect(model.bannerVideoURL == loop)
    }

    /// No pool, nothing plays: the still stays, and a stop is harmless.
    @Test func withoutAPoolTheStillStays() {
        let banner = ProfileBannerView(imagePipeline: ImagePipeline(fetcher: NoFetch()))
        banner.setVideoURL(URL(string: "https://example.com/loop.m3u8"), pool: nil)
        banner.setVideoPlaying(true, pool: nil)
        #expect(!banner.isVideoPlaying)
        #expect(banner.debugVideoView.isHidden)
        banner.setVideoPlaying(false, pool: nil)
        #expect(!banner.isVideoPlaying)
    }

    // MARK: - Through a dismissal (#1399)

    private actor BannerProfiles: ProfileProviding {
        private func someone() -> UserProfile {
            UserProfile(
                id: ProfileID("prof-demo"), handle: "you", displayName: "Demo Viewer", bio: "",
                avatarURL: nil, bannerURL: URL(string: "https://example.test/poster.jpg"),
                bannerVideoURL: URL(string: "mock://video/clip-18"), websiteURL: nil, isVerified: false,
                followerCount: .exact(0), followingCount: .exact(0), reactionCount: .exact(0)
            )
        }
        func currentUserProfile() async throws -> UserProfile { someone() }
        func profile(id: ProfileID) async throws -> UserProfile { someone() }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
        func updateCurrentUserProfile(
            displayName: String, bio: String, website: String, links: [ProfileLink]
        ) async throws -> UserProfile { someone() }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { someone() }
    }

    private struct StubSource: VideoSource {
        func playableURL(for url: URL) async throws -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stub.mp4")
        }
    }

    private func settle(looks: Int = 2_000, until condition: () -> Bool) async -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// The loop plays on while the screen leaves — it used to stop at
    /// `viewWillDisappear`, the card empty for the whole dismissal — and
    /// stops once the screen has gone, its player back to the pool; a
    /// cancelled dismissal keeps it.
    @Test func theLoopPlaysOnThroughADismissalAndStopsOnceGone() async throws {
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 2)
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: BannerProfiles(), source: .currentUser),
            imagePipeline: ImagePipeline(fetcher: NoFetch()),
            videoPlayback: pool,
            makeGridPage: TestGridPages.factory(),
            onLogout: nil
        )
        let navigation = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let surface = screen.headerView.debugBannerVideoView
        try #require(await settle {
            window.layoutIfNeeded()
            return screen.headerView.hasBannerVideo && screen.debugBannerVideoShouldPlay && pool.hasPlayer(in: surface)
        }, "the loop never played on show")

        // A dismissal begins, then is cancelled: the loop never stops.
        screen.beginAppearanceTransition(false, animated: true)
        #expect(screen.debugBannerVideoShouldPlay, "the loop stopped as the dismissal began")
        #expect(pool.hasPlayer(in: surface) && !surface.isHidden, "the loop left the card as the dismissal began")
        screen.beginAppearanceTransition(true, animated: true)
        screen.endAppearanceTransition()
        #expect(screen.debugBannerVideoShouldPlay, "a cancelled dismissal stopped the loop")
        #expect(pool.hasPlayer(in: surface))

        // A dismissal that completes: playing through it, released once gone.
        screen.beginAppearanceTransition(false, animated: true)
        #expect(screen.debugBannerVideoShouldPlay)
        #expect(pool.hasPlayer(in: surface))
        screen.endAppearanceTransition()
        #expect(!screen.debugBannerVideoShouldPlay, "the loop outlived the screen")
        #expect(!pool.hasPlayer(in: surface), "the banner's player stayed in the pool after the screen went")
        #expect(pool.playerCountByURL.isEmpty, "a player is left in the pool: \(pool.playerCountByURL)")
    }

    /// A stilled loop (Reduce Motion, Power Saving, once gone) leaves the
    /// still drawn under it — never the empty card.
    @Test func aStoppedLoopLeavesItsStill() async throws {
        let banner = ProfileBannerView(imagePipeline: ImagePipeline(fetcher: PictureFetch()))
        banner.frame = CGRect(x: 0, y: 0, width: 378, height: 300)
        let pool = VideoPlaybackController(source: StubSource(), poolSize: 2)
        banner.setVideoURL(URL(string: "mock://video/clip-18"), pool: pool)
        banner.setImageURL(URL(string: "https://example.test/poster.jpg"))
        banner.setVideoPlaying(true, pool: pool)
        try #require(await settle { banner.debugHasPicture && pool.hasPlayer(in: banner.debugVideoView) })
        banner.setVideoPlaying(false, pool: pool)
        #expect(banner.debugHasPicture, "the still went with the loop")
        #expect(banner.debugVideoView.isHidden && !pool.hasPlayer(in: banner.debugVideoView))
    }

    private struct PictureFetch: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            }.pngData() ?? Data()
        }
    }

    private struct NoFetch: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }
}
