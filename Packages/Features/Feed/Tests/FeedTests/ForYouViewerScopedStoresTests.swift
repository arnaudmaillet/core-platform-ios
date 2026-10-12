import CoreModels
import CoreStorage
import Foundation
import PostGrid
import Testing
@testable import Feed

/// FOR YOU'S SEEN AND UNREAD STATE IS THE VIEWER'S (#978).
///
/// The friends' stories a person opened and the "since you last looked"
/// watermarks were kept for the whole device: a profile switch carried the
/// previous viewer's rings and badges. Both stores now key by the active
/// profile (`StorageScope.profileKey`, the #443 policy), and the device-wide
/// keys of earlier builds are adopted by the first profile that reads them.
///
/// Every test owns its defaults suite and its scope; the app's shared scope is
/// never touched.
struct ForYouViewerScopedStoresTests {
    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "foryou.viewer-scoped.tests.\(UUID().uuidString)")!
    }

    private static func member(_ profile: String) -> StorageScope.Owner {
        .member(account: "acc-1", profile: profile)
    }

    private static func post(_ id: String, at publishedAtMS: Int64) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: "caption \(id)", publishedAtMS: publishedAtMS, reactionCount: nil
        )
    }

    // MARK: - Seen stories

    @Test func aProfileSwitchReadsTheNewViewersSeenStories() {
        let scope = StorageScope(owner: Self.member("p1"))
        let store = ForYouSeenPostsStore(defaults: Self.defaults(), scope: scope)
        store.insert([PostID("opened-by-p1")])

        scope.owner = Self.member("p2")
        #expect(!store.contains(PostID("opened-by-p1")), "p2 inherited p1's opened story")
        store.insert([PostID("opened-by-p2")])

        scope.owner = Self.member("p1")
        #expect(store.contains(PostID("opened-by-p1")), "p1's own set was lost")
        #expect(!store.contains(PostID("opened-by-p2")), "p1 inherited p2's opened story")
    }

    @Test func theDeviceWideSeenSetIsAdoptedByTheFirstProfileOnly() {
        let defaults = Self.defaults()
        defaults.set(["opened-before-scoping"], forKey: "foryou.friends.seen")
        let scope = StorageScope(owner: Self.member("p1"))
        let store = ForYouSeenPostsStore(defaults: defaults, scope: scope)

        #expect(store.contains(PostID("opened-before-scoping")), "the first profile lost the device's set")
        #expect(defaults.object(forKey: "foryou.friends.seen") == nil, "the device-wide key stayed behind")

        scope.owner = Self.member("p2")
        #expect(!store.contains(PostID("opened-before-scoping")), "a second profile inherited the device's set")
    }

    // MARK: - Unread watermarks

    @Test func aProfileSwitchCountsFromTheNewViewersOwnWatermark() {
        let scope = StorageScope(owner: Self.member("p1"))
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = ForYouUnreadStore(
            defaults: Self.defaults(), keyPrefix: "test.unread", arguments: [], now: { now }, scope: scope
        )
        let early = [Self.post("a", at: 1_000_000)]
        let later = early + [Self.post("b", at: 1_500_000), Self.post("c", at: 1_600_000)]

        // p1 looked when only `a` was there; two posts arrived since.
        #expect(store.sessionBaseline(for: .activity, in: early) == 1_000_000)
        #expect(store.count(for: .activity, in: later) == 2)

        // p2 has never looked: a first sight, nothing unread, and its own
        // watermark is the newest it has seen.
        scope.owner = Self.member("p2")
        #expect(store.count(for: .activity, in: later) == 0, "p2 inherited p1's unread count")
        #expect(store.sessionBaseline(for: .activity, in: later) == 1_600_000)

        scope.owner = Self.member("p1")
        #expect(store.count(for: .activity, in: later) == 2, "p1's watermark moved with p2's visit")
    }

    @Test func theDeviceWideWatermarkIsAdoptedByTheFirstProfileOnly() {
        let defaults = Self.defaults()
        defaults.set(Int64(1_200_000), forKey: "test.unread.media")
        let scope = StorageScope(owner: Self.member("p1"))
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = ForYouUnreadStore(
            defaults: defaults, keyPrefix: "test.unread", arguments: [], now: { now }, scope: scope
        )
        let posts = [Self.post("a", at: 1_100_000), Self.post("b", at: 1_300_000)]

        #expect(store.count(for: .media, in: posts) == 1, "the first profile lost the device's watermark")
        #expect(defaults.object(forKey: "test.unread.media") == nil, "the device-wide key stayed behind")

        scope.owner = Self.member("p2")
        #expect(store.count(for: .media, in: posts) == 0, "a second profile inherited the device's watermark")
    }
}
