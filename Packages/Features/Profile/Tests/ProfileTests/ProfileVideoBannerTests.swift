import CoreContracts
import CoreModels
import Foundation
import MediaCore
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

    private struct NoFetch: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }
}
