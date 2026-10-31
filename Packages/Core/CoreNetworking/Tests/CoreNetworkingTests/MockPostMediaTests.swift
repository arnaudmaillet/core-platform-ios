import Foundation
import Testing
@testable import CoreNetworkingMocks

/// ⚠️ POSTS WEAR "MEDIA 2", AVATARS AND SOUNDS KEEP THE OLD (the owner,
/// 2026-10-31, with "media3"). Across the whole mock world — the timeline, the viewer's
/// posts, the arrivals and their test collections, the world on the map —
/// every post's media is one of the owner's "media 2" clips or photographs;
/// the avatars, the banners and the borrowed sounds read the media they read
/// before. One media may be several posts', each with its own id.
@MainActor
struct MockPostMediaTests {
    private let clips = MockClipCatalog.shared
    private let photos = MockPhotoCatalog.shared
    private let dataset = MockSocialDataset(seedsWorld: true)

    /// Every media URL a post carries, head first.
    private func urls(_ post: MockSocialDataset.PostRecord) -> [String] {
        ([post.media?.url] + post.extraMedia.map(\.url)).compactMap { $0 }
    }

    /// Clip uses, in the order the world draws them.
    private var clipUses: [String] {
        dataset.posts.flatMap(urls).compactMap { URL(string: $0).flatMap(clips.clip(for:))?.id }
    }

    // MARK: - Posts

    /// Every media of every post is a "media 2" clip or photograph: never a
    /// retired clip, never an old gallery's or single's picture.
    @Test func everyPostMediaIsMedia2() {
        let postClips = Set(clips.postClips.map(\.id))
        let postPhotos = Set(photos.posts.map(\.id))
        #expect(postClips.count >= 151, "the bundle carries \(postClips.count) post clips")
        #expect(postPhotos.count >= 23, "the bundle carries \(postPhotos.count) post photos")
        for post in dataset.posts {
            for url in urls(post).compactMap(URL.init(string:)) {
                if let clip = clips.clip(for: url) {
                    #expect(postClips.contains(clip.id), "\(post.postID) plays the retired \(clip.id)")
                } else if let photo = photos.photo(for: url) {
                    #expect(postPhotos.contains(photo.id), "\(post.postID) shows the old \(photo.id)")
                } else {
                    Issue.record("\(post.postID) carries \(url), in no catalog")
                }
            }
        }
    }

    /// Every "media 2" clip is exactly one post's (the owner: use them all):
    /// the video posts and one photo post in two (`photoPostMedia`).
    @Test func everyClipIsExactlyOnePosts() {
        var counts: [String: Int] = [:]
        for id in clipUses { counts[id, default: 0] += 1 }
        let unused = clips.postClips.map(\.id).filter { counts[$0] == nil }
        #expect(unused.isEmpty, "no post plays \(unused)")
        let repeated = counts.filter { $0.value > 1 }.keys.sorted()
        #expect(repeated.isEmpty, "several posts play \(repeated)")
    }

    /// Single photos go round "media 2" in order: every one of them is a
    /// post's picture, and a repeat starts only once all are used.
    @Test func singlePhotosGoRoundThePool() {
        let singles = dataset.posts.filter { $0.extraMedia.isEmpty }
            .compactMap(\.media?.url).filter { $0.hasPrefix(MockPhotoCatalog.scheme) }
        #expect(singles.count > photos.posts.count)
        #expect(Set(singles) == Set(photos.posts.map(\.media.url)))
        for ordinal in 0..<(photos.posts.count * 2) {
            #expect(photos.singlePhoto(forOrdinal: ordinal) == photos.posts[ordinal % photos.posts.count])
        }
    }

    /// No carousel in the timeline (the owner: few carousels): the only
    /// posts with pages are the arrivals' three test collections.
    @Test func theOnlyCarouselsAreTheTestCollections() {
        let carousels = dataset.posts.filter { !$0.extraMedia.isEmpty }.map(\.postID)
        #expect(carousels.sorted() == ["post-new-01", "post-new-04", "post-new-05"], "\(carousels)")
    }

    /// A "media 2" clip's sound is its own post's: never lent.
    @Test func aPostClipsSoundIsNeverBorrowable() {
        #expect(clips.postClips.allSatisfy { !$0.lendsItsSound })
        for slot in 0..<(clips.clips.count * 2) {
            let clip = clips.borrowableClip(forSlot: slot)
            #expect(clip?.lendsItsSound == true && clip?.isRetired == true)
        }
    }

