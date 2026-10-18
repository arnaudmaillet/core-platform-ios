import CoreModels
import CoreStorage
import Foundation
import PostGrid
import Testing
@testable import Profile

/// Edit Profile → Video Banner (#944): the shop item at 500 gems until the
/// account owns it, then the loop of one of the viewer's own video posts.
@MainActor
struct EditProfileVideoBannerTests {
    private nonisolated static let me = ProfileID("prof-me")

    private nonisolated static func profile(loop: URL? = nil) -> UserProfile {
        UserProfile(
            id: me, handle: "me", displayName: "Me", bio: "", avatarURL: nil,
            bannerVideoURL: loop, websiteURL: nil, isVerified: false,
            followerCount: .unavailable, followingCount: .unavailable, reactionCount: .unavailable
        )
    }

    private actor Profiles: ProfileProviding {
        func currentUserProfile() async throws -> UserProfile { EditProfileVideoBannerTests.profile() }
        func profile(id: ProfileID) async throws -> UserProfile { EditProfileVideoBannerTests.profile() }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
        func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile {
            EditProfileVideoBannerTests.profile()
        }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { EditProfileVideoBannerTests.profile() }
    }

    private actor Banner: ProfileBannerManaging {
        private(set) var sent: [String?] = []
        func setBannerVideo(assetID: String?) async throws -> UserProfile {
            sent.append(assetID)
            return EditProfileVideoBannerTests.profile(loop: assetID.map { URL(string: "https://example.com/\($0).m3u8")! })
        }
    }

    private struct Gallery: ProfileGalleryProviding {
        let posts: [GalleryPost]
        func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { posts }
        func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
        func posts(ids: [String]) async throws -> [GalleryPost] { [] }
    }

    private final class Items: ProfileItemAccess {
        var gems: Int
        var owned: Set<ProfileItem> = []
        init(gems: Int) { self.gems = gems }
        func owns(_ item: ProfileItem) -> Bool { owned.contains(item) }
        func buy(_ item: ProfileItem) -> ProfileItemPurchase {
            guard !owned.contains(item) else { return .alreadyOwned }
            guard gems >= item.gemPrice else { return .insufficientGems(needed: item.gemPrice, have: gems) }
            gems -= item.gemPrice
            owned.insert(item)
            return .bought(remainingGems: gems)
        }
    }

    private static func video(_ id: String, asset: String?, repost: Bool = false) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .video, isRepost: repost,
            pages: [GalleryPost.MediaPage(
                thumbnailURL: URL(string: "https://example.com/\(id).jpg"),
                videoURL: URL(string: "https://example.com/\(id).mp4"), aspectRatio: 9.0 / 16.0, assetID: asset
            )],
            caption: id, publishedAtMS: 1
        )
    }

    private func makeModel(items: Items?, banner: Banner = Banner(), posts: [GalleryPost] = []) -> EditProfileViewModel {
        EditProfileViewModel(
            repository: Profiles(), seed: Self.profile(), banner: banner, gallery: Gallery(posts: posts),
            items: items, onSaved: {}
        )
    }

    @Test func withoutTheShopTheRowIsHidden() {
        #expect(makeModel(items: nil).videoBannerRow == .hidden)
    }

    @Test func untilOwnedTheRowIsTheItemsPrice() {
        #expect(makeModel(items: Items(gems: 0)).videoBannerRow == .locked(price: 500))
    }

    @Test func buyingWithEnoughGemsOwnsItOnce() {
        let items = Items(gems: 650)
        let model = makeModel(items: items)
        #expect(model.buyVideoBanner() == .bought(remainingGems: 150))
        #expect(model.videoBannerRow == .off)
        #expect(model.buyVideoBanner() == .alreadyOwned, "bought once, for good")
        #expect(items.gems == 150)
    }

    @Test func notEnoughGemsBuysNothing() {
        let model = makeModel(items: Items(gems: 82))
        #expect(model.buyVideoBanner() == .insufficientGems(needed: 500, have: 82))
        #expect(model.videoBannerRow == .locked(price: 500))
    }

    /// The picker offers the viewer's own videos that name their media asset:
    /// no repost, no photo, no video without an asset.
    @Test func thePickerOffersOwnVideosWithAnAsset() async throws {
        let photo = GalleryPost(id: PostID("photo"), kind: .photo, isRepost: false, thumbnailURL: nil, caption: "", publishedAtMS: 1)
        let model = makeModel(items: Items(gems: 0), posts: [
            Self.video("ok", asset: "asset-ok"), Self.video("no-asset", asset: nil),
            Self.video("repost", asset: "asset-r", repost: true), photo,
        ])
        #expect(try await model.ownVideoPosts().map(\.id.rawValue) == ["ok"])
    }

    @Test func pickingAVideoSetsTheBannerFromItsAsset() async throws {
        let items = Items(gems: 500)
        let banner = Banner()
        let model = makeModel(items: items, banner: banner)
        _ = model.buyVideoBanner()
        model.setVideoBanner(Self.video("ok", asset: "asset-ok"))
        for _ in 0..<100 where model.videoBannerRow != .on { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await banner.sent == ["asset-ok"])
        #expect(model.videoBannerRow == .on)

        model.setVideoBanner(nil)
        for _ in 0..<100 where model.videoBannerRow != .off { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await banner.sent == ["asset-ok", nil])
    }

    /// Not owned, a pick sends nothing.
    @Test func withoutTheItemAPickSendsNothing() async throws {
        let banner = Banner()
        let model = makeModel(items: Items(gems: 0), banner: banner)
        model.setVideoBanner(Self.video("ok", asset: "asset-ok"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await banner.sent.isEmpty)
    }
}
