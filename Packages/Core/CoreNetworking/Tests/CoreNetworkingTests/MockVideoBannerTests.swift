import Connect
import CoreContracts
import CoreNetworkingMocks
import Foundation
import Testing
@testable import CoreNetworking

/// The mock's `UpdateBanner` (#944): the viewer's banner from one of their
/// video posts' media asset, read back as the banner media, or cleared.
struct MockVideoBannerTests {
    private func make() -> Profile_V1_ProfileServiceClient {
        let bff = MockBFF()
        MockSocialServices(dataset: MockSocialDataset(), postStore: MockPostStore()).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return Profile_V1_ProfileServiceClient(client: client)
    }

    private func viewer(_ client: Profile_V1_ProfileServiceClient) async throws -> Profile_V1_ProfileView {
        var request = Profile_V1_GetProfileByIdRequest()
        request.profileID = MockSocialDataset.viewerProfileID
        return try await client.getProfileByID(request: request, headers: [:]).result.get()
    }

    private func setBanner(
        _ client: Profile_V1_ProfileServiceClient, asset: String,
        profile: String = MockSocialDataset.viewerProfileID
    ) async -> ConnectError? {
        var request = Profile_V1_UpdateBannerRequest()
        request.profileID = profile
        request.bannerAssetID = asset
        return await client.updateBanner(request: request, headers: [:]).error
    }

    private var clip: String? {
        MockSocialServices.videoBannerClips.first { MockClipCatalog.shared.clip(id: $0) != nil }
    }

    @Test func theViewerStartsWithoutAVideoBanner() async throws {
        let client = make()
        #expect(try await viewer(client).banner.renditions.isEmpty)
    }

    @Test func aVideoPostsAssetBecomesTheBannerAndClears() async throws {
        let client = make()
        let clip = try #require(clip)
        #expect(await setBanner(client, asset: MockSocialServices.clipAssetPrefix + clip) == nil)
        let banner = try await viewer(client)
        let loop = try #require(banner.banner.renditions.first { $0.kind == .mediaRenditionKindManifest })
        #expect(loop.url.contains(clip))
        #expect(!banner.bannerURL.isEmpty, "the poster is the still")

        #expect(await setBanner(client, asset: "") == nil)
        #expect(try await viewer(client).banner.renditions.isEmpty)
    }

    @Test func onlyTheViewersOwnVideoAssets() async throws {
        let client = make()
        #expect(await setBanner(client, asset: "asset-somewhere-else")?.code == .invalidArgument)
        let clip = try #require(clip)
        #expect(await setBanner(client, asset: MockSocialServices.clipAssetPrefix + clip, profile: "someone-else")?.code
            == .permissionDenied)
    }
}