    /// A "media 2" clip has no sound file: its sound is in its own video.
    @Test func aPostClipIsHeardFromItsVideo() throws {
        let clip = try #require(clips.postClips.first)
        #expect(clips.soundFileURL(clipID: clip.id) == nil)
        #expect(clips.videoFileURL(clipID: clip.id) != nil)
        #expect(clips.posterFileURL(clipID: clip.id) != nil)
    }

    // MARK: - What keeps the old media

    /// The sounds photo and text posts borrow are the retired clips', in the
    /// order they always had — so a borrowing post keeps its sound.
    @Test func theBorrowedSoundsAreUnchanged() {
        let before = [
            "clip-01", "clip-02", "clip-03", "clip-04", "clip-05", "clip-06", "clip-07", "clip-08",
            "clip-09", "clip-10", "clip-11", "clip-12", "clip-13", "clip-14", "clip-15", "clip-16",
            "clip-17", "clip-18", "clip-19", "clip-20", "clip-21", "clip-22", "clip-23", "clip-24",
            "clip-25", "clip-26", "clip-27", "clip-28", "clip-29", "clip-30", "clip-31", "clip-32",
            "clip-33", "clip-34", "clip-35", "clip-36", "clip-37", "clip-38", "clip-39", "clip-40",
            "clip-41", "clip-42", "clip-43", "clip-44", "clip-45", "clip-46", "clip-47", "clip-48",
            "clip-49", "clip-50", "clip-51", "clip-52", "clip-53", "clip-54", "clip-55", "clip-56",
            "clip-57", "clip-58", "clip-59", "clip-61", "clip-62", "clip-63", "clip-64", "clip-65",
            "clip-66", "clip-68", "clip-69", "clip-71", "clip-72", "clip-73", "clip-74", "clip-75",
            "clip-76", "clip-77", "clip-78", "clip-79"
        ]
        #expect(clips.borrowableClips.map(\.id) == before)
        for id in before { #expect(clips.soundFileURL(clipID: id) != nil, "\(id) lost its sound") }
    }

    /// Avatars — and so banners — wear the photographs they wore before
    /// "media 2" (pinned from `develop` @ 9473c9cf).
    @Test func avatarsAreUnchanged() {
        #expect(MockSocialDataset.syntheticAvatarURL(index: 0) == "mock://photo/gallery-13-06?w=1170&h=878")
        #expect(MockSocialDataset.syntheticAvatarURL(index: 1) == "mock://photo/gallery-17-15?w=1080&h=1440")
        #expect(MockSocialDataset.syntheticAvatarURL(index: 2) == "mock://photo/gallery-17-14?w=1080&h=1440")
        #expect(MockSocialDataset.syntheticAvatarURL(index: 5) == "mock://photo/gallery-17-12?w=1080&h=1440")
        #expect(MockSocialDataset.syntheticViewerAvatarURL == "mock://photo/gallery-13-08?w=1170&h=878")
    }

    /// No avatar is a post's picture, and no two authors (nor the viewer)
    /// wear the same one.
    @Test func noAvatarIsAPostsPicture() {
        let postPictures = Set(dataset.posts.flatMap(urls))
        // An animated avatar's author wears its photo as the banner.
        let avatars = dataset.authors.map { $0.bannerURL.isEmpty ? $0.avatarURL : $0.bannerURL }
            .filter { $0.hasPrefix(MockPhotoCatalog.scheme) } + [MockSocialDataset.syntheticViewerAvatarURL]
        #expect(avatars.count > 30)
        for avatar in avatars {
            #expect(!postPictures.contains(avatar), "\(avatar) is also a post's picture")
        }
        #expect(Set(avatars).count == avatars.count, "two people wear one avatar")
    }

    /// The animated avatars are cut from the retired clips they were cut from
    /// before, and every clip an animated avatar or a video banner reads
    /// keeps its video.
    @Test func avatarAndBannerClipsKeepTheirVideo() {
        let animated = dataset.authors.indices.filter(MockSocialDataset.hasSheetAvatar(index:))
        #expect(!animated.isEmpty)
        for index in animated {
            let clip = clips.avatarClip(forSheetAvatar: index)
            #expect(clip?.id == String(format: "clip-%02d", index + 1), "author \(index)")
            #expect(clip.flatMap { clips.videoFileURL(clipID: $0.id) } != nil, "author \(index)'s clip has no video")
        }
        for id in MockSocialServices.videoBannerClips {
            #expect(clips.clip(id: id)?.isRetired == true)
            #expect(clips.videoFileURL(clipID: id) != nil, "the banner \(id) has no video")
        }
    }
}
